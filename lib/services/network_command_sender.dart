// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/log.dart';
import 'ecp2_control_service.dart';
import 'http_control_service.dart';
import 'kasa_control_service.dart';
import 'rabbit_air_control_service.dart';
import 'soap_control_service.dart';
import 'spec_codec.dart';

/// Sends spec-resolved actions to one network device, over whichever of the
/// four transports each action declares — the send half of what
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

  /// The SOAP/HTTP control port discovery established. Null for a device
  /// that advertised none — Kasa and Rabbit Air sends still work (their
  /// ports are their own), and an HTTP send throws the same transport
  /// error the screen's load path raises.
  final int? discoveredControlPort;

  /// The raw discovery port, feeding the Kasa and Rabbit Air fallbacks.
  final int? devicePort;

  /// What the device answered to at discovery — the ECP2 gate: only a
  /// device that answered `roku:ecp` is offered the signed session.
  final List<String> ssdpTargets;

  final String specYaml;

  final SpecCodec _codec;
  final HttpControlClient _http;
  final SoapControlClient _soap;
  final KasaControlClient _kasa;
  final RabbitAirControlClient _rabbitAir;
  final Ecp2ControlService _ecp2Service;

  NetworkCommandSender({
    required this.host,
    required this.discoveredControlPort,
    required this.devicePort,
    required this.ssdpTargets,
    required this.specYaml,
    required SpecCodec codec,
    required HttpControlClient http,
    required SoapControlClient soap,
    required KasaControlClient kasa,
    required RabbitAirControlClient rabbitAir,
    required Ecp2ControlService ecp2,
  })  : _codec = codec,
        _http = http,
        _soap = soap,
        _kasa = kasa,
        _rabbitAir = rabbitAir,
        _ecp2Service = ecp2;

  /// The Kasa transport constant, matched as a bare string exactly as
  /// `'http'` is — one spec's actions are all one transport.
  static const kasaTransport = 'tcp-json';

  /// The TP-Link Smart Home port, the fallback when discovery did not carry
  /// one (a manually added device, a mock). Real discovery reports 9999.
  static const kasaPort = 9999;

  /// The Rabbit Air transport constant — encrypted JSON over UDP.
  static const rabbitAirTransport = 'udp';

  /// Roku control — plain ECP and the ECP2 session alike — always lives on
  /// 8060 (the spec's `default_port`), whatever port the SSDP LOCATION
  /// carried. A field TV answered discovery with a 7250 root-description
  /// port, but /keypress, /query, /launch and /ecp-session are only ever
  /// served on 8060.
  static const rokuEcpPort = 8060;

  /// A Roku, by the `roku:ecp` target it answered at discovery — the same
  /// test the signed session is gated on, not a name guess.
  bool get isRoku => ssdpTargets.contains('roku:ecp');

  /// The port a control request goes to. A Roku is pinned to its ECP port;
  /// every other device uses the port discovery captured from its LOCATION.
  int? get controlPort => isRoku ? rokuEcpPort : discoveredControlPort;

  int get _kasaHostPort => devicePort ?? kasaPort;

  int get _rabbitAirHostPort =>
      devicePort ?? RabbitAirControlClient.defaultPort;

  /// The ECP2 signed session, opened lazily and reused. Null plus
  /// [_ecp2Unavailable] means there is no ECP2 here — not a Roku, or the
  /// session itself was refused — and every request takes the plain path.
  Ecp2Session? _ecp2;
  Future<Ecp2Session?>? _ecp2Opening;
  bool _ecp2Unavailable = false;

  /// Set by [close], so a connect still in flight closes its socket rather
  /// than handing it to nobody.
  bool _closed = false;

  /// Release the signed session, if one was opened. Safe to call twice.
  Future<void> close() async {
    _closed = true;
    final session = _ecp2;
    _ecp2 = null;
    _ecp2Opening = null;
    await (session?.close() ?? Future<void>.value());
  }

  /// Whether [action] rides a transport with no read-back coupling. HTTP,
  /// Kasa and Rabbit Air sends are independent; SOAP writes serialize —
  /// the Crock-Pot's read-back design — and the caller owns that gate,
  /// since "one SOAP write in flight" is a per-surface rule.
  static bool isIndependentTransport(NetworkActionDto action) =>
      action.transport == 'http' ||
      action.transport == kasaTransport ||
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
    Map<String, String> values, {
    SoapDeviceDescription? description,
    String? rabbitAirKey,
  }) async {
    switch (action.transport) {
      case 'http':
        await _sendHttp(action, values);
      case kasaTransport:
        await _sendKasa(action, values);
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
      NetworkActionDto action, Map<String, String> values) async {
    final request = await _codec.renderNetworkHttpCommand(
      specYaml: specYaml,
      commandName: action.commandName,
      values: values,
    );
    await sendHttpRequest(request);
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
    final session = await openSignedSession();
    if (session != null) {
      try {
        return await session.send(request);
      } on ControlRefusedException {
        // ECP2 has no equivalent for this path, or the device refused it over
        // the session — fall through to the plain path below.
      } on Ecp2Exception {
        // The session faltered; fall back to plain ECP for this request. A
        // socket that truly died self-closes and throws fast next time, so the
        // fallback stays cheap and the keyboard watch keeps owning the session.
      }
    }
    final port = controlPort;
    if (port == null) {
      // The same wording the screen's load path raises for a portless
      // device — by the time a control is tappable there this cannot happen;
      // a headless caller (a group run) can reach it.
      throw const SoapTransportException(
          'the device did not advertise a control port');
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
  Future<Ecp2Session?> openSignedSession() {
    final session = _ecp2;
    if (session != null) return Future.value(session);
    final port = controlPort;
    if (_closed || _ecp2Unavailable || !isRoku || port == null) {
      return Future.value(null);
    }
    return _ecp2Opening ??=
        _ecp2Service.connect(host, port).then<Ecp2Session?>((opened) {
      _ecp2Opening = null;
      // Closed while the connect was in flight: close() saw a null _ecp2 and
      // closed nothing, so close it here or the socket leaks.
      if (_closed) {
        unawaited(opened.close());
        return null;
      }
      return _ecp2 = opened;
    }).catchError((Object e) {
      _ecp2Opening = null;
      if (e is Ecp2Exception) _ecp2Unavailable = true;
      Log.net.debug('ecp2 session failed for $host: $e');
      return null;
    });
  }

  /// The Kasa send: render the JSON command and write it to the plug over
  /// the socket. Like the HTTP send there is no read-back and no
  /// description to resolve; the caller re-polls `get_sysinfo` afterwards,
  /// so the switch snaps to the plug's true state whether or not the write
  /// took.
  Future<void> _sendKasa(
      NetworkActionDto action, Map<String, String> values) async {
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
          'no user key is stored for this purifier');
    }
    await _rabbitAir.syncClock(host, _rabbitAirHostPort,
        specYaml: specYaml, userKey: key);
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
          'the device description has not been fetched');
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
      final returned =
          await _soap.send(description.host, description.port, path, request);
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
          'the device does not list ${request.service}');
    }
    await _soap.send(description.host, description.port, path, request);
  }
}
