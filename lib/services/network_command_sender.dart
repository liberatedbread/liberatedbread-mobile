// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/log.dart';
import '../models/network_device.dart';
import 'ecp2_control_service.dart';
import 'http_control_service.dart';
import 'kasa_control_service.dart';
import 'mqtt_session.dart';
import 'ws_control_service.dart';
import 'rabbit_air_control_service.dart';
import 'soap_control_service.dart';
import 'spec_codec.dart';
import 'tls_trust.dart';

/// Reads the credentials stored for one device, name → value.
///
/// Asked per send rather than captured once — see
/// [NetworkCommandSender.credentials] for why that matters.
typedef CredentialReader = Future<Map<String, String>> Function();

/// Builds one sender for one device — the shape the device screen's factory
/// provider and the group runner must AGREE on. It lives here, next to the
/// constructor it mirrors, because the group runner used to re-declare it
/// inline and the two copies drifted: dropping an optional argument from a
/// function type is silent, and the group's copy lost `capabilities` for a
/// whole release of consequences (see NetworkGroupRunner's field note).
typedef NetworkCommandSenderFactory =
    NetworkCommandSender Function({
      required NetworkDevice device,
      required String specYaml,
      NetworkCapabilitiesDto? capabilities,
    });

/// Sends spec-resolved actions to one network device, over whichever of the
/// six transports each action declares — the send half of what
/// NetworkDeviceScreen used to do inline, extracted so anything headless (a
/// group run, a voice intent) can drive a device without building a widget.
///
/// One instance per device, for the same reason the screen kept this state
/// per screen: the ECP2 signed session is a per-device socket, opened lazily
/// and reused for the device's life. Callers own the lifecycle — [close]
/// releases the session, and leaving one open would hold a socket on a TV
/// that has moved on. The session is exposed rather than private because it
/// is the device's, not the send path's: the control screen reads the
/// `textedit` focus signal off the same session (see [openSignedSession]).
///
/// Deliberately stateless about *readings*: state polling, decode and
/// re-render stay with the caller, because what "the current state" means
/// differs per surface (the screen re-decodes every entity; a group run
/// reads one power field). What lives here is exactly the exchange: render
/// the command, pick the transport, and send it — over the signed session
/// first where there is one, plain ECP otherwise.
class NetworkCommandSender {
  final String host;

  /// The device's hardware address, when discovery recovered one.
  ///
  /// Used for one thing: keying the certificate pin to something that is not
  /// a DHCP lease. Null for a device that published none, which falls back to
  /// the host and says so in the key.
  final String? deviceMac;

  /// The SOAP/HTTP control port discovery established. Null for a device
  /// that advertised none — Kasa and Rabbit Air sends still work (their
  /// ports are their own), and an HTTP send throws the same transport
  /// error the screen's load path raises.
  final int? discoveredControlPort;

  /// The raw discovery port, feeding the Kasa and Rabbit Air fallbacks.
  final int? devicePort;

  /// What the device answered to at discovery. Kept for callers that route
  /// on it; the ECP2 gate itself moved to [capabilities].
  final List<String> ssdpTargets;

  /// The spec's declared control-path capabilities: whether the device
  /// speaks the signed ECP2 session, and its declared control port. Null
  /// means no declared capability — plain paths only.
  final NetworkCapabilitiesDto? capabilities;

  final String specYaml;

  final SpecCodec _codec;
  final HttpControlClient _http;
  final SoapControlClient _soap;
  final KasaControlClient _kasa;
  final RabbitAirControlClient _rabbitAir;
  final Ecp2ControlService _ecp2Service;

  /// Opens the MQTT session for a device whose commands ride that transport.
  /// Injected so a test answers from canned bytes; null means the default
  /// TLS connector.
  final MqttConnect? _mqttConnect;

  /// The credential a WebSocket device's pairing issued, when one is stored.
  /// Null means unpaired: the session then runs the spec's pairing flow, which
  /// on both televisions raises a prompt the viewer must accept.
  final String? wsCredential;

  /// Called with the NAME and value of a credential the device issued at
  /// runtime — a WebSocket pairing's token today. The name is the spec's own
  /// (`websocket.pairing.credential_name`), the same key the [useCredentials]
  /// map serves it back under on the next connect, so a caller can persist it
  /// in [DeviceCredentialStore] without knowing which transport issued it.
  ///
  /// AWAITED by the sender before its memoized credential read resets, so
  /// the very next read sees the store after the write — fired-and-forgotten,
  /// a re-read racing the save could memoize the pre-save map and the token
  /// would be "stored" but never found. A throw from the callback is logged
  /// and swallowed: the session in hand is authorised either way, and only
  /// the next open pays for the failed save.
  final Future<void> Function(String name, String value)? onCredentialIssued;

  /// Opens the WebSocket. Injected so a test answers from canned frames.
  final WsConnect? _wsConnect;

  /// Values for the `credential:`-sourced parameters this spec declares,
  /// name → value, as [DeviceCredentialStore] holds them.
  ///
  /// Spec-named throughout: `serial` on a Bambu printer, `username` on a Hue
  /// bridge, `client_id` on a Hisense set. Empty when the device has not been
  /// paired or told, and the render then fails BY NAME — which is the honest
  /// answer, rather than putting a request with a brace in it on the wire.
  ///
  /// One map for every transport, not a per-transport one. This was
  /// `mqttCredentials` and applied to exactly the MQTT send, so a `credential:`
  /// parameter on any of the four other transports silently had nothing to
  /// fill it — the same one-path-treated-and-not-its-siblings bug this file
  /// has now been bitten by three times.
  ///
  /// The MQTT session's own login rides here too, under the names the broker
  /// wants (`client_id`, `username`, `password`). Those are not `credential:`
  /// parameters of any command, but they are the same kind of thing — a value
  /// a client was given for one device — and giving them a second store would
  /// mean two places to forget when a device is removed.
  ///
  /// A reader rather than a map because the answer CHANGES while this sender
  /// lives: a person types the serial off their printer's touchscreen and the
  /// very next press has to use it. A map captured at construction would make
  /// that press fail on a value the app is already holding, and the screen
  /// would have to rebuild its sender — dropping the signed session and the
  /// broker connection with it — to pick the value up.
  ///
  /// Handed over by [useCredentials] rather than taken at construction,
  /// because whether this device needs any is the SPEC's answer and reading
  /// the spec is asynchronous. Absent — the case for all but a handful of the
  /// catalogue — means the store is never opened at all, which is the point:
  /// a device that names no credential must not touch the platform keychain
  /// on every send.
  CredentialReader? _credentials;

  NetworkCommandSender({
    required this.host,
    this.deviceMac,
    required this.discoveredControlPort,
    required this.devicePort,
    required this.ssdpTargets,
    required this.specYaml,
    this.capabilities,
    required this._codec,
    required this._http,
    required this._soap,
    required this._kasa,
    required this._rabbitAir,
    required Ecp2ControlService ecp2,
    this._mqttConnect,
    this.wsCredential,
    this.onCredentialIssued,
    this._wsConnect,
  }) : _ecp2Service = ecp2;

  /// The credentials read from the store, held once read.
  ///
  /// Memoized because the callers are a four-second state poll and every
  /// button press, and the store is the platform keychain — asking it per
  /// poll is a lot of keychain traffic for an answer that changes when a
  /// person types something and at no other time. [refreshCredentials] is
  /// that moment.
  Future<Map<String, String>>? _credentialsRead;

  /// The stored credentials, or an empty map when this sender was built
  /// without a reader (a fixture, a device whose spec names none).
  ///
  /// A store that cannot be read means "nothing stored", not a failed send.
  /// The keychain being briefly unreadable must not break a device that needs
  /// no credential at all — which is most of the catalogue — and one that does
  /// still fails visibly, by name, at the render.
  Future<Map<String, String>> _storedCredentials() {
    final reader = _credentials;
    if (reader == null) return Future.value(const {});
    // NOT latched on failure. `catchError` returns a future that COMPLETES
    // successfully with the empty map, so memoizing it cached the failure: one
    // PlatformException from a locked keystore and every later send from this
    // sender rendered with no credentials, failing forever while the card
    // showed the value as held. The memo is cleared in the handler, the way
    // `_tlsReady`'s sibling does, so the next send asks again.
    return _credentialsRead ??= reader().catchError((Object e) {
      Log.net.debug('credential store unreadable for $host: $e');
      _credentialsRead = null;
      return const <String, String>{};
    });
  }

  /// The values a render would be given, for a caller that has to decide
  /// whether an action is sendable BEFORE trying it — the screen asking what
  /// it still has to ask a person for.
  Future<Map<String, String>> currentCredentials() => _storedCredentials();

  /// The value for one of a command's parameters, resolved the way a renderer
  /// resolves it: the caller's own first, then the stored credential the
  /// action says fills it, then a credential of that literal name.
  ///
  /// Exists because the MQTT session needs two of them (`client_id`, and
  /// whatever login the broker wants) BEFORE it has a rendered request to read
  /// them out of, and the mapping between a parameter and the credential that
  /// fills it lives in the spec — carried here as `action.credentials`, the
  /// `{param, name}` pairs Rust parsed out of `source:`.
  static String? _credentialFor(
    NetworkActionDto? action,
    String param,
    Map<String, String> credentials,
    Map<String, String> values,
  ) {
    final supplied = values[param];
    if (supplied != null && supplied.isNotEmpty) return supplied;
    // A readings-only device has no action to carry a mapping; the literal
    // lookup below is all there is for it.
    if (action != null) {
      for (final declared in action.credentials) {
        if (declared.param != param) continue;
        final stored = credentials[declared.name];
        if (stored != null && stored.isNotEmpty) return stored;
      }
    }
    // A spec that names the credential exactly as the parameter (Hue's
    // `username`) needs no mapping, and a broker login that is not a command
    // parameter at all has none to find.
    return credentials[param];
  }

  /// Forget what was read, so the next send asks the store again. Called when
  /// a person supplies a credential: the value that was missing is now held,
  /// and the very next press has to use it.
  void refreshCredentials() => _credentialsRead = null;

  /// Give this sender the store to read its device's credentials from.
  ///
  /// Called once the caller knows the spec declares any — which it learns
  /// asynchronously, after this sender was built. Idempotent, and calling it
  /// again with a new reader drops what the old one had been read to say.
  void useCredentials(CredentialReader reader) {
    if (identical(_credentials, reader)) return;
    _credentials = reader;
    _credentialsRead = null;
  }

  /// The Kasa transport constant, matched as a bare string exactly as
  /// `'http'` is — one spec's actions are all one transport.
  static const kasaTransport = 'tcp-json';

  /// The TP-Link Smart Home port, the fallback when discovery did not carry
  /// one (a manually added device, a mock). Real discovery reports 9999.
  static const kasaPort = 9999;

  /// The WebSocket transport constant. A persistent socket a television's
  /// whole control surface rides.
  static const websocketTransport = 'websocket';

  /// The MQTT transport constant. A device's own broker, addressed by topic —
  /// a Hisense set's remote, a Dyson purifier's state.
  static const mqttTransport = 'mqtt';

  /// The Rabbit Air transport constant — encrypted JSON over UDP.
  static const rabbitAirTransport = 'udp';

  /// Whether the spec declares the signed ECP2 session for this device —
  /// the spec's own `ecp2:` block, surfaced through [capabilities], not a
  /// discovery-string guess.
  bool get isRoku => capabilities?.signedSession == 'ecp2';

  /// The port a control request goes to.
  ///
  /// Discovery wins, because a device that told us where it is knows better
  /// than a catalogue default — unless the SPEC says its announcement lies.
  /// `identification.advertised_port_unreliable` is that statement, and two
  /// devices make it: a Roku serves /keypress, /query, /launch and
  /// /ecp-session only on 8060 whatever its SSDP LOCATION carried (a field TV
  /// advertised 7250), and the Envoy's mDNS answer still says 80 while
  /// firmware 8.x serves the API only over HTTPS on 443 and refuses 80
  /// outright.
  ///
  /// This used to read `isRoku ? spec : discovered`, which got the Roku right
  /// and left the Envoy connecting to a port that refuses connections — the
  /// one HTTPS device the TLS work above exists for. The difference between
  /// them was never "is this a Roku"; it is a fact about the announcement,
  /// and it belongs to the spec.
  ///
  /// Either way the spec's port is the fallback when discovery captured none:
  /// 67 specs declare one, and a device added by hand used to fail every send
  /// with "did not advertise a control port" while its spec said which.
  int? get controlPort => (capabilities?.advertisedPortUnreliable ?? false)
      ? (capabilities?.defaultPort ?? discoveredControlPort)
      : (discoveredControlPort ?? capabilities?.defaultPort);

  int get _kasaHostPort => devicePort ?? kasaPort;

  int get _rabbitAirHostPort =>
      devicePort ?? RabbitAirControlClient.defaultPort;

  /// The ECP2 signed session, opened lazily and reused. Null plus
  /// [_ecp2Unavailable] means there is no ECP2 here — not a Roku, or the
  /// session itself was refused — and every request takes the plain path.
  Ecp2Session? _ecp2;
  Future<Ecp2Session?>? _ecp2Opening;
  bool _ecp2Unavailable = false;

  /// The one-time TLS policy handover to the HTTP client, memoized.
  Future<void>? _tlsReady;

  /// The MQTT session, for a device whose control surface rides one, and the
  /// connect in flight that every concurrent send waits on.
  MqttSession? _mqtt;
  Future<MqttSession>? _mqttOpening;

  /// The WebSocket session, and the open in flight every concurrent send
  /// waits on — the same guard, for the same reason.
  WsSession? _ws;
  Future<WsSession>? _wsOpening;

  /// Set by [close], so a connect still in flight closes its socket rather
  /// than handing it to nobody.
  bool _closed = false;

  /// Release the signed session, if one was opened. Safe to call twice.
  Future<void> close() async {
    _closed = true;
    // The HTTP client outlives this sender — it is a Provider, shared by every
    // surface — so what this sender taught it about this host has to go back
    // with the sender. Otherwise both its maps grow for the life of the
    // process, and a host stays on the blanket-trust fallback list forever on
    // the strength of one request made once.
    //
    // Only if this sender REGISTERED, which `_tlsReady` is the record of. The
    // client refcounts registrations per host, and forgetting unconditionally
    // decremented a count this sender had never incremented: a second sender
    // on the same host that never made an https send would, on close, drop a
    // live sender's pinned policy to zero and remove it. That sender's own
    // registration is memoized here, so it never re-registered, and its next
    // request fell through to blanket trust — an impostor accepted on a device
    // that was correctly pinned a moment earlier.
    //
    // R-037: awaited first, because `_tlsReady` is set to the future BEFORE
    // the registration it stands for has been made. A close landing in that
    // gap decremented a count nothing had incremented — so the count went
    // negative, the entry was removed, and the registration then landed and
    // put it back at one with nobody left to release it: a policy and a
    // blanket-trusted host kept for the life of the process, which is the
    // leak this release exists to prevent.
    final registering = _tlsReady;
    if (registering != null) {
      await registering.catchError((Object _) {});
      _http.forgetHost(host);
    }
    _tlsReady = null;
    final session = _ecp2;
    _ecp2 = null;
    _ecp2Opening = null;
    final mqtt = _mqtt;
    _mqtt = null;
    _mqttOpening = null;
    final ws = _ws;
    _ws = null;
    _wsOpening = null;
    await (session?.close() ?? Future<void>.value());
    // DISCONNECT rather than a dropped socket: a broker that serves one local
    // client leaves the owner's own app locked out until it notices.
    await (mqtt?.dispose() ?? Future<void>.value());
    // And every socket the WebSocket session opened, including the runtime
    // one a television handed out.
    await (ws?.dispose() ?? Future<void>.value());
  }

  /// Whether [action] rides a transport with no read-back coupling. HTTP,
  /// Kasa and Rabbit Air sends are independent; SOAP writes serialize —
  /// the Crock-Pot's read-back design — and the caller owns that gate,
  /// since "one SOAP write in flight" is a per-surface rule.
  static bool isIndependentTransport(NetworkActionDto action) =>
      action.transport == 'http' ||
      action.transport == kasaTransport ||
      action.transport == mqttTransport ||
      action.transport == websocketTransport ||
      action.transport == rabbitAirTransport;

  /// Send one resolved action with [values] as its user-owned parameters,
  /// routed by the action's own declared transport.
  ///
  /// [description] is required for a SOAP action — the envelope POSTs to
  /// the control URL the device's own description names — and unused by
  /// every other transport. [rabbitAirKey] is required for a Rabbit Air
  /// action, whose every exchange is encrypted under the per-device key.
  Future<void> sendAction(
    NetworkActionDto action,
    Map<String, String> rawValues, {
    SoapDeviceDescription? description,
    String? rabbitAirKey,
  }) async {
    // Merged once, here, so every transport's renderer sees the same values.
    // The caller's own first: a spec that names a parameter the caller also
    // set means the caller (a read-back value the send just fetched is more
    // current than anything a store holds).
    //
    // Keyed by the CREDENTIAL's name, which is usually not the parameter's:
    // Frigidaire's `applianceId` is sourced from `credential:appliance_id`.
    // The remap is Rust's (`protocol::resolve_parameter`), because the spec
    // states the correspondence and doing it here would mean this side parsing
    // `source:` strings the renderers already understand.
    final values = <String, String>{
      ...await _storedCredentials(),
      ...rawValues,
    };
    switch (action.transport) {
      case 'http':
        await _sendHttp(action, values);
      case kasaTransport:
        await _sendKasa(action, values);
      case mqttTransport:
        await _sendMqtt(action, values);
      case websocketTransport:
        await _sendWebsocket(action, values);
      case rabbitAirTransport:
        await _sendRabbitAir(action, values, rabbitAirKey);
      default:
        await _sendSoap(action, values, description);
    }
  }

  /// The plain-HTTP send: render, POST to the discovered port, done. The
  /// method and path are the whole request, and the address is the one
  /// discovery already established.
  Future<void> _sendHttp(
    NetworkActionDto action,
    Map<String, String> values,
  ) async {
    final request = await _codec.renderNetworkHttpCommand(
      specYaml: specYaml,
      commandName: action.commandName,
      values: values,
    );
    await sendHttpRequest(request);
  }

  /// The MQTT send: render the topic and payload from the spec, then publish
  /// them over a session opened once and held.
  ///
  /// The session is the device's, not the request's — a broker that serves one
  /// client at a time is held out by a client that reconnects per keypress,
  /// and the keepalive exists so the session survives between them. Closed
  /// with the sender.
  Future<void> _sendMqtt(
    NetworkActionDto action,
    Map<String, String> values,
  ) async {
    final request = await _codec.renderNetworkMqttCommand(
      specYaml: specYaml,
      commandName: action.commandName,
      // The user's values first, then the stored credentials — a spec that
      // names a parameter the caller also set means the caller.
      values: values,
    );
    final session = await _openMqtt(action, values);
    await session.publish(request.topic, request.payload);
  }

  /// Open (or reuse) the device's MQTT session, subscribe to [topics], and
  /// hand back the session's message stream for the caller to read state
  /// from.
  ///
  /// The other half of admitting `state_topic` entities to the network
  /// surface: the binding resolved, the cards drew — and nothing ever
  /// subscribed, so a Hisense set's power state and a Dyson's sensors
  /// rendered permanently unknown while a comment upstairs claimed a stream
  /// was filling them. [action] can be ANY of the device's MQTT actions: it
  /// carries the credential mapping the session's login rides, exactly as a
  /// send's does. NULL when the device declares no MQTT commands at all — a
  /// readings-only purifier — in which case the login falls back to stored
  /// credentials under the literal names `client_id`/`username`/`password`,
  /// the same names a pairing flow for such a device would store them under.
  Future<Stream<MqttMessage>> subscribeMqttState(
    NetworkActionDto? action,
    List<String> topics,
  ) async {
    // The reading half of the spec's two-spellings rule. On HTTP the device
    // answers 404 and the sender tries the other path; a subscription has no
    // 404 — a topic the firmware never publishes on is indistinguishable from
    // a quiet device — so the honest move is to listen on both and let the
    // device decide which it uses. Messages arriving on the second spelling
    // are handed on under the FIRST, because the caller subscribed to a
    // reading, not to a string.
    final second = await _fallbackTopics(topics);
    final session = await _openMqtt(action, const {});
    for (final topic in topics) {
      await session.subscribe(topic);
    }
    for (final topic in second.keys) {
      await session.subscribe(topic);
    }
    if (second.isEmpty) return session.messages;
    return session.messages.map(
      (message) => second.containsKey(message.topic)
          ? MqttMessage(second[message.topic]!, message.payload)
          : message,
    );
  }

  /// Second spelling → the topic it stands in for, for the topics the caller
  /// asked about.
  ///
  /// The spec declares its pairs unfilled, so this can only speak for a topic
  /// the spec states literally — which is what a `state_topic_fallback` is:
  /// the same reading spelled the way an older firmware generation named it
  /// (ESPHome's `/cover/door` beside `/cover/Door`), never a template. A
  /// placeholder-carrying topic arrives here already filled and matches
  /// nothing, which is the honest answer rather than a guessed substitution.
  /// Empty — and free — for every spec that declares no fallback.
  Future<Map<String, String>> _fallbackTopics(List<String> topics) async {
    final List<StateTopicFallbackDto> declared;
    try {
      declared = await _codec.specStateTopicFallbacks(specYaml: specYaml);
    } catch (e) {
      // A fallback nobody can resolve must not cost the primary its
      // subscription: the reading a spec spells once is the common case.
      Log.net.debug('could not resolve state-topic fallbacks for $host: $e');
      return const {};
    }
    final wanted = topics.toSet();
    return {
      for (final pair in declared)
        if (wanted.contains(pair.topic) && !wanted.contains(pair.fallback))
          pair.fallback: pair.topic,
    };
  }

  /// The MQTT session, opened once and reused.
  ///
  /// Unlike the ECP2 session there is no fallback path: a device whose control
  /// surface is MQTT has no second way in, so a failure to connect is the
  /// caller's to report rather than something to latch and route around.
  Future<MqttSession> _openMqtt(
    NetworkActionDto? action,
    Map<String, String> values,
  ) {
    final existing = _mqtt;
    if (existing != null && existing.isConnected) return Future.value(existing);
    // One connect in flight, shared by every caller waiting on it. MQTT is an
    // independent transport, so the screen deliberately does not serialize
    // sends: two buttons pressed together would otherwise each open a session,
    // the second overwriting the first's handle so its socket never closes —
    // and on a broker that serves one client at a time, the second CONNECT
    // evicts the first. The ECP2 path guards the same way for the same reason.
    return _mqttOpening ??= _connectMqtt(action, values).whenComplete(() {
      _mqttOpening = null;
    });
  }

  Future<MqttSession> _connectMqtt(
    NetworkActionDto? action,
    Map<String, String> values,
  ) async {
    if (_closed) {
      throw const MqttConnectionException('This device screen has closed.');
    }
    final port = devicePort ?? capabilities?.defaultPort;
    if (port == null) {
      throw const MqttConnectionException(
        'the device did not advertise a broker port',
      );
    }
    final credentials = await _storedCredentials();
    // The session must connect under the very id its topics are addressed to,
    // so the id is read the way the topic reads it: through the action's own
    // declared `credential:` mapping. Asking the store for `client_id`
    // directly is what this used to do, and on the one set in the catalogue
    // that pairs, the credential is named `mqtt_client_id` — so the lookup
    // always missed and every send reported the device as unpaired moments
    // after the user typed exactly what the card asked for.
    var clientId = _credentialFor(action, 'client_id', credentials, values);
    if (clientId == null || clientId.isEmpty) {
      if (capabilities?.mqttClientIdGenerated ?? false) {
        // A broker that authenticates on username/password and accepts any
        // client id (a Dyson purifier): synthesize a stable one instead of
        // refusing to connect. Stable per host so a reconnect reuses it.
        clientId = 'liberatedbread-$host';
      } else {
        // A set that pairs on a specific client id has no useful session
        // without it — every topic is addressed to it. Named rather than
        // improvised: a generated id would connect and then be silently
        // unauthorised there.
        throw const MqttConnectionException(
          'This device has not been paired yet — there is no client id to '
          'connect with.',
        );
      }
    }
    // A session that died leaves its stream controller open; dropping the
    // handle would leak it as surely as dropping a socket.
    final stale = _mqtt;
    _mqtt = null;
    await (stale?.dispose() ?? Future<void>.value());

    final session = MqttSession(
      codec: _codec,
      // Production injects no connector, so choose one from the spec's own
      // `mqtt.transport_security` declaration, falling back to the port
      // convention (a plaintext 1883 broker — Dyson — must NOT get the TLS
      // handshake the unconditional default used to send). A test-injected
      // connector still wins.
      connect:
          _mqttConnect ??
          selectMqttConnector(
            declared: capabilities?.mqttTransportSecurity,
            port: port,
          ),
      label: 'mqtt $host',
    );
    await session.connect(
      host,
      port,
      clientId: clientId,
      username: _credentialFor(action, 'username', credentials, values),
      password: _credentialFor(action, 'password', credentials, values),
    );
    // Published only once it is authenticated, and only if the screen is still
    // open: close() ran while this was in flight would have seen a null _mqtt
    // and closed nothing.
    if (_closed) {
      await session.dispose();
      throw const MqttConnectionException('This device screen has closed.');
    }
    return _mqtt = session;
  }

  /// The WebSocket send: render the frame from the spec, then write it to
  /// whichever socket the frame's channel names.
  ///
  /// The session is the device's rather than the request's, exactly as the
  /// MQTT one is: a television authorises a client once, per socket, and
  /// re-pairing per keypress would raise its consent prompt every time.
  Future<void> _sendWebsocket(
    NetworkActionDto action,
    Map<String, String> values,
  ) async {
    final session = await _openWs();
    await session.send(action.commandName, values);
  }

  Future<WsSession> _openWs() {
    final existing = _ws;
    if (existing != null && existing.isConnected) return Future.value(existing);
    return _wsOpening ??= _connectWs().whenComplete(() {
      _wsOpening = null;
    });
  }

  Future<WsSession> _connectWs() async {
    if (_closed) {
      throw const WsConnectionException('This device screen has closed.');
    }
    final surface = await _codec.websocketSurface(specYaml);
    if (surface == null) {
      // The resolver admits a websocket command only when the spec declares a
      // surface, so reaching here means the two disagree.
      throw const WsConnectionException(
        'This device declares no WebSocket control surface.',
      );
    }
    final stale = _ws;
    _ws = null;
    await (stale?.dispose() ?? Future<void>.value());

    // The pairing credential rides the same store map every other credential
    // does, under the spec's own name (`samsung_token`, `webos_client_key`).
    // The constructor value wins when a caller pinned one — tests, mostly —
    // and a device with no reader wired simply pairs afresh, exactly as an
    // unpaired one would. Before this lookup the production factory passed
    // nothing at all, so every screen open re-ran pairing and raised the
    // television's Allow prompt again.
    final credentialName = surface.credentialName;
    var given = wsCredential;
    if (given == null && credentialName != null) {
      given = (await _storedCredentials())[credentialName];
    }

    final session = WsSession(
      codec: _codec,
      specYaml: specYaml,
      host: host,
      surface: surface,
      credential: given,
      connect: _wsConnect,
    );
    await session.open();
    if (_closed) {
      await session.dispose();
      throw const WsConnectionException('This device screen has closed.');
    }
    // Reported after the session is authorised and only when it CHANGED: a
    // pairing that reissued the same key is not news, and a store write per
    // connect is a write per screen open.
    final issued = session.credential;
    if (issued != null && issued != given && credentialName != null) {
      final persist = onCredentialIssued;
      if (persist != null) {
        try {
          // Awaited so the refresh below cannot memoize a pre-save read;
          // caught so a locked keystore costs the NEXT open its token, not
          // this press its session (or the zone its stability).
          await persist(credentialName, issued);
        } catch (e) {
          Log.net.warning(
            'storing issued "$credentialName" for $host failed: $e',
          );
        }
        // The store just changed (or tried to) under the memoized read.
        refreshCredentials();
      }
    }
    return _ws = session;
  }

  /// Send one control request. A Roku is driven over the app's
  /// authenticated ECP2 session — the same path the official Roku app uses —
  /// for EVERYTHING, and falls back to plain ECP only when the session is
  /// unavailable (not a Roku, or ECP2 could not be opened) or cannot carry
  /// this particular request (a path with no ECP2 equivalent, or the device
  /// refuses it over the session). Every non-Roku device has only the plain
  /// path: [openSignedSession] returns null and this is a plain send on the
  /// discovered port.
  Future<String> sendHttpRequest(HttpRequestDto request) async {
    // At most two tries over the session: the one that finds it dead, and
    // one over its replacement.
    for (var attempt = 0; attempt < 2; attempt++) {
      final session = await openSignedSession();
      if (session == null) break;
      try {
        return await session.send(request);
      } on ControlRefusedException {
        // ECP2 has no equivalent for this path, or the device refused it over
        // the session — fall through to the plain path below.
        break;
      } on Ecp2Exception {
        // A session the device dropped UNDER this request (its socket
        // closed mid-round-trip) is reopened by the next openSignedSession
        // and the request retried once, so the press that discovers the
        // drop still lands. Any other falter — a timeout on a session that
        // is still up — falls back to plain ECP for this request only; the
        // session stays owned by the keyboard watch and the next send
        // tries it again.
        if (!session.isClosed) break;
      }
    }
    // The device's own TLS policy, before the first handshake. Once per
    // sender: the pin has to be in the client's hand synchronously when
    // `badCertificateCallback` fires, and reading the store on every send
    // would be work for an answer that cannot change.
    // Keyed through the shared rule, because the forget-device flow has to
    // compute the same string to erase what this writes. Neither spec that
    // asks to be pinned declares a `protocol_handler`, so the earlier
    // expression resolved to a bare `device@<ip>` for both of them — the
    // DHCP-lease keying its own comment said it was avoiding.
    final identity = identityFor(mac: deviceMac, host: host);
    // Memoized so the pin is read once, but NOT latched on failure: the read
    // goes to the platform keychain, and one PlatformException (a locked
    // keystore on a backgrounded app, a missing keyring on desktop) would
    // otherwise complete this future with an error that every later send on
    // this sender awaits and rethrows — every button on the screen dead over a
    // storage blip. `_policies[host]` is written before the read anyway, so
    // the send can proceed. Same shape as `_ecp2Opening` below, which clears
    // itself in both arms.
    _tlsReady ??= _http
        .useTlsPolicy(
          host: host,
          identity: identity,
          policy: TlsPolicy.parse(capabilities?.tlsVerification),
        )
        .catchError((Object e) {
          Log.net.warning(
            'could not load the certificate pin for $host',
            error: e,
          );
          _tlsReady = null;
        });
    await _tlsReady;

    final port = controlPort;
    if (port == null) {
      // The same wording the screen's load path raises for a portless
      // device — by the time a control is tappable there this cannot happen;
      // a headless caller (a group run) can reach it.
      throw const SoapTransportException(
        'the device did not advertise a control port',
      );
    }
    return _http.send(host, port, request);
  }

  /// The signed session, opened once and reused. Only a Roku speaks ECP2 —
  /// the check is the `roku:ecp` search target the device answered to at
  /// discovery, not a name guess. Public because the session is the device's,
  /// not the send path's: the control screen also reads the `textedit` focus
  /// signal off it, which plain ECP cannot answer.
  ///
  /// A failure that means "no ECP2 here" — the client id refused, no
  /// challenge, an [Ecp2Exception] — is latched as unavailable, so later
  /// refusals keep the plain answer instead of waiting out a fresh timeout
  /// each time. A mere transient (a socket drop, a busy TV at load) is NOT
  /// latched: it clears the in-flight handle so the next caller re-attempts,
  /// so a hiccup while the keyboard watch opens the session cannot poison the
  /// control fallback.
  ///
  /// A session the device has since dropped is not "opened once and reused":
  /// it marks itself dead when its socket closes (a reboot, sleep, a Wi-Fi
  /// blip) and fails every request at once, so it is let go and a fresh one
  /// opened. Serving the corpse instead — as this did — sent every later
  /// press down the plain-ECP fallback, which a Limited-mode Roku refuses,
  /// leaving the set uncontrollable until the screen was closed and reopened.
  Future<Ecp2Session?> openSignedSession() {
    final session = _ecp2;
    if (session != null) {
      if (!session.isClosed) return Future.value(session);
      _ecp2 = null;
      // Its socket is already gone; this releases the focus stream and the
      // subscription the dead session still holds.
      unawaited(session.close());
    }
    final port = controlPort;
    if (_closed || _ecp2Unavailable || !isRoku || port == null) {
      return Future.value(null);
    }
    return _ecp2Opening ??= _ecp2Service
        .connect(host, port)
        .then<Ecp2Session?>((opened) {
          _ecp2Opening = null;
          // Closed while the connect was in flight: close() saw a null _ecp2 and
          // closed nothing, so close it here or the socket leaks.
          if (_closed) {
            unawaited(opened.close());
            return null;
          }
          _ecp2Proven = true;
          return _ecp2 = opened;
        })
        .catchError((Object e) {
          _ecp2Opening = null;
          // A device that has authenticated once speaks ECP2; a failure to open
          // a REPLACEMENT session is the TV still rebooting or still asleep, not
          // "no ECP2 here", and latching it would put the set back on the
          // permanent fallback this reopen exists to end. Each attempt is still
          // bounded by the service's timeout and shared by concurrent callers
          // through `_ecp2Opening`.
          if (e is Ecp2Exception && !_ecp2Proven) _ecp2Unavailable = true;
          Log.net.debug('ecp2 session failed for $host: $e');
          return null;
        });
  }

  /// Whether a session on this device has ever authenticated — the
  /// difference between "no ECP2 here" (latched) and "the TV is away for a
  /// moment" (retried) when a later open fails.
  bool _ecp2Proven = false;

  /// The Kasa send: render the JSON command and write it to the plug over
  /// the socket. Like the HTTP send there is no read-back and no
  /// description to resolve; the caller re-polls `get_sysinfo` afterwards,
  /// so the switch snaps to the plug's true state whether or not the write
  /// took.
  Future<void> _sendKasa(
    NetworkActionDto action,
    Map<String, String> values,
  ) async {
    final request = await _codec.renderNetworkKasaCommand(
      specYaml: specYaml,
      commandName: action.commandName,
      values: values,
    );
    await _kasa.send(host, _kasaHostPort, request);
  }

  /// The Rabbit Air send: sync the clock, render the envelope, encrypt it
  /// under the user key, and send it as one UDP datagram. Like the Kasa
  /// send there is no read-back; the caller re-polls `get_state`
  /// afterwards, so a control snaps to the purifier's true state whether or
  /// not the write took.
  Future<void> _sendRabbitAir(
    NetworkActionDto action,
    Map<String, String> values,
    String? key,
  ) async {
    if (key == null) {
      throw const RabbitAirControlException(
        'no user key is stored for this purifier',
      );
    }
    await _rabbitAir.syncClock(
      host,
      _rabbitAirHostPort,
      specYaml: specYaml,
      userKey: key,
    );
    final request = await _codec.renderNetworkRabbitAirCommand(
      specYaml: specYaml,
      commandName: action.commandName,
      values: values,
      requestId: _rabbitAir.nextRequestId(),
      deviceTs: _rabbitAir.deviceTs(host),
    );
    await _rabbitAir.send(host, _rabbitAirHostPort, request, userKey: key);
  }

  /// The SOAP send: read back the settings this action carries but is not
  /// changing, render the envelope, and POST it to the control URL the
  /// device's own description names.
  Future<void> _sendSoap(
    NetworkActionDto action,
    Map<String, String> values,
    SoapDeviceDescription? description,
  ) async {
    if (description == null) {
      throw const SoapTransportException(
        'the device description has not been fetched',
      );
    }
    // The spec says which settings this action carries that the user is NOT
    // changing, and where to read them. Fetched fresh, not from the last
    // refresh: the device's own countdown moves between refreshes, and
    // sending a stale cook time rewinds it.
    for (final readBack in action.readBack) {
      final request = await _codec.renderNetworkStateRequest(
        specYaml: specYaml,
        stateCommand: readBack.command,
      );
      final path = description.controlPathFor(request);
      if (path == null) continue;
      final returned = await _soap.send(
        description.host,
        description.port,
        path,
        request,
        // R-039: the description's URLBase resolves its relative controlURLs,
        // and Wemo firmware really does publish LOCATION on one port and
        // URLBase on another. Every other consumer of a SoapDeviceDescription
        // passes it (adopt_service, group_runner, network_device_screen's
        // state poll); without it here the screen READ live state from the
        // URLBase port while every button press POSTed to the LOCATION port
        // and came back 404, reported as the device refusing the command.
        urlBase: description.urlBase,
      );
      final current = returned[readBack.field];
      // An empty element (`<time/>`) is a value the device did not state,
      // not a value of "": forwarding it renders an empty parameter the
      // firmware may read as 0. Leave it absent so the Rust renderer fails
      // the write instead — the same refusal a missing field gets.
      if (current != null && current.trim().isNotEmpty) {
        values.putIfAbsent(readBack.param, () => current);
      }
    }

    final request = await _codec.renderNetworkCommand(
      specYaml: specYaml,
      commandName: action.commandName,
      values: values,
    );
    final path = description.controlPathFor(request);
    if (path == null) {
      throw SoapTransportException(
        'the device does not list ${request.service}',
      );
    }
    await _soap.send(
      description.host,
      description.port,
      path,
      request,
      urlBase: description.urlBase,
    );
  }
}
