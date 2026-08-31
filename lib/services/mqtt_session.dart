// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/error_text.dart';
import '../core/log.dart';
import 'spec_codec.dart';

/// One MQTT 3.1.1 session over a socket the caller opened.
///
/// The device-blind half of talking to an appliance's own broker: open,
/// authenticate, subscribe, publish, keep alive, hand back what arrives. Every
/// byte is framed by the Rust codec (`protocol::mqtt`) and every device fact —
/// which port, which credentials, which topics, what a payload means — belongs
/// to the caller, read from the spec.
///
/// Written for the Roomba and generalised for the other MQTT devices in the
/// catalogue. [RoombaMqttClient] is its first consumer and still owns the
/// Roomba's own vocabulary; a spec-driven device uses this directly.

/// A duplex byte stream to a broker, abstracted so tests answer from canned
/// bytes instead of a socket — the seam `KasaExchange` gives the TCP-JSON
/// transport, one transport up.
typedef MqttConnect = Future<MqttSocket> Function(
  String host,
  int port,
  Duration timeout,
);

/// The half of a socket this transport uses. Narrow on purpose: a fake that
/// implements three members is a fake worth writing.
abstract class MqttSocket {
  Stream<Uint8List> get incoming;
  void add(List<int> bytes);
  Future<void> close();
}

/// One PUBLISH the broker sent us.
class MqttMessage {
  final String topic;
  final String payload;
  const MqttMessage(this.topic, this.payload);
}

/// The broker could not be reached, or hung up.
class MqttConnectionException implements UserFacingException {
  @override
  final String message;

  /// True when the failure was a TLS handshake. Worth distinguishing because
  /// on some appliances it means a cipher gap no amount of retrying fixes,
  /// and the caller is the only one who knows whether that applies to its
  /// device.
  final bool handshakeFailed;

  /// True when the socket opened and the broker then never sent CONNACK.
  ///
  /// Flagged rather than left to the message text because what it MEANS is
  /// device-specific — on a Roomba it is almost always the iRobot app holding
  /// the one local client slot — and a caller that wants to say so should not
  /// have to string-match this class's wording.
  final bool ackTimedOut;

  const MqttConnectionException(
    this.message, {
    this.handshakeFailed = false,
    this.ackTimedOut = false,
  });

  @override
  String toString() => message;
}

/// The broker answered CONNACK with a refusal.
///
/// The code IS the diagnosis, and callers translate it: a device knows what
/// its own broker means by 4 or 5 far better than this layer does.
class MqttRefusedException implements UserFacingException {
  final int code;
  const MqttRefusedException(this.code);

  @override
  String get message => switch (code) {
        1 => 'The device rejected the MQTT protocol version.',
        2 => 'The device rejected this client id.',
        3 => 'The device\'s broker is not available right now.',
        4 => 'The device rejected the username or password.',
        5 => 'The device refused this client.',
        _ => 'The device refused the connection (MQTT code $code).',
      };

  @override
  String toString() => message;
}

/// The default connector: TLS, accepting a self-signed certificate.
///
/// A LAN appliance's certificate is self-signed with no chain to anything, so
/// validating it is not a thing that can succeed. Callers that must not accept
/// that pass their own connector.
Future<MqttSocket> tlsConnect(String host, int port, Duration timeout) async {
  try {
    // Ownership transfers to the adapter, which the session closes.
    // ignore: close_sinks
    final socket = await SecureSocket.connect(
      host,
      port,
      timeout: timeout,
      onBadCertificate: (_) => true,
    );
    return SocketAdapter(socket);
  } on HandshakeException catch (e) {
    throw MqttConnectionException(
      'The TLS handshake with $host:$port failed ($e).',
      handshakeFailed: true,
    );
  } on SocketException catch (e) {
    throw MqttConnectionException('Could not reach $host:$port — ${e.message}');
  } on TimeoutException {
    throw MqttConnectionException(
        '$host:$port did not answer within ${timeout.inSeconds}s.');
  }
}

/// The plain-TCP connector, for a broker that offers no TLS at all — a Dyson
/// purifier's is on port 1883 in the clear.
Future<MqttSocket> plainConnect(String host, int port, Duration timeout) async {
  try {
    // ignore: close_sinks
    final socket = await Socket.connect(host, port, timeout: timeout);
    return SocketAdapter(socket);
  } on SocketException catch (e) {
    throw MqttConnectionException('Could not reach $host:$port — ${e.message}');
  } on TimeoutException {
    throw MqttConnectionException(
        '$host:$port did not answer within ${timeout.inSeconds}s.');
  }
}

/// Which connector a broker on [port] needs, when the caller injects none.
///
/// Port 1883 is the IANA plaintext-MQTT port; a broker there speaks no TLS (a
/// Dyson purifier's is plaintext on 1883, and its TLS 8883 is closed), so a
/// [tlsConnect] handshake against it fails before login. Everything else keeps
/// [tlsConnect] — the LAN-appliance default — which preserves the brokers that
/// work today (Roomba and Bambu on 8883).
///
/// Deriving transport security from the port is a CONVENTION, not a spec
/// declaration, which is a small exception to this project's spec-driven rule.
/// The spec-gap — an explicit MQTT transport-security field — is tracked in
/// THINGS_TO_FIX; until it exists, 1883-means-plaintext is the reliable signal.
MqttConnect mqttConnectorFor(int port) =>
    port == 1883 ? plainConnect : tlsConnect;

/// Adapts a `dart:io` socket to the narrow [MqttSocket] surface.
class SocketAdapter implements MqttSocket {
  final Socket _socket;

  /// How long [close] will wait for the flush before destroying anyway.
  /// Overridable so a test of the deadline does not take two seconds.
  final Duration flushDeadline;

  SocketAdapter(
    this._socket, {
    this.flushDeadline = const Duration(seconds: 2),
  });

  @override
  Stream<Uint8List> get incoming => _socket;

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close() async {
    try {
      // flush() before destroy(): destroy discards unsent output, and the
      // packet queued right before every close is the DISCONNECT — on a
      // broker that serves one local client at a time, the difference
      // between releasing the slot now and holding it until keepalive
      // expiry locks the owner's own app out.
      //
      // Bounded, because a wedged peer advertising a zero receive window
      // never drains the flush: unbounded, this await sat on connect()'s
      // ack-timeout path (swallowing the exception the caller was owed),
      // on _connectMqtt's stale-session dispose, and on the group runner's
      // finally — a hang in a tidy-up, everywhere the tidy-up runs. The
      // DISCONNECT is best-effort by its own doc; two seconds is more
      // courtesy than a wedged broker has earned.
      await _socket.flush().timeout(flushDeadline);
    } catch (_) {
      // Already gone, or not draining; either way we are done waiting.
    }
    _socket.destroy();
  }
}

/// An open MQTT session.
class MqttSession {
  final SpecCodec _codec;
  final MqttConnect _connect;

  /// A label for the log lines, so two sessions in one app are tellable apart.
  /// Never a credential.
  final String _label;

  static const connectTimeout = Duration(seconds: 10);

  /// The default wait for CONNACK once the socket is up. Separate from the
  /// socket timeout because a device that accepts TCP and then says nothing is
  /// a different problem from one that never accepted.
  static const ackTimeout = Duration(seconds: 8);

  /// This session's CONNACK wait. Overridable because eight seconds is a
  /// guess that suits a LAN appliance and not every broker, and because a
  /// test of the timeout should not take eight seconds to run.
  final Duration ackWait;

  /// Comfortably inside the 60 s keepalive the CONNECT advertises.
  static const pingInterval = Duration(seconds: 25);

  MqttSocket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  Timer? _ping;
  final _buffer = <int>[];

  /// Bumped every time the session is torn down, so a chunk decode suspended
  /// across an `await` can tell it belongs to a session that has since closed
  /// (or been reopened) and bail before it touches the shared buffer. Without
  /// it, a close() that clears the buffer mid-parse makes the resuming
  /// `removeRange` throw, and a reopen in that window has its fresh buffer
  /// stripped by the stale decode.
  int _generation = 0;

  /// The tail of the chunk-processing chain.
  ///
  /// `Stream.listen` does not await an async callback, so without this two
  /// chunks arriving close together both run [_onBytes] and interleave at its
  /// `await`: each snapshots the buffer, then each removes what IT consumed
  /// from a buffer the other has already trimmed. The second removal runs off
  /// the end.
  ///
  /// The failure is quiet, which is what makes it worth guarding. The
  /// `RangeError` is thrown inside the async callback, and a stream discards
  /// the future its callback returns — so nothing surfaces it, and whatever
  /// that chunk carried is simply never delivered. A device that goes silent,
  /// not one that reports a problem.
  ///
  /// Chaining makes the listener synchronous — it only enqueues — so the
  /// framing state is touched by one chunk at a time.
  Future<void> _pump = Future<void>.value();
  final _messages = StreamController<MqttMessage>.broadcast();
  Completer<void>? _connected;
  var _packetId = 0;

  MqttSession({
    required SpecCodec codec,
    MqttConnect? connect,
    String label = 'mqtt',
    this.ackWait = ackTimeout,
  })  : _codec = codec,
        _connect = connect ?? tlsConnect,
        _label = label;

  /// Every PUBLISH the broker has sent since connecting.
  Stream<MqttMessage> get messages => _messages.stream;

  bool get isConnected => _socket != null;

  /// What a hang-up should say. Overridden by a device that knows something
  /// specific — a Roomba serves one client at a time, so a close means it was
  /// taken — and left alone otherwise.
  MqttConnectionException Function()? onHangUp;

  /// Open the session and wait for the broker to accept the credentials.
  ///
  /// Throws [MqttRefusedException] on a CONNACK refusal, which is a different
  /// thing from an unreachable device and must read that way: the fix (redo
  /// the pairing) is different from the fix for a network problem.
  Future<void> connect(
    String host,
    int port, {
    required String clientId,
    String? username,
    String? password,
  }) async {
    if (_socket != null) return;

    final socket = await _connect(host, port, connectTimeout);
    _socket = socket;
    _failed = false;
    _connected = Completer<void>();

    Log.hub.debug('$_label: connected to $host:$port, sending CONNECT');

    _subscription = socket.incoming.listen(
      _enqueue,
      onError: (Object error) => _fail(error),
      onDone: () => _fail(onHangUp?.call() ??
          const MqttConnectionException('The device closed the connection.')),
      cancelOnError: false,
    );

    socket.add(await _codec.mqttConnectPacket(
      clientId: clientId,
      username: username,
      password: password,
    ));

    try {
      final acknowledged = _connected!.future;
      // The timeout below gives up on this future, and then close() shuts the
      // socket — which fires onDone, which fails the very same completer. By
      // then nothing is listening, and Dart reports a completed-with-error
      // future that nobody handled as an unhandled async error: in production
      // a red screen for a device that merely did not answer, and in a test a
      // zone failure that hides the real assertion. A no-op handler on a
      // second copy marks it handled without changing what `await` below
      // sees, so a genuine refusal still propagates.
      unawaited(acknowledged.catchError((Object _) {}));
      await acknowledged.timeout(ackWait);
    } on TimeoutException {
      await close();
      throw const MqttConnectionException(
        'The device accepted the connection but never acknowledged the login.',
        ackTimedOut: true,
      );
    } catch (_) {
      // Every OTHER way this can fail — a refused CONNACK, the device hanging
      // up mid-handshake — must also release the socket. Leaving it set makes
      // the next connect() return early at the guard above, handing the caller
      // a control panel over a session the broker never authenticated: every
      // button press would go nowhere, silently. Rethrown as-is, because which
      // failure it was is what the UI reports.
      await close();
      rethrow;
    }

    Log.hub.debug('$_label: login acknowledged');

    _ping = Timer.periodic(pingInterval, (_) async {
      final open = _socket;
      if (open == null) return;
      final packet = await _codec.mqttPingreqPacket();
      // Re-check across the await, and check IDENTITY rather than null:
      // close() can land in that window, and a later connect() can even have
      // put a new socket in place. Writing to the old one throws inside a
      // timer callback, where nothing is waiting to catch it.
      if (!identical(_socket, open)) return;
      open.add(packet);
    });
  }

  /// Subscribe to one topic filter at QoS 0.
  Future<void> subscribe(String topic) async {
    final socket = _requireSocket();
    _packetId = (_packetId % 0xFFFF) + 1;
    socket.add(
        await _codec.mqttSubscribePacket(topic: topic, packetId: _packetId));
  }

  /// Publish one message at QoS 0.
  Future<void> publish(String topic, String payload) async {
    final socket = _requireSocket();
    socket.add(await _codec.mqttPublishPacket(topic: topic, payload: payload));
  }

  MqttSocket _requireSocket() {
    final socket = _socket;
    if (socket == null) {
      throw const MqttConnectionException('Not connected to the device.');
    }
    return socket;
  }

  /// Queue one chunk behind whatever is still being decoded.
  ///
  /// The `catchError` is not decoration: an unhandled throw would leave [_pump]
  /// a permanently-failed future, and every later chunk chained onto it would
  /// be dropped without ever running — a device that goes silent rather than
  /// one that reports a problem.
  void _enqueue(Uint8List chunk) {
    _pump = _pump.then((_) => _onBytes(chunk)).catchError(_fail);
  }

  /// Ceiling on unparsed bytes. The packet length prefix is device-declared
  /// — a 4-byte varint can announce 268 MB — so accumulating until a packet
  /// completes is a remote-controlled allocation. A megabyte holds any
  /// reading these devices push many times over; a stream that outgrows it
  /// has lost framing as surely as one that fails to parse.
  static const int _maxBufferedBytes = 1 << 20;

  Future<void> _onBytes(Uint8List chunk) async {
    final generation = _generation;
    if (_buffer.length + chunk.length > _maxBufferedBytes) {
      _fail(const MqttConnectionException(
          'The MQTT stream exceeded its 1 MiB receive bound.'));
      return;
    }
    _buffer.addAll(chunk);
    final MqttParsedDto parsed;
    try {
      parsed = await _codec.mqttParseIncoming(buffer: List.of(_buffer));
    } catch (e) {
      // Framing is lost; nothing after this point is readable.
      _fail(MqttConnectionException('Unreadable MQTT stream — $e'));
      return;
    }
    // close() may have run during the parse above, clearing (and a reopen
    // refilling) the buffer. This decode belongs to the session that was live
    // when it started; if that is no longer the current one, drop it rather
    // than removeRange past the emptied buffer or strip a fresh session's bytes.
    if (generation != _generation) return;
    _buffer.removeRange(0, parsed.consumed);

    for (final packet in parsed.packets) {
      switch (packet.kind) {
        case 'connack':
          if (packet.code == 0) {
            _connected?.complete();
          } else {
            // Logged as well as thrown because the throw becomes UI text that
            // deliberately does not carry a number.
            Log.hub.warning('$_label: broker refused the login, CONNACK code '
                '${packet.code}');
            _fail(MqttRefusedException(packet.code));
          }
        case 'publish':
          if (!_messages.isClosed) {
            _messages.add(MqttMessage(packet.topic, packet.payload));
          }
        default:
          break;
      }
    }
  }

  /// One failure has been reported for the current socket. Everything after
  /// the first is aftermath — queued chunks draining, the close racing the
  /// stream's own onDone — and a screen that shows one banner per aftermath
  /// event is a screen nobody reads. Reset by the next [connect].
  bool _failed = false;

  void _fail(Object error) {
    if (_failed) return;
    _failed = true;
    // Tear down FIRST: the session is spent the moment anything fails — a
    // hang-up, lost framing, a refused CONNACK, the receive bound. close()
    // nulls the socket synchronously, so isConnected is already false for
    // whoever reacts to the error and the next send REOPENS instead of
    // publishing into a corpse; it also cancels the keepalive and the
    // subscription, so a dead broker stops being pinged and a flooding one
    // stops being read. The WebSocket sibling learned this in its onDone;
    // this session had kept the dead socket cached for the screen's life.
    unawaited(close());
    final pending = _connected;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
      return;
    }
    if (!_messages.isClosed) _messages.addError(error);
  }

  /// Send DISCONNECT and let go of the socket.
  ///
  /// Idempotent, and safe to call on a session that never finished connecting.
  /// The DISCONNECT is best-effort: if the socket is already gone the device
  /// works it out on its own, and throwing here would turn a tidy-up into a
  /// user-visible error.
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    // Retire this session's generation so any chunk decode suspended across an
    // await bails when it resumes, instead of removeRange-ing the buffer we are
    // about to clear (or, after a reopen, the next session's buffer).
    _generation++;
    _ping?.cancel();
    _ping = null;
    // Cancel and detach the read subscription and buffer SYNCHRONOUSLY, before
    // the awaits below. _fail() fires close() unawaited, and a connect() that
    // reopens the session during the disconnect-write / socket.close() awaits
    // installs a fresh _subscription and refills _buffer. Cancelling/clearing
    // them only after the awaits — as this used to — would then cannibalise the
    // NEW session: it connects, its subscription is cancelled out from under it,
    // and it goes deaf until the CONNACK timeout. Same identity discipline the
    // ping timer already uses on _socket. cancel() is intentionally not awaited
    // (its future only reports cleanup, and waiting on it would reopen the very
    // window this closes) — so there is no await point between the cancel and
    // the null, keeping the swap atomic.
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _subscription = null;
    _buffer.clear();
    if (socket != null) {
      try {
        socket.add(await _codec.mqttDisconnectPacket());
      } catch (_) {
        // Already gone.
      }
      await socket.close();
    }
  }

  /// Close the session and the message stream. After this the session is spent.
  Future<void> dispose() async {
    await close();
    await _messages.close();
  }
}
