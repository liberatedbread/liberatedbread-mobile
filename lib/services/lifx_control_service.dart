// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'real_network_scan_service.dart' show isLocalNetworkDenied;

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

  /// Bind the sending socket, as a typed failure rather than a raw one.
  ///
  /// R-044: this class documents `LifxTransportException` for exactly two
  /// conditions — a bind that fails and a host that cannot be parsed — and
  /// then threw neither, so a caller following the contract caught nothing
  /// and a `SocketException` or `ArgumentError` reached the UI as an
  /// unclassified error. Both are funnelled here.
  Future<RawDatagramSocket> _bind() async {
    try {
      return await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } on SocketException catch (e) {
      throw LifxTransportException(
        'could not open a socket to talk to the light (${e.message}).',
      );
    }
  }

  /// Parse [host] as an address, as a typed failure. LIFX is addressed by IP
  /// — discovery reports one — so a name here is a caller error, not a
  /// lookup to attempt on the device's behalf.
  static InternetAddress _address(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      throw LifxTransportException(
        '"$host" is not an address this app can '
        'send to; LIFX devices are reached by IP.',
      );
    }
    return address;
  }

  /// A send the OS refused, as the typed failure this class documents.
  ///
  /// dart:io never throws a refused send from `send()`: it returns 0, puts
  /// the SocketException on the socket's stream a microtask later and closes
  /// the socket. Every listener here routes that error through this, so iOS
  /// Local Network denial reads as that — not as a silent "write-only"
  /// light, an empty setup network, or an uncaught zone error.
  static LifxTransportException _sendError(Object error) {
    if (isLocalNetworkDenied(
      error,
      isApplePlatform: Platform.isIOS || Platform.isMacOS,
    )) {
      return const LifxTransportException(
        'the phone could not send to the light: Local Network access is off '
        'for this app (Settings → Privacy & Security → Local Network).',
      );
    }
    final detail = error is SocketException
        ? (error.osError?.message ?? error.message)
        : '$error';
    return LifxTransportException(
      'the phone could not send to the light ($detail).',
    );
  }

  /// Send [packet] to [host]:56700 and return without waiting for a reply.
  ///
  /// Sent [sends] times (default twice) because a dropped datagram on lossy UDP
  /// would otherwise silently fail a set. Broadcast is enabled so the same
  /// method can drive a `255.255.255.255` provisioning/discovery packet. A
  /// send the OS refuses throws [LifxTransportException].
  Future<void> send(String host, Uint8List packet, {int sends = 2}) async {
    final socket = await _bind();
    // Listened to only so a refused send is seen: without a listener the
    // error is never delivered and the set silently does nothing.
    Object? sendError;
    final subscription = socket.listen(
      (_) {},
      onError: (Object e) => sendError ??= e,
    );
    try {
      socket.broadcastEnabled = true;
      final dest = _address(host);
      for (var i = 0; i < sends && sendError == null; i++) {
        socket.send(packet, dest, port);
        // One event-loop turn lets a refusal land before the next send, and
        // before the socket is closed below.
        await Future<void>.delayed(
          i + 1 < sends ? const Duration(milliseconds: 40) : Duration.zero,
        );
      }
      final failed = sendError;
      if (failed != null) throw _sendError(failed);
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }

  /// Send [packet] to [host]:56700 and wait for the reply whose header sequence
  /// byte (offset 23) equals [sequence]. Retries the send on timeout; returns
  /// the raw reply bytes for the Rust decoder, or null once every attempt has
  /// timed out (a write-only or unreachable device). A send the OS refuses
  /// throws [LifxTransportException] instead.
  Future<Uint8List?> request(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration timeout = _defaultTimeout,
    int retries = _defaultRetries,
  }) async {
    final socket = await _bind();
    // RawDatagramSocket is single-subscription, so listen once for the whole
    // exchange and re-send inside that subscription rather than per attempt.
    final completer = Completer<Uint8List>();
    var failed = false;
    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null || completer.isCompleted) return;
        // Correlate by source host and sequence: a datagram from this device
        // whose header echoes the sequence we asked with is our answer.
        if (datagram.address.address != host) return;
        final data = datagram.data;
        // R-160: the 23 is the LIFX header's sequence byte, whose layout lives
        // in `lifx::parse_header`. It is read here rather than asked for,
        // deliberately: correlation has to work on a build whose native library
        // failed to load — main() carries on without it by design — and a
        // transport that silently stops matching replies in that case is worse
        // than a restated offset. What the offset must not do is DRIFT, so
        // `lifx_control_service_test.dart` decodes a crafted frame through Rust
        // and requires the two to agree; a layout change fails there.
        if (data.length > 23 && data[23] == sequence) {
          completer.complete(Uint8List.fromList(data));
        }
      },
      // A refused send ends the exchange as a transport failure at once.
      // Unhandled, it was an uncaught zone error, every retry sent into the
      // closed socket, and the light read as write-only after 3 s.
      onError: (Object e) {
        failed = true;
        if (!completer.isCompleted) completer.completeError(_sendError(e));
      },
    );
    try {
      final dest = _address(host);
      for (var attempt = 0; attempt <= retries && !failed; attempt++) {
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
  /// [matchSequence] false keeps every well-formed datagram regardless of the
  /// header's echoed sequence. On a setup AP there is exactly one device and
  /// nothing else on the wire, and some firmware answers `GetService`/
  /// `GetAccessPoints` with a zeroed sequence byte — filtering on the echo
  /// there drops the only device on the network. The decoder is the real
  /// filter: a datagram that is not the message we asked for fails to decode
  /// and is discarded by the caller. Leave it true on the shared LAN.
  Future<List<Uint8List>> collect(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration window = const Duration(seconds: 5),
    int sends = 2,
    bool matchSequence = true,
  }) async {
    final socket = await _bind();
    socket.broadcastEnabled = true;
    final replies = <Uint8List>[];
    // A refused send (iOS Local Network off, no route to the setup AP's
    // broadcast address) used to be an uncaught zone error, leave the socket
    // dead for the whole window and return [] — which the adopt flow reads
    // as "no device / no networks", the wrong diagnosis.
    final refused = Completer<Object>();
    final subscription = socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final data = datagram.data;
        if (data.length > 23 && (!matchSequence || data[23] == sequence)) {
          replies.add(Uint8List.fromList(data));
        }
      },
      onError: (Object e) {
        if (!refused.isCompleted) refused.complete(e);
      },
    );
    try {
      final dest = _address(host);
      for (var i = 0; i < sends && !refused.isCompleted; i++) {
        socket.send(packet, dest, port);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      // Collect until quiet: StateAccessPoint replies trickle in over seconds.
      // A refusal ends the wait: nothing more can arrive on a closed socket.
      if (!refused.isCompleted) {
        await Future.any([Future<void>.delayed(window), refused.future]);
      }
      if (refused.isCompleted) throw _sendError(await refused.future);
      return replies;
    } finally {
      await subscription.cancel();
      socket.close();
    }
  }
}

/// The LIFX transport failed in a way worth surfacing (bind failure, an
/// unresolvable host, a send the OS refused). A timed-out
/// [LifxControlClient.request] is not one of these — it returns null,
/// because a write-only strip is a normal outcome.
class LifxTransportException implements Exception {
  final String message;
  const LifxTransportException(this.message);
  @override
  String toString() => 'LifxTransportException: $message';
}
