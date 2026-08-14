// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'json_fields.dart';
import 'spec_codec.dart';

/// One UDP exchange with a Rabbit Air device: send [datagram] to
/// [host]:[port] and return every datagram that answers within [timeout].
///
/// Abstracted so tests can answer from canned bytes instead of a socket, the
/// way [KasaControlClient] takes an exchange. Replies from other hosts are
/// filtered out by the default implementation, not the caller.
typedef RabbitAirExchange = Future<List<Uint8List>> Function(
  String host,
  int port,
  Uint8List datagram,
  Duration timeout,
);

/// The transport half of Rabbit Air control: encrypted JSON envelopes over
/// UDP datagrams on port 9009.
///
/// The fourth network transport's sibling of [KasaControlClient] —
/// [LifxControlClient]'s UDP socket shape with a request/response
/// correlation rule. All protocol logic lives in the Rust codec (envelope
/// rendering, AES-128-CBC with the IV appended, the time-sync offset); this
/// client owns what the codec must not: the socket, the retry loop, the
/// request-id matching, and the learned device-clock offset.
///
/// The vendor client's discipline, restated: every request is sent up to
/// [attempts] times with [timeout] per attempt; a reply is matched to its
/// request by the echoed `id`, and datagrams that do not decrypt under the
/// user key or echo some other id are ignored. The device clock is learned
/// once per session via the `time_sync` command ([syncClock]) and
/// extrapolated from the local clock thereafter; any failed exchange drops
/// the learned offset, because the vendor client re-syncs whenever it
/// re-creates the socket — and an error is what re-creates it.
class RabbitAirControlClient {
  final SpecCodec _codec;
  final RabbitAirExchange _exchange;
  final Random _random;

  /// The one port every Rabbit Air purifier listens on for the LAN protocol.
  /// Matches `crate::protocol::rabbit_air::PORT`.
  static const defaultPort = 9009;

  /// Per-attempt answer window, as the vendor client sets it: a purifier on
  /// the LAN answers in milliseconds; two seconds is generous.
  static const timeout = Duration(seconds: 2);

  /// Sends per request, as the vendor client makes them — UDP is lossy, and a
  /// dropped datagram must not read as a dead purifier.
  static const attempts = 3;

  RabbitAirControlClient(this._codec,
      {RabbitAirExchange? exchange, Random? random})
      : _exchange = exchange ?? _socketExchange,
        _random = random ?? Random.secure();

  /// Learned device-clock offsets (device seconds minus local seconds), keyed
  /// by host. An entry lives until an exchange fails — the re-sync rule above.
  final Map<String, int> _clockOffsetByHost = {};

  /// The next request nonce, 0–0xFFFFFF as the vendor client seeds it. The
  /// response echoes it, which is how a reply is matched to its request.
  int nextRequestId() => _random.nextInt(0x1000000);

  static int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// The device-clock timestamp to stamp on the next request to [host]:
  /// local time plus the learned offset (zero before the first sync, which
  /// is exactly the time-sync request's own case).
  int deviceTs(String host) => _nowSecs() + (_clockOffsetByHost[host] ?? 0);

  /// Learn the device clock, once per session: send the spec's `time_sync`
  /// command and store the offset its reply teaches. A no-op when this
  /// session already synced — the vendor client syncs on socket creation,
  /// and this client's socket-per-exchange means "per session" here.
  Future<void> syncClock(
    String host,
    int port, {
    required String specYaml,
    required String userKey,
  }) async {
    if (_clockOffsetByHost.containsKey(host)) return;
    final request = await _codec.renderNetworkRabbitAirStateRequest(
      specYaml: specYaml,
      stateCommand: 'time_sync',
      requestId: nextRequestId(),
      deviceTs: deviceTs(host),
    );
    final reply = await send(host, port, request, userKey: userKey);
    _clockOffsetByHost[host] = await _codec.rabbitAirTimeSyncOffset(
      replyJson: reply,
      localNowSecs: _nowSecs(),
    );
  }

  /// Send one rendered request and return the matching reply's decrypted JSON.
  ///
  /// Retries per [attempts]/[timeout] and matches on the echoed request id;
  /// datagrams that fail to decrypt or echo another id are ignored, as the
  /// vendor client ignores them. A device that never answers throws
  /// [RabbitAirControlException] — and forgets the clock offset, so the next
  /// exchange re-syncs (the vendor client's socket-recreation rule).
  Future<String> send(
    String host,
    int port,
    RabbitAirRequestDto request, {
    required String userKey,
  }) async {
    final datagram = Uint8List.fromList(await _codec.rabbitAirEncryptDatagram(
        userKey: userKey, plaintext: request.json));
    try {
      for (var attempt = 0; attempt < attempts; attempt++) {
        final replies = await _exchange(host, port, datagram, timeout);
        for (final reply in replies) {
          final String plaintext;
          try {
            plaintext = await _codec.rabbitAirDecryptDatagram(
                userKey: userKey, datagram: reply);
          } catch (_) {
            // Not ours to read — a wrong key, a corrupt datagram, or another
            // conversation's traffic. Unmatched datagrams are ignored.
            continue;
          }
          if (rabbitAirReplyId(plaintext) == request.requestId) {
            return plaintext;
          }
        }
      }
    } on SocketException catch (e) {
      _clockOffsetByHost.remove(host);
      throw RabbitAirControlException(
          'could not reach $host:$port — ${e.message}');
    }
    _clockOffsetByHost.remove(host);
    throw RabbitAirControlException(
        '$host:$port did not answer within ${timeout.inSeconds}s '
        '($attempts attempts)');
  }
}

/// The default socket exchange: one bound [RawDatagramSocket], send once,
/// collect every datagram the device sends back until the window closes.
Future<List<Uint8List>> _socketExchange(
  String host,
  int port,
  Uint8List datagram,
  Duration timeout,
) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final replies = <Uint8List>[];
  final subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final received = socket.receive();
    if (received == null || received.address.address != host) return;
    replies.add(Uint8List.fromList(received.data));
  });
  try {
    socket.send(datagram, InternetAddress(host), port);
    await Future<void>.delayed(timeout);
    return replies;
  } finally {
    await subscription.cancel();
    socket.close();
  }
}

/// The `id` a decrypted reply echoes, or null when the reply carries none —
/// which makes it unmatched, never a state answer.
int? rabbitAirReplyId(String replyJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(replyJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final id = decoded['id'];
  return id is int ? id : null;
}

/// Flatten a Rabbit Air state reply into the name→value pairs the generic
/// entity decoder reads — the JSON counterpart of the SOAP client's XML parse.
///
/// The spec's `state_mapping` paths are rooted at the reply's `data` object
/// (`power` means reply data.power), so this lifts that object and flattens
/// it via [jsonStateFields]; the envelope's own `id` is matched to the
/// request, not read as state. A reply carrying an `error`, or no `data`
/// object, yields an empty map — "no state here", never a fabricated zero.
Map<String, String> rabbitAirStateFields(String replyJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(replyJson);
  } on FormatException {
    return const {};
  }
  if (decoded is! Map) return const {};
  final error = decoded['error'];
  if (error != null && error != false) return const {};
  final data = decoded['data'];
  if (data is! Map) return const {};
  return jsonStateFields(jsonEncode(data));
}

/// The Rabbit Air transport failed: unreachable host, no answer after every
/// attempt, or an unreadable reply.
class RabbitAirControlException implements Exception {
  final String message;
  const RabbitAirControlException(this.message);
  @override
  String toString() => 'RabbitAirControlException: $message';
}
