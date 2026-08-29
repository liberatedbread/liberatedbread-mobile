// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';

/// Raw byte-stream transport for Brother QL raster label printers.
///
/// A QL consumes one unframed, unauthenticated byte stream — the same on TCP
/// 9100 (RAW/AppSocket), LPR/LPD 515, SPP or USB. Rust builds every byte (the
/// job and the `ESC i S` status request); this only opens the socket, writes,
/// and optionally reads the fixed 32-byte status reply back. Like the other
/// network transports, it never throws: every failure is a typed result so a
/// print button can report it without an unhandled async error.
class BrotherQlPrintService {
  /// How long to wait for the TCP connect.
  final Duration connectTimeout;

  /// How long to wait for the 32-byte status reply before giving up (the
  /// printer answers a status request promptly, or not at all).
  final Duration statusReadTimeout;

  const BrotherQlPrintService({
    this.connectTimeout = const Duration(seconds: 6),
    this.statusReadTimeout = const Duration(seconds: 4),
  });

  /// Open [host]:[port], write [payload], and — when [readStatus] — read up to
  /// the 32-byte status reply. Returns [BrotherQlSendOk] (with the reply, or
  /// null when none was requested/received) or [BrotherQlSendFailed].
  Future<BrotherQlSendResult> send(
    String host,
    int port,
    List<int> payload, {
    bool readStatus = false,
  }) async {
    Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: connectTimeout);
    } on Object catch (e) {
      Log.spec.debug('brother_ql connect to $host:$port failed', error: e);
      return BrotherQlSendFailed('Could not reach the printer at $host:$port.');
    }
    try {
      socket.add(payload);
      await socket.flush();
      if (!readStatus) {
        await socket.close();
        return const BrotherQlSendOk(null);
      }
      final reply = await _readStatus(socket);
      // close() flushes and half-closes; destroy() guarantees the read side is
      // torn down too even if the printer left the connection open.
      socket.destroy();
      return BrotherQlSendOk(reply);
    } on Object catch (e) {
      Log.spec.debug('brother_ql send to $host:$port failed', error: e);
      socket.destroy();
      return const BrotherQlSendFailed('The printer refused the data.');
    }
  }

  /// Collect the first 32 bytes the printer sends, or null on timeout / a short
  /// close. Cancels its subscription and timer however it completes.
  Future<Uint8List?> _readStatus(Socket socket) {
    final completer = Completer<Uint8List?>();
    final buffer = <int>[];
    void completeWith(Uint8List? value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    final timer = Timer(statusReadTimeout, () => completeWith(null));
    final subscription = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        if (buffer.length >= 32) {
          completeWith(Uint8List.fromList(buffer.sublist(0, 32)));
        }
      },
      onError: (Object _) => completeWith(null),
      onDone: () => completeWith(buffer.length >= 32
          ? Uint8List.fromList(buffer.sublist(0, 32))
          : null),
      cancelOnError: true,
    );
    return completer.future.whenComplete(() {
      timer.cancel();
      unawaited(subscription.cancel());
    });
  }
}

/// The outcome of a [BrotherQlPrintService.send].
sealed class BrotherQlSendResult {
  const BrotherQlSendResult();
}

class BrotherQlSendOk extends BrotherQlSendResult {
  /// The 32-byte status reply when one was requested and received, else null.
  final Uint8List? statusReply;
  const BrotherQlSendOk(this.statusReply);
}

class BrotherQlSendFailed extends BrotherQlSendResult {
  final String reason;
  const BrotherQlSendFailed(this.reason);
}

/// The print transport. Tests override with a fake.
final brotherQlPrintServiceProvider =
    Provider<BrotherQlPrintService>((ref) => const BrotherQlPrintService());
