// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../core/error_text.dart';
import '../core/log.dart';
import 'spec_codec.dart';

/// A spec-declared WebSocket control session.
///
/// The device-blind half of driving a television: open the socket the spec's
/// `websocket:` block names, become authorised the way its `pairing` block
/// says, and write frames the Rust renderer built. Which frames, on which
/// socket, under what authorisation are all the spec's answers — this file
/// knows only how to hold a socket open.
///
/// The sibling of [MqttSession] one transport over, and of
/// [Ecp2ControlService], which stays its own thing: a Roku's session is a
/// challenge-response handshake with a device-specific secret, not something
/// a spec declares.

/// The slice of a WebSocket this uses, so tests drive the protocol from a
/// script instead of a network.
abstract class WsSocket {
  Stream<dynamic> get stream;
  void add(String frame);
  Future<void> close();

  /// Ask the transport to keep the link alive with protocol-level pings.
  ///
  /// A WebSocket ping is the protocol's own keepalive — a control frame the
  /// peer must pong, invisible to the application. The empty TEXT frame that
  /// used to stand in here was neither: it reached LG's SSAP dispatcher as a
  /// malformed request, and it kept being sent into sockets that had already
  /// closed, throwing inside a timer where nothing caught it. Fakes may
  /// ignore this; `dart:io` maps it to [WebSocket.pingInterval].
  set pingInterval(Duration? interval);
}

/// Opens one socket. Injected so a test answers from canned frames.
typedef WsConnect = Future<WsSocket> Function(
  String url,
  Map<String, String> headers,
);

/// The socket could not be opened, or the device hung up.
class WsConnectionException implements UserFacingException {
  @override
  final String message;
  const WsConnectionException(this.message);
  @override
  String toString() => message;
}

/// The device refused to authorise this client.
///
/// A different thing from an unreachable device and it must read that way: the
/// fix is on the television, in front of the person holding the phone.
class WsPairingException implements UserFacingException {
  @override
  final String message;

  /// What the spec says the viewer has to do, when it says.
  final String? promptNotes;

  const WsPairingException(this.message, {this.promptNotes});

  @override
  String toString() =>
      promptNotes == null ? message : '$message\n\n$promptNotes';
}

/// The default connector for [surface]: a real WebSocket whose certificate
/// posture is what the SPEC declares, not a blanket accept.
///
/// The televisions in the catalogue carry self-signed certificates with no
/// chain, record `tls.self_signed: true` / `verification: "none"`, and are
/// authenticated by their token or client-key — for THOSE surfaces the
/// permissive callback is the documented truth. A surface that declares
/// neither gets the platform's ordinary validation: the fields crossed the
/// FFI from day one and were then ignored here, which silently extended one
/// television's posture to every future WebSocket device.
WsConnect _connectorFor(WebSocketSurfaceDto surface) {
  final permissive =
      surface.tlsSelfSigned == true || surface.tlsVerification == 'none';
  return (String url, Map<String, String> headers) async {
    final client = HttpClient();
    if (permissive) {
      client.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      // ignore: close_sinks — ownership passes to the session, which closes it.
      final socket = await WebSocket.connect(
        url,
        headers: headers.isEmpty ? null : headers,
        customClient: client,
      );
      return _RealWsSocket(socket, client);
    } on SocketException catch (e) {
      client.close(force: true);
      throw WsConnectionException('Could not reach $url — ${e.message}');
    } on WebSocketException catch (e) {
      client.close(force: true);
      throw WsConnectionException(
          '$url refused the WebSocket upgrade — ${e.message}');
    } on HandshakeException catch (e) {
      client.close(force: true);
      throw WsConnectionException('The TLS handshake with $url failed ($e).');
    }
  };
}

class _RealWsSocket implements WsSocket {
  final WebSocket _socket;
  final HttpClient _client;
  _RealWsSocket(this._socket, this._client);

  @override
  Stream<dynamic> get stream => _socket;

  @override
  void add(String frame) => _socket.add(frame);

  @override
  set pingInterval(Duration? interval) => _socket.pingInterval = interval;

  @override
  Future<void> close() async {
    await _socket.close();
    _client.close(force: true);
  }
}

/// One open control session against a device's WebSocket surface.
class WsSession {
  final SpecCodec _codec;
  final WsConnect _connect;
  final String _specYaml;
  final String _host;
  final WebSocketSurfaceDto _surface;

  /// The credential the pairing issued, once known. Null until the device has
  /// authorised this client.
  String? _credential;

  /// The credential this session was given or has since been issued — what a
  /// caller stores so the next session skips the viewer's prompt.
  String? get credential => _credential;

  WsSocket? _socket;
  StreamSubscription<dynamic>? _subscription;

  /// Frames from the main socket, for a caller reading state. The session
  /// itself only consumes what pairing needs.
  final _frames = StreamController<String>.broadcast();
  Stream<String> get frames => _frames.stream;

  /// Sockets the device handed out at runtime, keyed by channel name. LG's
  /// remote buttons ride one of these.
  final _channelSockets = <String, WsSocket>{};

  /// The open in flight per channel, so two presses racing the first use of
  /// a runtime socket share ONE open instead of each opening their own and
  /// leaking whichever lost the map write.
  final _channelOpening = <String, Future<WsSocket>>{};
  final _channelSubscriptions = <StreamSubscription<dynamic>>[];

  var _requestId = 0;

  static const connectTimeout = Duration(seconds: 10);

  /// How long to wait for the device to authorise us. Long, deliberately: on
  /// a `register_frame` device this is a person walking to the television and
  /// pressing accept.
  static const pairingTimeout = Duration(seconds: 60);

  WsSession({
    required SpecCodec codec,
    required String specYaml,
    required String host,
    required WebSocketSurfaceDto surface,
    String? credential,
    WsConnect? connect,
  })  : _codec = codec,
        _specYaml = specYaml,
        _host = host,
        _surface = surface,
        _credential = credential,
        _connect = connect ?? _connectorFor(surface);

  bool get isConnected => _socket != null;

  /// The next correlation integer. Wraps below the point where a JSON number
  /// stops being exact; nothing correlates across a wrap.
  int get _nextRequestId => _requestId = (_requestId % 0x7FFFFFFF) + 1;

  /// Open the socket and become authorised.
  ///
  /// Tries the spec's declared address, then its fallback: LG's clients are
  /// required to, because late firmware listens on the TLS port only and
  /// answers the plain one with a refusal.
  Future<void> open() async {
    if (_socket != null) return;

    final addresses = [
      (_surface.port, _surface.scheme, _surface.path),
      if (_surface.fallbackPort != null)
        (
          _surface.fallbackPort!,
          _surface.fallbackScheme ?? _surface.scheme,
          _surface.fallbackPath ?? _surface.path,
        ),
    ];

    Object? lastFailure;
    for (final (port, scheme, path) in addresses) {
      try {
        _socket = await _connect(
          '$scheme://$_host:$port${_fillPath(path)}',
          {for (final h in _surface.headers) h.name: h.value},
        ).timeout(connectTimeout);
        break;
      } on TimeoutException catch (e) {
        lastFailure = WsConnectionException(
            '$_host:$port did not answer within ${connectTimeout.inSeconds}s.');
        Log.net.debug('ws $_host:$port timed out ($e)');
      } catch (e) {
        // A refusal on the plain port is the ordinary case on late firmware,
        // not an error worth surfacing until the fallback has also failed.
        lastFailure = e;
        Log.net.debug('ws $_host:$port failed, trying the next address: $e');
      }
    }
    final socket = _socket;
    if (socket == null) {
      throw lastFailure ?? const WsConnectionException('No address answered.');
    }

    // The waiter goes up BEFORE the socket is pumped into `_frames`, and the
    // order is load-bearing: a Samsung set speaks first, delivering its token
    // in the first frame after the upgrade. `_frames` is a broadcast stream,
    // so a frame that arrives with no listener attached is dropped — and the
    // session would then wait out its whole pairing window for a token the TV
    // already sent.
    final authorised = _startAuthorising();

    _subscription = socket.stream.listen(
      (Object? frame) {
        if (frame is String && !_frames.isClosed) _frames.add(frame);
      },
      onError: (Object e) {
        if (!_frames.isClosed) _frames.addError(WsConnectionException('$e'));
      },
      onDone: () {
        if (!_frames.isClosed) {
          _frames.addError(
              const WsConnectionException('The device closed the connection.'));
        }
        // The device hung up, so the session must stop LOOKING connected:
        // with `_socket` still set, `isConnected` stayed true, the sender
        // handed this dead session out forever, and every later press died
        // inside a closed sink as a raw StateError. Tearing down here flips
        // `isConnected`, which is what makes the next send reopen.
        unawaited(close());
      },
      cancelOnError: false,
    );

    try {
      await authorised;
    } catch (_) {
      // Every failure releases the socket. Leaving it set makes the next
      // open() return early at the guard above, handing the caller a control
      // surface over a session the device never authorised: every press would
      // go nowhere, silently.
      await close();
      rethrow;
    }

    final heartbeat = _surface.heartbeatSeconds;
    if (heartbeat != null && heartbeat > 0) {
      // The protocol's own keepalive, at the spec's declared cadence. The
      // transport owns it — see [WsSocket.pingInterval] for why this stopped
      // being a timer writing empty text frames.
      socket.pingInterval = Duration(milliseconds: (heartbeat * 1000).round());
    }
  }

  /// The name this client authorises under, in the encoding the catalogue's
  /// sets expect: standard base64 of the UTF-8 display name (samsungtvws
  /// precedent, recorded in the spec's own protocol_details). The whole
  /// Samsung flow keys on this string — a client that changes it is a new
  /// stranger and the TV prompts again — so it is a constant, not a setting.
  static final String _clientName =
      base64.encode(utf8.encode(AppConstants.appName));

  /// Fill the connect path's placeholders and query-encode what goes in.
  ///
  /// Three placeholders can appear in the catalogue: the one the spec names as
  /// its `credential_name` (Samsung's is `{samsung_token}`, which its connect
  /// path spells), plus two well-known ones — `{token}` (the same credential,
  /// kept as a fallback for any spec that still spells it that way) and
  /// `{client_name}` (this client's name, base64 of the UTF-8 display name).
  /// Filling ONLY `{credentialName}` — as this once did before `{client_name}`
  /// was handled — left the name placeholder as literal braces on the wire, and
  /// filling ONLY `{token}` misses a spec whose path spells the credential name
  /// directly; so all three are substituted and pairing works either way.
  String _fillPath(String path) {
    final credential = _credential ?? '';
    var filled = path;
    final name = _surface.credentialName;
    if (name != null) {
      filled =
          filled.replaceAll('{$name}', Uri.encodeQueryComponent(credential));
    }
    filled = filled
        .replaceAll('{token}', Uri.encodeQueryComponent(credential))
        .replaceAll('{client_name}', Uri.encodeQueryComponent(_clientName));
    return _dropEmptyQueryPairs(filled);
  }

  /// Remove query parameters whose value resolved empty — the first pairing,
  /// before any token exists. `token=` is not "no token" to every set: some
  /// read the empty string as a key and refuse it, where an absent parameter
  /// raises the Allow prompt the first connection is for.
  ///
  /// "Empty" means the pair's FIRST `=` is also its last character.
  /// Classifying by a trailing `=` alone — as this used to — deleted any
  /// literal value that merely ENDS in one, which is every base64 payload
  /// with padding; filled credentials only escaped because the query
  /// encoding turns their padding into `%3D`.
  static String _dropEmptyQueryPairs(String path) {
    final question = path.indexOf('?');
    if (question < 0) return path;
    final kept = path.substring(question + 1).split('&').where((pair) {
      final equals = pair.indexOf('=');
      return equals == -1 || equals != pair.length - 1;
    }).toList();
    final base = path.substring(0, question);
    return kept.isEmpty ? base : '$base?${kept.join('&')}';
  }

  /// Begin becoming authorised, by whichever mode the spec declares.
  ///
  /// Returns a future that completes when the device has authorised this
  /// client. Split from the awaiting so the caller can attach this BEFORE the
  /// socket starts delivering — see the ordering note in [open]. `async` is
  /// load-bearing twice over: the body still runs synchronously to its first
  /// await, preserving that ordering, and a synchronous throw on the way —
  /// `_registerFrame()` on a spec with no frame, or its jsonDecode on a
  /// malformed one — becomes a FAILED FUTURE the caller's close-on-error can
  /// catch, instead of escaping past it with the socket already open.
  Future<void> _startAuthorising() async {
    switch (_surface.pairingMode) {
      case null:
        // The socket needs no authorisation at all.
        return;
      case 'token_query':
        // The device speaks first; nothing to send.
        return _awaitIssuedCredential(send: null);
      case 'register_frame':
        return _awaitIssuedCredential(send: _registerFrame());
      case final unknown:
        // A pairing mode this build does not implement is not something to
        // improvise past: proceeding would open an unauthorised session whose
        // every command is silently dropped.
        throw WsPairingException(
          'This app does not know how to pair with this device yet '
          '(pairing mode "$unknown").',
        );
    }
  }

  /// The registration frame, with the stored credential spliced in — or the
  /// placeholder removed entirely on a first pairing, which is what tells the
  /// device to raise its prompt.
  String _registerFrame() {
    final frame = _surface.registerFrame;
    if (frame == null) {
      throw const WsPairingException(
        'This device pairs by sending a registration frame, but its spec does '
        'not carry one yet.',
      );
    }
    final credential = _credential;
    if (credential != null && credential.isNotEmpty) {
      return frame.replaceAll('{credential}', credential);
    }
    // No key yet: send the frame without the field rather than with an empty
    // string, which some devices read as a key and reject.
    final decoded = jsonDecode(frame);
    if (decoded is Map<String, dynamic>) {
      _stripCredentialPlaceholder(decoded);
      return jsonEncode(decoded);
    }
    return frame;
  }

  static void _stripCredentialPlaceholder(Map<String, dynamic> node) {
    node.removeWhere((_, value) => value == '{credential}');
    for (final value in node.values) {
      if (value is Map<String, dynamic>) _stripCredentialPlaceholder(value);
    }
  }

  /// Wait for the device to hand over the secret the spec says it issues.
  ///
  /// One rule for both modes, because they differ only in whether the client
  /// speaks first: the device answers, somewhere in that answer is the value
  /// at the spec's `issued_at` path, and until it arrives nothing else may be
  /// sent.
  Future<void> _awaitIssuedCredential({required String? send}) async {
    final path = _surface.issuedAt;
    if (path == null) {
      // The spec says a credential is issued but not where to read it; a
      // session opened on that basis would look authorised and not be.
      throw const WsPairingException(
        'This device issues a pairing credential, but its spec does not say '
        'where in the reply to find it.',
      );
    }

    final issued = Completer<String>();
    final watching = _frames.stream.listen((frame) {
      if (issued.isCompleted) return;
      final Object? decoded;
      try {
        decoded = jsonDecode(frame);
      } on FormatException {
        return; // Not the frame we are waiting for.
      }
      final value = _atPath(decoded, path);
      if (value != null && value.isNotEmpty) issued.complete(value);
    }, onError: (Object e) {
      if (!issued.isCompleted) issued.completeError(e);
    });

    try {
      // Sent after the listener is up, and only once the socket exists: a
      // `register_frame` device answers immediately and the reply must not
      // land in the gap.
      if (send != null) {
        await Future<void>.delayed(Duration.zero);
        _socket?.add(send);
      }
      _credential = await issued.future.timeout(pairingTimeout);
      Log.net.debug('ws $_host: authorised');
    } on TimeoutException {
      throw WsPairingException(
        'The device never authorised this app.',
        promptNotes: _surface.promptNotes,
      );
    } finally {
      await watching.cancel();
    }
  }

  /// Read a dotted path out of a decoded JSON document, as a string.
  static String? _atPath(Object? node, String path) {
    Object? current = node;
    for (final segment in path.split('.')) {
      if (current is! Map) return null;
      current = current[segment];
    }
    return switch (current) {
      String s => s,
      num n => '$n',
      _ => null,
    };
  }

  /// Render one of the spec's commands and write it to whichever socket its
  /// channel names.
  Future<void> send(String commandName, Map<String, String> values) async {
    if (_socket == null) {
      throw const WsConnectionException('Not connected to the device.');
    }
    final frame = await _codec.renderNetworkWebsocketCommand(
      specYaml: _specYaml,
      commandName: commandName,
      values: values,
      requestId: _nextRequestId,
    );
    final socket = await _socketFor(frame.channel);
    socket.add(frame.text);
  }

  /// The socket a channel's frames go to.
  ///
  /// Every channel rides the main socket except one the device hands out at
  /// runtime: the spec names the command whose reply carries its address, and
  /// that reply is an ordinary command on the main socket. Opened on first
  /// use and held, because asking for a new one per button press is what the
  /// address exists to avoid.
  Future<WsSocket> _socketFor(String channelName) async {
    // Re-read across send()'s render await rather than trusting its entry
    // guard: a hang-up lands exactly in that window, onDone's close() nulls
    // the field, and a bare `!` here turned "the device closed the
    // connection" into a raw null-check TypeError that no catch knows.
    final main = _socket;
    if (main == null) {
      throw const WsConnectionException('The device closed the connection.');
    }
    final channel = _surface.channels.firstWhere(
      (c) => c.name == channelName,
      // The renderer already refused an undeclared channel, so reaching here
      // means the surface and the renderer disagree — which is a bug, not a
      // device problem.
      orElse: () => throw WsConnectionException(
          'The spec declares no channel named "$channelName".'),
    );
    final obtainedBy = channel.obtainedBy;
    if (obtainedBy == null) return main;

    final existing = _channelSockets[channelName];
    if (existing != null) return existing;

    // One open per channel, however many presses race the first use: both
    // used to miss the cache, both opened a pointer socket, and the second
    // overwrote the map so the first was never closed by anything — the same
    // race the sender's `_wsOpening` guard closes one level up.
    final opening = _channelOpening[channelName];
    if (opening != null) return opening;
    final future = _openChannelSocket(channelName, channel, obtainedBy);
    _channelOpening[channelName] = future;
    try {
      return await future;
    } finally {
      // The map's value is a Future; removing it is bookkeeping, not a wait.
      unawaited(_channelOpening.remove(channelName));
    }
  }

  Future<WsSocket> _openChannelSocket(
    String channelName,
    WebSocketChannelDto channel,
    String obtainedBy,
  ) async {
    final addressPath = channel.addressPath;
    if (addressPath == null) {
      throw WsConnectionException(
          'The "$channelName" socket has no declared address path.');
    }

    // Ask on the main socket, and read the address out of the reply.
    final address = Completer<String>();
    final watching = _frames.stream.listen((frame) {
      if (address.isCompleted) return;
      try {
        final value = _atPath(jsonDecode(frame), addressPath);
        if (value != null && value.isNotEmpty) address.complete(value);
      } on FormatException {
        // Not the reply we are waiting for.
      }
    });
    try {
      await send(obtainedBy, const {});
      final url = await address.future.timeout(connectTimeout);
      // The reply names where the socket lives — and the answer must still
      // be THIS device, on a WebSocket scheme. The value is device-supplied:
      // taken verbatim, a compromised or spoofed set could point the app at
      // an arbitrary endpoint off the LAN and have it connect under the
      // session's certificate posture. The host compares case-insensitively
      // because Uri.parse lowercases it while `_host` is whatever discovery
      // recorded ("LGwebOSTV.local"); everything else stays DELIBERATELY
      // strict — an address on any other host, the set's own second
      // interface included, is refused rather than followed.
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'ws' && uri.scheme != 'wss') ||
          uri.host != _host.toLowerCase()) {
        throw WsConnectionException(
          'The device offered its "$channelName" socket at "$url" — not a '
          'WebSocket address on $_host, so it is refused.',
        );
      }
      final socket = await _connect(url, const {}).timeout(connectTimeout);
      if (_socket == null) {
        // close() ran while this connect was in flight. A socket cached now
        // would repopulate the maps on a spent session and hold its TCP
        // connection to the device for the life of the process — nothing
        // would ever close it.
        socket.stream.listen((_) {}, onError: (_) {}, cancelOnError: false);
        unawaited(socket.close().then((_) {}, onError: (_) {}));
        throw const WsConnectionException(
            'The session closed while the socket was being opened.');
      }
      // Drained even though nothing reads it: a socket whose stream has no
      // listener never delivers its done event, so closing it later would
      // hang, and any error it reports would go unobserved. LG's button
      // socket answers nothing useful — what matters is that it is a socket
      // like any other. Its onDone EVICTS the cache entry: the set
      // idle-closes this socket, and a cached corpse would be served to
      // every later press with add() silently dropping, every button on the
      // channel dead until the whole session died.
      _channelSubscriptions.add(socket.stream.listen(
        (_) {},
        onError: (Object e) =>
            Log.net.debug('ws $_host "$channelName" socket: $e'),
        onDone: () {
          if (identical(_channelSockets[channelName], socket)) {
            _channelSockets.remove(channelName);
          }
        },
        cancelOnError: false,
      ));
      // The protocol keepalive the main socket gets, for the same reason:
      // an idle button socket a set would otherwise time out.
      final heartbeat = _surface.heartbeatSeconds;
      if (heartbeat != null && heartbeat > 0) {
        socket.pingInterval =
            Duration(milliseconds: (heartbeat * 1000).round());
      }
      _channelSockets[channelName] = socket;
      return socket;
    } on TimeoutException {
      throw WsConnectionException(
        'The device did not hand over its "$channelName" socket.',
      );
    } finally {
      await watching.cancel();
    }
  }

  /// Close every socket this session opened. Idempotent.
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    final extras = List.of(_channelSockets.values);
    _channelSockets.clear();
    await _subscription?.cancel();
    _subscription = null;
    for (final extra in _channelSubscriptions) {
      await extra.cancel();
    }
    _channelSubscriptions.clear();
    for (final extra in extras) {
      try {
        await extra.close();
      } catch (_) {
        // Already gone.
      }
    }
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {
        // Already gone.
      }
    }
  }

  /// Close the session and the frame stream. After this the session is spent.
  Future<void> dispose() async {
    await close();
    await _frames.close();
  }
}
