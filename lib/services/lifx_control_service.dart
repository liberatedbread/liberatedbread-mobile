// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// The transport half of LIFX control: move datagram bytes over UDP.
///
/// LIFX is the first device this app *controls* over UDP (the network scan
/// already discovers over UDP, but never sent a control packet). Like the SOAP
/// and HTTP control clients, this knows nothing device-specific: what to send
/// and what a reply means live in the spec and are answered by the Rust codec,
/// which hands this the exact bytes to put on the wire and decodes the bytes
/// that come back. This class only owns the socket and the sequence counter —
/// the same division as the BLE path, where the platform channel moves bytes
/// and Rust encodes/decodes them.
///
/// LIFX control is unauthenticated and, for sets, fire-and-forget: the wire is
/// lossy UDP, so a set is sent more than once and no acknowledgement is awaited
/// ([send]); a read sends a request and waits for the one reply that echoes its
/// sequence number ([request]).
class LifxControlClient {
  /// The one port every LIFX device listens on for the LAN protocol. Matches
  /// `crate::protocol::lifx::PORT`.
  static const defaultPort = 56700;

  static const _defaultTimeout = Duration(seconds: 1);
  static const _defaultRetries = 2;

  /// The destination port. Fixed at [defaultPort] for real devices; a test
  /// points it at a loopback responder on an ephemeral port.
  final int port;

  LifxControlClient({this.port = defaultPort});

  int _sequence = 0;

  /// The next sequence number, 1–255 wrapping. Zero is skipped so a reply's
  /// sequence byte of 0 (an unsolicited push, or firmware that did not echo)
  /// never matches a request we are waiting on.
  int nextSequence() {
    _sequence = (_sequence % 255) + 1;
    return _sequence;
  }

  /// Send [packet] to [host]:56700 and return without waiting for a reply.
  ///
  /// Sent [sends] times (default twice) because a dropped datagram on lossy UDP
  /// would otherwise silently fail a set. Broadcast is enabled so the same
  /// method can drive a `255.255.255.255` provisioning/discovery packet.
  Future<void> send(String host, Uint8List packet, {int sends = 2}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      socket.broadcastEnabled = true;
      final dest = InternetAddress(host);
      for (var i = 0; i < sends; i++) {
        socket.send(packet, dest, port);
        if (i + 1 < sends) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    } finally {
      socket.close();
    }
  }

  /// Send [packet] to [host]:56700 and wait for the reply whose header sequence
  /// byte (offset 23) equals [sequence]. Retries the send on timeout; returns
  /// the raw reply bytes for the Rust decoder, or null once every attempt has
  /// timed out (a write-only or unreachable device).
  Future<Uint8List?> request(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration timeout = _defaultTimeout,
    int retries = _defaultRetries,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    // RawDatagramSocket is single-subscription, so listen once for the whole
    // exchange and re-send inside that subscription rather than per attempt.
    final completer = Completer<Uint8List>();
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null || completer.isCompleted) return;
      // Correlate by source host and sequence: a datagram from this device
      // whose header echoes the sequence we asked with is our answer.
      if (datagram.address.address != host) return;
      final data = datagram.data;
      if (data.length > 23 && data[23] == sequence) {
        completer.complete(Uint8List.fromList(data));
      }
    });
    try {
      final dest = InternetAddress(host);
      for (var attempt = 0; attempt <= retries; attempt++) {
        socket.send(packet, dest, port);
        try {
          return await completer.future.timeout(timeout);
        } on TimeoutException {
          // This attempt went unanswered; loop to re-send, unless it was the
          // last, in which case fall through to the null return.
        }
      }
      return null;
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  /// Send [packet] and collect every reply that echoes [sequence] over [window].
  ///
  /// Unlike [request], which wants one answer, provisioning's `GetAccessPoints`
  /// is answered by one `StateAccessPoint` datagram per visible network, arriving
  /// over a few seconds — so this gathers them all and returns them for the codec
  /// to decode. Sent to [host] (the setup network's broadcast address), broadcast
  /// enabled.
  Future<List<Uint8List>> collect(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration window = const Duration(seconds: 5),
    int sends = 2,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final replies = <Uint8List>[];
    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final data = datagram.data;
      if (data.length > 23 && data[23] == sequence) {
        replies.add(Uint8List.fromList(data));
      }
    });
    try {
      final dest = InternetAddress(host);
      for (var i = 0; i < sends; i++) {
        socket.send(packet, dest, port);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      // Collect until quiet: StateAccessPoint replies trickle in over seconds.
      await Future<void>.delayed(window);
      return replies;
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }
}

/// The LIFX transport failed in a way worth surfacing (bind failure, an
/// unresolvable host). A timed-out [LifxControlClient.request] is not one of
/// these — it returns null, because a write-only strip is a normal outcome.
class LifxTransportException implements Exception {
  final String message;
  const LifxTransportException(this.message);
  @override
  String toString() => 'LifxTransportException: $message';
}
