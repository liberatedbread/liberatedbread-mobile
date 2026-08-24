// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/error_text.dart';
import '../core/log.dart';
import 'mqtt_session.dart';
import 'roomba_credential_store.dart';
import 'spec_codec.dart';

/// A TLS connection to a robot: the shared MQTT socket seam under the name
/// this file has always used.
///
/// Returns a duplex byte stream: what the caller writes goes to the robot,
/// what the robot sends arrives on the stream. A loopback `SecureServerSocket`
/// stands in for a robot in the integration tests; a plain in-memory pair
/// stands in for one in the unit tests.
typedef RoombaTlsConnect = MqttConnect;

/// The half of a socket this transport uses. Narrow on purpose: a fake that
/// implements three members is a fake worth writing.
typedef RoombaTlsSocket = MqttSocket;

/// The port the robot's own MQTT broker listens on. Matches
/// `crate::protocol::roomba::PORT`.
const roombaPort = 8883;

/// The spec's `protocol_handler` for a robot. Matches
/// `crate::protocol::roomba::HANDLER_NAME`.
///
/// The transport below cannot stand in for it: a Hisense set rides `mqtt`
/// too, and only a robot wants this file's credentials, HA route and
/// one-client-slot bookkeeping.
const roombaProtocolHandler = 'roomba_mqtt';

/// The transport token entities and actions carry, and what the device screen
/// dispatches on. Matches `crate::protocol::roomba::TRANSPORT`.
const roombaTransport = 'mqtt';

/// A robot could not be reached, or refused.
///
/// [legacyTlsSuspected] is the one that matters most. Older Roomba firmware
/// negotiates only `AES128-SHA256` (`TLS_RSA_WITH_AES_128_CBC_SHA256`) and
/// expects legacy renegotiation. Dart's TLS stack is BoringSSL, which retired
/// that suite and offers no way to ask for it, so those robots cannot be
/// reached from this app at all — not because the network is wrong, and not
/// because the robot is asleep. Saying that plainly is the whole point of the
/// flag: the alternative is a user re-checking their Wi-Fi for an hour.
class RoombaConnectionException implements UserFacingException {
  @override
  final String message;

  /// True when the failure was a TLS handshake, which on this device usually
  /// means the cipher gap above rather than anything the user can fix.
  final bool legacyTlsSuspected;

  const RoombaConnectionException(
    this.message, {
    this.legacyTlsSuspected = false,
  });

  @override
  String toString() => message;
}

/// The robot answered, but not with a password.
class RoombaPasswordException implements UserFacingException {
  @override
  final String message;

  /// True when holding the HOME button again is worth trying. False when the
  /// robot said it cannot disclose locally at all, where retrying is just a
  /// slower way to reach the same dead end.
  final bool retryable;

  const RoombaPasswordException(this.message, {this.retryable = true});

  @override
  String toString() => message;
}

/// The broker refused the credentials.
class RoombaAuthException implements UserFacingException {
  final int code;
  const RoombaAuthException(this.code);

  @override
  String get message => switch (code) {
        4 => 'The robot rejected this BLID and password. If it has been '
            'factory reset since you saved them, the reset made a new '
            'password — run the handshake again.',
        5 => 'The robot refused this client. Close the iRobot app: the robot '
            'serves one local connection at a time.',
        _ => 'The robot refused the connection (MQTT code $code).',
      };

  @override
  String toString() => message;
}

/// The default connector: real TLS to a real robot.
///
/// `onBadCertificate` always accepts. The robot's certificate is self-signed
/// with no chain to anything, so validating it is not a thing that can succeed;
/// the spec says to pin on first sight instead. This app does not pin yet —
/// what it protects is a vacuum cleaner's clean/dock commands on the owner's
/// own LAN, and refusing to connect at all would be the larger harm. The
/// credential does cross this connection, which is the argument for pinning
/// later; it is recorded here rather than left implied.
Future<RoombaTlsSocket> _realTlsConnect(
  String host,
  int port,
  Duration timeout,
) async {
  try {
    // Ownership transfers to the adapter, which every caller closes in a
    // `finally` (the password handshake) or in `close()` (the MQTT client).
    // Closing it here would return a dead socket.
    // ignore: close_sinks
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: timeout,
      onBadCertificate: (_) => true,
    );
    return SocketAdapter(socket);
  } on HandshakeException catch (e) {
    throw RoombaConnectionException(
      'The TLS handshake with $host failed. Older Roomba firmware only offers '
      'the AES128-SHA256 cipher, which this phone\'s TLS library no longer '
      'supports and gives no way to request — so some robots cannot be '
      'reached from here at all. Run dorita980 or roombapy on a computer to '
      'get the password, then paste it in.\n\n($e)',
      legacyTlsSuspected: true,
    );
  } on SocketException catch (e) {
    throw RoombaConnectionException(
      'Could not reach $host:$port — ${e.message}. A 2025-model Roomba (105, '
      '205, Combo 405) refuses this port outright: those have no local broker.',
    );
  } on TimeoutException {
    throw RoombaConnectionException(
      '$host:$port did not answer within ${timeout.inSeconds}s.',
    );
  }
}

/// The account-free credential route: hold HOME, then ask the robot.
///
/// Store-free on purpose, exactly like [HuePairingService]: this proves
/// proximity and returns what the robot disclosed. Persisting it — keyed by
/// BLID, never by IP — is the caller's job, which keeps the retry loop
/// testable without a keychain.
class RoombaPasswordService {
  final SpecCodec _codec;
  final RoombaTlsConnect _connect;

  /// One attempt's ceiling. dorita980 uses ten seconds; a robot in disclosure
  /// mode answers in milliseconds, so this is generous and still fails a robot
  /// that is not listening before the user gives up on the app.
  static const attemptTimeout = Duration(seconds: 10);

  /// How many times to retry inside one disclosure window.
  ///
  /// Not politeness: j-series firmware is reported to reset the TLS connection
  /// on the first attempt or two before answering, and a client that gives up
  /// after one reset tells the user their robot cannot do something it can.
  static const defaultAttempts = 4;

  static const retryInterval = Duration(milliseconds: 600);

  RoombaPasswordService({
    required SpecCodec codec,
    RoombaTlsConnect? connect,
  })  : _codec = codec,
        _connect = connect ?? _realTlsConnect;

  /// Ask [host] for its password. Call this straight after the user releases
  /// the HOME button — the robot's disclosure window is short.
  ///
  /// [onAttempt] fires before each try with the attempt number, which is what
  /// the wizard drives its progress text from.
  Future<String> fetchPassword(
    String host, {
    int attempts = defaultAttempts,
    int port = roombaPort,
    void Function(int attempt)? onAttempt,
  }) async {
    final probe = await _codec.roombaPasswordProbe();
    Object? lastError;

    for (var attempt = 1; attempt <= attempts; attempt++) {
      onAttempt?.call(attempt);
      try {
        final reply = await _exchange(host, port, probe);
        final password = await _codec.roombaParsePasswordReply(reply: reply);
        Log.hub.info('password disclosed by robot at $host');
        return password;
      } on RoombaConnectionException catch (e) {
        // A cipher failure will fail identically every time; retrying it just
        // wastes the user's disclosure window.
        if (e.legacyTlsSuspected) rethrow;
        lastError = e;
      } on RoombaPasswordException catch (e) {
        if (!e.retryable) rethrow;
        lastError = e;
      } catch (e) {
        // The codec reports a model that cannot disclose locally at all. That
        // is not a timing problem, so retrying is only a slower way to reach
        // the same dead end — and the message already sends the user to the
        // account route.
        //
        // Matched on the message because the codec surfaces errors as text.
        // The coupling is pinned from both ends: `rust/tests/roomba_control.rs`
        // asserts that reply's error names the account route, and
        // `roomba_control_service_test.dart` asserts this branch fires on it.
        if (e.toString().contains('account')) {
          throw RoombaPasswordException(e.toString(), retryable: false);
        }
        lastError = e;
      }
      if (attempt < attempts) await Future<void>.delayed(retryInterval);
    }

    throw RoombaPasswordException(
      'The robot did not disclose a password after $attempts tries. Put it on '
      'the dock, close the iRobot app on every phone, then hold HOME until it '
      'plays the tones and try again straight away.\n\n($lastError)',
    );
  }

  /// One connect → write → read → close cycle.
  ///
  /// Reads until the robot's declared length has arrived rather than treating
  /// the first chunk as the reply: TLS delivers the two-byte header separately
  /// often enough that the published clients each grew a different workaround
  /// for it, which is exactly how their offsets came to disagree.
  Future<List<int>> _exchange(String host, int port, List<int> probe) async {
    final socket = await _connect(host, port, attemptTimeout);
    try {
      socket.add(probe);
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in socket.incoming.timeout(attemptTimeout)) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        // [0xf0][length][payload] — read until the payload is whole.
        if (bytes.length >= 2 && bytes.length >= 2 + bytes[1]) break;
      }
      return buffer.toBytes();
    } on TimeoutException {
      throw const RoombaPasswordException(
        'The robot accepted the connection but never answered. That usually '
        'means it is not in disclosure mode — hold HOME until it plays the '
        'tones, then retry immediately.',
      );
    } finally {
      await socket.close();
    }
  }
}

/// A live MQTT session with one robot.
///
/// # Hold it briefly
///
/// The robot accepts **one** local client at a time and a new connection
/// evicts the old, so a client that keeps this open holds the owner out of
/// their own iRobot app. Everything here is built for open → act → close:
/// [connect] returns once the broker has accepted, [publish] sends, and
/// [close] is expected — not optional. The control screen closes it on
/// dismissal for exactly this reason, and it is why Home Assistant's
/// integration polls rather than subscribing forever.
class RoombaMqttClient {
  final SpecCodec _codec;
  final MqttSession _session;

  /// Timings, kept here as the names this file's callers and tests use. The
  /// session owns the behaviour.
  static const connectTimeout = MqttSession.connectTimeout;
  static const ackTimeout = MqttSession.ackTimeout;
  static const pingInterval = MqttSession.pingInterval;

  final _state = StreamController<Map<String, String>>.broadcast();
  StreamSubscription<MqttMessage>? _messages;

  RoombaMqttClient({required SpecCodec codec, RoombaTlsConnect? connect})
      : _codec = codec,
        _session = MqttSession(
          codec: codec,
          connect: connect ?? _realTlsConnect,
          label: 'roomba',
        );

  /// Every state push the robot has sent since connecting, flattened to the
  /// dotted paths the spec's entities bind to.
  Stream<Map<String, String>> get state => _state.stream;

  bool get isConnected => _session.isConnected;

  /// Open the session and wait for the broker to accept the credentials.
  ///
  /// Throws [RoombaAuthException] on a refusal — which is a different thing
  /// from an unreachable robot and must read that way, because the fix (redo
  /// the handshake) is different from the fix for a network problem.
  Future<void> connect(
    String host,
    RoombaCredentials credentials, {
    int port = roombaPort,
  }) async {
    if (_session.isConnected) return;

    // The eviction signal. The robot serves ONE local client and a new
    // connection displaces the old, so a hang-up is what "something else took
    // the robot" looks like from here — the failure this whole feature keeps
    // warning about. At warning so it survives the release floor into a bug
    // report, where it is the first thing worth knowing.
    _session.onHangUp = () {
      Log.hub.warning(
        'roomba ${credentials.blid}: the robot closed the connection — '
        'another client (the iRobot app, Home Assistant) may have taken it',
      );
      return const MqttConnectionException('The robot closed the connection.');
    };

    Log.hub.debug('roomba ${credentials.blid}: connecting to $host '
        '(password ${redact(credentials.password)})');

    // Translated at this boundary rather than raised generically: what a
    // CONNACK code MEANS is the robot's own — 4 is a stale password after a
    // factory reset, 5 is the iRobot app holding the one local slot — and
    // those two sentences are the difference between a user fixing it in a
    // minute and giving up. Everything the session raises reaches the caller
    // as the Roomba-shaped exception this service has always thrown, so the
    // UI above is unchanged.
    try {
      await _session.connect(
        host,
        port,
        // The BLID is both the client id and the username; the robot refuses
        // a client id of anything else.
        clientId: credentials.blid,
        username: credentials.blid,
        password: credentials.password,
      );
    } on MqttRefusedException catch (e) {
      throw RoombaAuthException(e.code);
    } on MqttConnectionException catch (e) {
      throw RoombaConnectionException(
        e.ackTimedOut
            ? 'The robot accepted the connection but never acknowledged the '
                'login. Close the iRobot app — the robot serves one local '
                'client at a time.'
            : e.message,
        legacyTlsSuspected: e.handshakeFailed,
      );
    }

    // Subscribed and flattened here because both are the robot's: '#' rather
    // than the spec's topic names (which shape a given firmware publishes
    // locally is not settled — the spec grades the shadow topic `low`), and
    // the payload is a Roomba state document the codec knows how to flatten.
    _messages = _session.messages.listen(
      (message) async {
        final fields = await _codec.roombaStateFields(payload: message.payload);
        if (fields.isNotEmpty && !_state.isClosed) _state.add(fields);
      },
      onError: (Object error) {
        if (_state.isClosed) return;
        _state.addError(error is MqttConnectionException
            ? RoombaConnectionException(error.message)
            : error);
      },
    );

    Log.hub.debug('roomba ${credentials.blid}: login acknowledged');
    await _session.subscribe('#');
  }

  /// Render and publish one of the spec's commands.
  ///
  /// [now] is injected so a test can pin the timestamp; production passes
  /// nothing and the wall clock is used. The Rust renderer requires the value
  /// rather than defaulting it, which is what keeps a `time: 0` payload from
  /// ever reaching a robot.
  Future<void> sendCommand({
    required String specYaml,
    required String commandName,
    DateTime? now,
  }) async {
    if (!_session.isConnected) {
      throw const RoombaConnectionException('Not connected to the robot.');
    }
    final epoch =
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final request = await _codec.renderNetworkRoombaCommand(
      specYaml: specYaml,
      commandName: commandName,
      epochSeconds: epoch,
    );
    await _session.publish(request.topic, request.payload);
  }

  /// Send DISCONNECT and let go of the socket.
  ///
  /// Idempotent, and safe to call on a session that never finished connecting.
  Future<void> close() async {
    await _messages?.cancel();
    _messages = null;
    await _session.close();
  }

  /// Close the session and the state stream. After this the client is spent.
  Future<void> dispose() async {
    await close();
    await _session.dispose();
    await _state.close();
  }
}
