// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/error_text.dart';
import 'real_network_scan_service.dart' show isLocalNetworkDenied;
import 'spec_codec.dart';

/// The transport half of a legacy LimitlessLED / Mi-Light bridge: play a timed
/// sequence of datagrams at UDP 8899.
///
/// The Rust codec decides what goes on the wire and when, zone addressing and
/// the repeat-with-pacing the spec calls for included, so this owns only the
/// socket and the waiting. The protocol is write-only: nothing answers, so a
/// return from [send] means the phone sent the frames and says nothing about
/// whether a bulb, or even a bridge of this generation, acted on them.
class LimitlessledControlClient {
  /// `crate::protocol::limitlessled::PORT`, for a device whose spec and
  /// discovery both gave none.
  static const defaultPort = 8899;

  /// Throws [LimitlessledControlException] for a send the phone itself could
  /// not make.
  Future<void> send(
    String host,
    int port,
    List<LimitlessledFrameDto> frames,
  ) async {
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      throw LimitlessledControlException(
        '"$host" is not an address this app can send to.',
      );
    }
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException catch (e) {
      throw LimitlessledControlException(
        'Could not open a socket to talk to the bridge (${e.message}).',
      );
    }
    // dart:io never throws a refused send: it returns 0 and delivers the
    // SocketException on this stream, so listening is how a refusal is seen.
    Object? refusal;
    final subscription = socket.listen(
      (_) {},
      onError: (Object e) => refusal ??= e,
    );
    try {
      for (final frame in frames) {
        socket.send(Uint8List.fromList(frame.bytes), address, port);
        // At least one event-loop turn, so a refusal lands before the next
        // frame and before the socket closes below.
        await Future<void>.delayed(Duration(milliseconds: frame.delayAfterMs));
        if (refusal != null) break;
      }
      final failed = refusal;
      if (failed != null) throw _sendError(failed);
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  static LimitlessledControlException _sendError(Object error) {
    if (isLocalNetworkDenied(
      error,
      isApplePlatform: Platform.isIOS || Platform.isMacOS,
    )) {
      return const LimitlessledControlException(
        'The phone could not send to the bridge: Local Network access is off '
        'for this app (Settings → Privacy & Security → Local Network).',
      );
    }
    final detail = error is SocketException
        ? (error.osError?.message ?? error.message)
        : '$error';
    return LimitlessledControlException(
      'The phone could not send to the bridge ($detail).',
    );
  }
}

/// A send the phone could not make, in words meant for the person holding it.
class LimitlessledControlException implements UserFacingException {
  @override
  final String message;
  const LimitlessledControlException(this.message);
  @override
  String toString() => 'LimitlessledControlException: $message';
}
