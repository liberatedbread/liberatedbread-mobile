// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

/// Wait at most [limit] for a WebSocket connect, and close whatever socket
/// the connect hands back after the deadline has passed.
///
/// A bare `Future.timeout` only abandons the future: it does not cancel the
/// connect. A device that finishes the upgrade on the eleventh second hands
/// back a live socket that nobody listens to or closes — and with it the
/// HttpClient underneath and a session slot on the device. The camera
/// keepalive retries on a timer, so a slow camera piled up one such socket
/// per retry. Every WebSocket connect with a deadline goes through here so
/// the late-close cannot drift between call sites again.
///
/// [discard] releases a late socket; it must drain the stream before
/// closing (see [discardWebSocket]), because a socket whose stream has no
/// listener never delivers its done event. On timeout this throws
/// [TimeoutException] named [what].
Future<T> connectWithinDeadline<T>(
  Future<T> pending,
  Duration limit, {
  required Future<void> Function(T socket) discard,
  String what = 'websocket connect',
}) => pending.timeout(
  limit,
  onTimeout: () {
    unawaited(pending.then(discard).then((_) {}, onError: (Object _) {}));
    throw TimeoutException(what, limit);
  },
);

/// Release a dart:io [WebSocket] nobody will use: drain it (so close can
/// complete and a late error is observed rather than uncaught), then close.
Future<void> discardWebSocket(WebSocket socket) {
  socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
  return socket.close();
}
