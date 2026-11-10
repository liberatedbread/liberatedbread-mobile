// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/error_text.dart';
import '../core/log.dart';
import '../core/stop_signal.dart';
import 'real_network_scan_service.dart' show isLocalNetworkDenied;
import 'spec_codec.dart';

/// The transport half of a LOY SPACE / popled.cn LED panel over Wi-Fi: its
/// `aa 55` frames in UDP datagrams to port 9090 (led-space.yaml).
///
/// The Rust codec owns every byte — the frame, the outer length prefix the
/// spec gives each datagram, the 180-byte split, the reading of replies — so
/// this owns the socket, the sequence number and the waiting. Every frame is
/// acknowledged by the panel and the next waits for it, the way the BLE
/// backpack's frames are.
///
/// NOT verified on hardware. The frame and its bodies are the ones a real
/// backpack accepted over BLE; the UDP wrapping is the spec's word alone, and
/// on BLE the spec's word about a length prefix turned out wrong.
class PopledUdpClient {
  /// `crate::protocol::popled_udp::PORT`, for a device whose spec and
  /// discovery both gave none.
  static const defaultPort = 9090;

  /// The wire sequence of the first frame (`sequence.sno_base`).
  static const firstSeq = 1;

  final SpecCodec _codec;

  /// How long one send waits for the panel's acknowledgement before sending
  /// the same frame again.
  ///
  /// The vendor app waits 8 s and resends up to ten times; a control that
  /// holds a spinner for eighty seconds before saying the panel is not there
  /// helps nobody, so this is shorter and gives up sooner.
  final Duration ackTimeout;

  /// Sends of one frame before it is reported unanswered (the first included).
  final int attempts;

  int _seq = firstSeq;

  PopledUdpClient(
    this._codec, {
    this.ackTimeout = const Duration(seconds: 2),
    this.attempts = 3,
  });

  /// The sequence number the next frame carries. Starts at 1 and rises by one
  /// per frame, wrapping with the wire's 16 bits, as the spec's `sequence`
  /// block describes.
  int get nextSeq => _seq;

  int _takeSeq() {
    final seq = _seq;
    _seq = (_seq + 1) & 0xFFFF;
    return seq;
  }

  /// Send one frame body and wait for the panel to answer it.
  Future<PopledUdpReplyDto> send(String host, int port, List<int> body) async =>
      (await sendAll(host, port, [body])).single;

  /// Ask the panel its size. Null when it does not say.
  Future<({int width, int height})?> panelSize(String host, int port) async {
    final reply = await send(host, port, await _codec.popledUdpPanelQuery());
    final width = reply.width;
    final height = reply.height;
    if (width == null || height == null) return null;
    return (width: width, height: height);
  }

  /// Send [bodies] in order, each in its own frame, each waiting for its
  /// acknowledgement before the next: an upload is a sequence the panel
  /// stores step by step. [onProgress] hears how many have been taken.
  ///
  /// Throws [PopledUdpException] for a panel that refuses a frame, does not
  /// answer, or cannot be sent to.
  Future<List<PopledUdpReplyDto>> sendAll(
    String host,
    int port,
    List<List<int>> bodies, {
    StopSignal? stop,
    void Function(int done, int total)? onProgress,
  }) async {
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      throw PopledUdpException(
        '"$host" is not an address this app can send to.',
      );
    }
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException catch (e) {
      throw PopledUdpException(
        'Could not open a socket to talk to the panel (${e.message}).',
      );
    }
    // A broadcast-adopted address can be the subnet's own, so allow it.
    socket.broadcastEnabled = true;

    // Datagrams from the panel since the frame in flight was first sent. A
    // reply can span datagrams, so they are read together.
    final inbox = <Uint8List>[];
    Object? refusal;
    Completer<void>? arrived;
    void wake() {
      final waiting = arrived;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
    }

    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        // Only the panel's: anything else on the port is not its answer.
        if (datagram.address != address) return;
        inbox.add(datagram.data);
        wake();
      },
      // dart:io never throws a refused send: it returns 0 and delivers the
      // SocketException here, so listening is how a refusal is seen.
      onError: (Object e) {
        refusal ??= e;
        wake();
      },
    );

    final replies = <PopledUdpReplyDto>[];
    try {
      for (final body in bodies) {
        if (stop?.stopped ?? false) {
          throw const PopledUdpException('Stopped before the panel had it.');
        }
        final send = await _codec.popledUdpFrame(seq: _takeSeq(), body: body);
        inbox.clear();
        PopledUdpReplyDto? answer;
        for (var attempt = 0; attempt < attempts && answer == null; attempt++) {
          if (attempt > 0) {
            Log.net.debug(
              'popled frame ${send.seq} to $host unanswered; resending',
            );
          }
          for (var i = 0; i < send.datagrams.length; i++) {
            socket.send(send.datagrams[i], address, port);
            // At least one event-loop turn, so a refusal lands before the
            // next datagram, and the spec's pacing between split ones.
            await Future<void>.delayed(
              Duration(
                milliseconds: i + 1 < send.datagrams.length ? send.gapMs : 0,
              ),
            );
            final failed = refusal;
            if (failed != null) throw _sendError(failed);
          }
          answer = await _awaitReply(send.seq, inbox, () {
            final next = Completer<void>();
            arrived = next;
            return next.future;
          }, () => refusal);
        }
        if (answer == null) {
          throw const PopledUdpException(
            'The panel did not answer. Join its Wi-Fi network (its name '
            'starts with "YS"), then try again.',
          );
        }
        final status = answer.ackStatus;
        if (status != null && status != 0) {
          throw PopledUdpException('The panel refused that (status $status).');
        }
        replies.add(answer);
        onProgress?.call(replies.length, bodies.length);
      }
      return replies;
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  /// Wait out one attempt for the reply to frame [seq]: an acknowledgement or
  /// an answer carrying that sequence number. Garbage, another frame's reply,
  /// or a frame whose tail has not come yet is waited past.
  ///
  /// [arm] is called before the inbox is looked at, so a datagram landing
  /// while the codec reads completes the wait that follows instead of being
  /// missed until the deadline.
  Future<PopledUdpReplyDto?> _awaitReply(
    int seq,
    List<Uint8List> inbox,
    Future<void> Function() arm,
    Object? Function() refusal,
  ) async {
    final deadline = DateTime.now().add(ackTimeout);
    var read = 0;
    while (true) {
      final next = arm();
      final failed = refusal();
      if (failed != null) throw _sendError(failed);
      if (inbox.length > read) {
        read = inbox.length;
        final replies = await _codec.popledUdpReadReplies(
          datagrams: List.of(inbox),
        );
        for (final reply in replies) {
          if (reply.seq == seq && (reply.ackStatus != null || reply.answer)) {
            return reply;
          }
        }
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      try {
        await next.timeout(remaining);
      } on TimeoutException {
        return null;
      }
    }
  }

  static PopledUdpException _sendError(Object error) {
    if (isLocalNetworkDenied(
      error,
      isApplePlatform: Platform.isIOS || Platform.isMacOS,
    )) {
      return const PopledUdpException(
        'The phone could not send to the panel: Local Network access is off '
        'for this app (Settings → Privacy & Security → Local Network).',
      );
    }
    final detail = error is SocketException
        ? (error.osError?.message ?? error.message)
        : '$error';
    return PopledUdpException(
      'The phone could not send to the panel ($detail).',
    );
  }
}

/// A send the panel did not take, in words meant for the person holding the
/// phone.
class PopledUdpException implements UserFacingException {
  @override
  final String message;
  const PopledUdpException(this.message);
  @override
  String toString() => 'PopledUdpException: $message';
}
