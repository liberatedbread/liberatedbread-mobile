// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/error_text.dart';
import 'spec_codec.dart';

/// The transport half of Yeelight LAN control: one JSON line down a TCP socket
/// on port 55443, and the line that answers it.
///
/// The sibling of [KasaControlClient], and like it this opens a connection per
/// exchange. Framing and the meaning of a reply are the Rust codec's; this owns
/// the socket and the line buffer. The one wrinkle Kasa has no version of is
/// that the lamp also pushes `{"method":"props",...}` lines on the same socket,
/// so a line is only the answer when the codec says it is.
class YeelightControlClient {
  /// `crate::protocol::yeelight::PORT`, for a device whose spec and discovery
  /// both gave none.
  static const defaultPort = 55443;

  /// One exchange's ceiling, connect and answer each.
  static const timeout = Duration(seconds: 5);

  /// Largest line this will buffer. A `get_prop` answer is a few hundred bytes,
  /// and how much arrives is the far end's choice.
  static const maxReplyBytes = 64 * 1024;

  final SpecCodec _codec;

  YeelightControlClient(this._codec);

  /// Send [request] and return the reply that answers it.
  ///
  /// Throws [YeelightControlException] for a light that cannot be reached, that
  /// never answers, or that answers with an error.
  Future<YeelightReplyDto> send(
    String host,
    int port,
    YeelightRequestDto request,
  ) async {
    final line = await _codec.yeelightEncodeLine(json: request.json);
    final YeelightReplyDto reply;
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      try {
        socket.add(line);
        await socket.flush();
        reply = await _readAnswer(socket, request.json).timeout(timeout);
      } finally {
        socket.destroy();
      }
    } on SocketException catch (e) {
      throw YeelightControlException(
        'Could not reach the light at $host:$port (${e.message}). Yeelight '
        'lights can refuse this connection until LAN Control is turned on for '
        'them in the Yeelight app.',
      );
    } on TimeoutException {
      throw YeelightControlException(
        'The light at $host:$port did not answer within '
        '${timeout.inSeconds} seconds.',
      );
    }
    if (reply.errorCode != null || reply.errorMessage != null) {
      throw YeelightControlException(
        'The light refused that: '
        '${reply.errorMessage ?? 'error ${reply.errorCode}'}.',
      );
    }
    return reply;
  }

  Future<YeelightReplyDto> _readAnswer(
    Stream<List<int>> chunks,
    String requestJson,
  ) async {
    final buffer = <int>[];
    await for (final chunk in chunks) {
      buffer.addAll(chunk);
      while (true) {
        final end = buffer.indexOf(0x0A);
        if (end < 0) break;
        final text = utf8.decode(buffer.sublist(0, end), allowMalformed: true);
        buffer.removeRange(0, end + 1);
        final reply = await _codec.yeelightDecodeReply(
          requestJson: requestJson,
          line: text,
        );
        if (reply.answersRequest) return reply;
      }
      if (buffer.length > maxReplyBytes) {
        throw const YeelightControlException(
          'The light sent a reply too long to be one.',
        );
      }
    }
    throw const YeelightControlException(
      'The light closed the connection without answering.',
    );
  }
}

/// Yeelight control failed, in words meant for the person holding the phone.
class YeelightControlException implements UserFacingException {
  @override
  final String message;
  const YeelightControlException(this.message);
  @override
  String toString() => 'YeelightControlException: $message';
}
