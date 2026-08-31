// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import '../core/unit_display.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/entity_icon.dart';
import '../core/entity_keys.dart';
import '../core/sensor_reading_level.dart';
import '../core/error_text.dart';
import '../core/log.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/roomba_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/http_control_service.dart';
import '../services/json_fields.dart';
import '../services/mqtt_session.dart' show MqttMessage;
import '../services/kasa_control_service.dart';
import '../services/network_command_sender.dart';
import '../services/query_source_reader.dart';
import '../services/rabbit_air_control_service.dart';
import '../services/rabbit_air_control_transport.dart';
import '../services/soap_control_service.dart';
import '../services/roomba_control_service.dart';
import '../services/roomba_controller.dart';
import '../services/spec_codec.dart';
import '../services/tls_trust.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/camera_view_card.dart';
import '../widgets/device_credentials_card.dart';
import '../widgets/entity_cards/sensor_level_chip.dart';
import '../widgets/network_light_card.dart';
import '../widgets/power_strip_icon.dart';
import '../widgets/rabbit_air_controls_panel.dart';
import '../widgets/unclaimed_actions.dart';

/// Controls for a network device whose matched spec declares entities — the
/// Wi-Fi counterpart of the BLE device screen's typed control panel.
///
/// For a SOAP device, the flow on every load and after every write is the
/// same three steps, each owned by the layer that knows it:
/// 1. fetch the device's own `setup.xml` and resolve control URLs from its
///    service list (transport — [SoapControlClient]);
/// 2. render and send one state request per distinct `state_command`
///    (what to send comes from the spec, via the codec);
/// 3. hand the returned values back to the codec per entity for decoding.
///
/// Writes carrying `read_back` parameters re-read the state they depend on
/// immediately before sending: the Crock-Pot's set-mode action carries the
/// cook time with it, and sending a stale one silently rewinds the timer.
///
/// A plain-HTTP action (a Roku remote key) skips all of that: there is no
/// description to fetch and no state to poll — the rendered method and path
/// are the whole exchange, sent through [HttpControlClient]. Plain HTTP can
/// also BE the state poll (the Envoy's `GET /api/v1/production`): the
/// command's declared transport decides, and the JSON reply is flattened to
/// dotted name→value pairs for the same decoder. Which path a send takes is
/// the action's own `transport`, so one spec may mix both.
class NetworkDeviceScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;

  /// The matched spec's `device.category` and `specKeyFor` identity, when the
  /// opener knew them — used only to pick the device-targeted ad banner (label
  /// supplies for a label printer, filters for a Rabbit Air). Null falls back
  /// to the global promotion.
  final String? category;
  final String? specKey;

  const NetworkDeviceScreen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
  });

  @override
  ConsumerState<NetworkDeviceScreen> createState() =>
      _NetworkDeviceScreenState();
}

class _NetworkDeviceScreenState extends ConsumerState<NetworkDeviceScreen> {
  SoapDeviceDescription? _description;
  final Map<String, Map<String, String>> _stateByCommand = {};
  final Map<String, NetworkReadingDto?> _readings = {};

  /// Slider positions the user has set but the device has not yet confirmed,
  /// shown until the next state decode supersedes them.
  final Map<String, double> _pendingSetpoints = {};

  /// The raw (unflattened) reply per state command, kept because an instanced
  /// entity — a Kasa power strip's outlets — enumerates its children straight
  /// from the reply's own structure, which the flattener discards.
  final Map<String, String> _rawStateReply = {};

  /// Children enumerated per instanced entity, and each child's role readings
  /// keyed "entityName/childId". Populated for a Kasa strip; empty for a
  /// single-outlet plug (no `children`), whose plain switch shows instead.
  final Map<String, List<NetworkInstanceDto>> _instances = {};
  final Map<String, Map<String, NetworkReadingDto>> _instanceReadings = {};

  /// The brightness the user is dragging on a Kasa light's slider, held locally
  /// until they let go (then sent). Null when not dragging — the slider shows
  /// the device's reported brightness.

  /// Names of entities a send is in flight for, disabling their controls.
  ///
  /// A set rather than one slot because remote buttons overlap: a volume
  /// press must not wait for a slow PowerOn to settle, and two in-flight
  /// sends clearing one shared flag would re-enable both early.
  final Set<String> _sending = {};

  /// Options fetched from the device for entities that declare an
  /// `options_source` — the installed-channel list — by entity name.
  final Map<String, List<QueryEntry>> _fetchedOptions = {};

  /// Which of those options is current, by entity name. Absent means the
  /// device named none: on Roku's home screen no channel is foreground, and
  /// showing nothing selected is the true answer.
  final Map<String, String?> _currentOption = {};

  /// Whether the device refused a command while its queries kept answering —
  /// the "control by mobile apps" gate. Sticky for the screen's life so the
  /// note stays up after the error text is replaced by the next attempt.
  bool _controlRefused = false;

  /// Credentials this device's spec names, that nothing has supplied yet and
  /// that no declared setup flow can mint — the ones a person has to type.
  ///
  /// Recomputed whenever one is saved, so entering the last of them makes the
  /// card go away rather than leaving a prompt for a value already held.
  List<NetworkCredentialDto> _missingCredentials = const [];

  /// The per-device send pipeline — transport dispatch and the lazily
  /// opened ECP2 signed session both live in it, so a group run can drive
  /// the same device the same way without this widget. The session is the
  /// device's rather than the send path's, which is why the keyboard watch
  /// below reads its `textedit` signal off the very same one.
  late final NetworkCommandSender _sender;

  /// Whether the device has a text field focused, so its on-screen keyboard is
  /// actually usable — and, through that, where the keyboard card sits:
  /// `true` places it high, right under the controls and above the channel
  /// picker; `null` (unknown — no signal yet, or none to be had because it is
  /// not a Roku or ECP2 was refused) parks it at the very foot, below the
  /// channels, shown rather than hide a keyboard the user might need; `false`,
  /// the device saying "nothing is focused", shows it nowhere. Driven by the
  /// ECP2 session's textedit state, the one place this can be known: plain ECP
  /// has no such query. See [_watchKeyboard] and the build's placement.
  bool? _keyboardFocused;
  StreamSubscription<bool>? _keyboardSub;
  Timer? _keyboardPoll;

  /// Background re-poll of device state, so a device toggled physically or from
  /// another app updates here without a manual Refresh. Started after the first
  /// successful load, only for devices that actually expose state. [_polling]
  /// guards against a slow tick stacking on the one before it.
  Timer? _statePoll;

  /// The pushed-state stream of a non-Roomba MQTT device, held so dispose
  /// stops listening when the screen goes.
  StreamSubscription<MqttMessage>? _mqttStateSub;

  /// A pending re-subscribe after the MQTT state stream errored (a broker drop),
  /// and the growing backoff between attempts. Without this a transient drop
  /// froze every pushed reading until the screen was reopened.
  Timer? _mqttRetry;
  Duration _mqttBackoff = Duration.zero;
  bool _polling = false;

  /// Bumped on every write to [_keyboardFocused]. A poll captures it before its
  /// round trip and discards its answer if it changed meanwhile — so a stale
  /// poll reply cannot clobber a fresher `textedit` notice that arrived while
  /// the poll was in flight.
  int _keyboardStateGen = 0;

  /// Names of entities whose device-sourced list never arrived — the query
  /// failed outright (timeout, unreachable), as opposed to answered-empty.
  /// The two read very differently on screen, and "listed nothing" is a lie
  /// about a device that said nothing at all.
  final Set<String> _optionsUnavailable = {};

  /// Name of the entity a SOAP send is in flight for, or null.
  ///
  /// HTTP button presses overlap freely — a volume press must not wait for
  /// a slow PowerOn — but SOAP writes serialize: the Crock-Pot's switch,
  /// mode and cook time are three entities writing one SetCrockpotState,
  /// each read-back filling in the values it does not own, so a second SOAP
  /// send racing the first reads back the pre-send state and quietly
  /// reverts what the first just set. One SOAP write in flight per screen
  /// is the read-back design's actual precondition.
  String? _soapSending;

  bool _loading = true;

  /// The device-sourced option lists (a Roku's channel list) load on their own
  /// slower path — plain ECP refuses them in Limited mode, so the ECP2 session
  /// has to open first. This tracks that second fetch so the control surface
  /// can draw the instant state is in, with the lists filling in under their
  /// own indicator rather than holding the whole screen behind a spinner.
  bool _loadingOptions = false;

  String? _error;

  /// Per-entity state for `text` entities (the TV keyboard): the field's
  /// controller, the text as the device last saw it, and a chain serializing
  /// keystroke sends — concurrent Lit_ POSTs can arrive out of order and
  /// scramble what the user typed, so each keystroke awaits the one before.
  final Map<String, TextEditingController> _textControllers = {};
  final Map<String, String> _typedText = {};
  final Map<String, Future<void>> _keystrokeChains = {};

  /// The robot's session, when this screen is driving one. Held rather than
  /// re-created per send because the robot serves ONE local client at a time:
  /// a connect-per-command would evict itself, and would spend the whole
  /// screen's life holding the owner out of their own iRobot app.
  RoombaController? _roomba;
  StreamSubscription<Map<String, String>>? _roombaState;

  /// Keeps the direct client's provider alive for as long as this screen is
  /// driving the robot.
  ///
  /// `roombaClientProvider` is `autoDispose`, and a provider with no listeners
  /// is reclaimed a frame later — taking `ref.onDispose(client.dispose)` with
  /// it, which closes the TLS socket. Reading it with `ref.read` registers no
  /// listener, so the session this screen is holding would be torn down under
  /// it moments after connecting. `listenManual` is the listener; closing the
  /// subscription in [dispose] is what lets autoDispose do its job afterwards.
  ///
  /// Only the direct path needs this. `rest980ClientProvider` is a plain
  /// `Provider` and is never reclaimed.
  ProviderSubscription<RoombaMqttClient>? _directClientHandle;

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    _keyboardPoll?.cancel();
    _statePoll?.cancel();
    _mqttRetry?.cancel();
    unawaited(_keyboardSub?.cancel());
    unawaited(_mqttStateSub?.cancel());
    unawaited(_sender.close());
    // Letting go is part of the Roomba protocol, not tidiness: the slot stays
    // occupied until this happens, and the owner's app stays locked out.
    unawaited(_roombaState?.cancel() ?? Future<void>.value());
    unawaited(_roomba?.close() ?? Future<void>.value());
    _directClientHandle?.close();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _sender = ref.read(networkCommandSenderFactoryProvider)(
      device: widget.device,
      specYaml: widget.controls.specYaml,
      capabilities: widget.controls.capabilities,
    );
    // Credentials BEFORE the first load, not alongside it. Fired together,
    // `_refreshMissingCredentials` was still awaiting its FFI call while
    // `_load` was already rendering the opening state poll — with an empty
    // map, because the handover to the sender had not happened yet. On a
    // device that needs one the render throws, and it throws OUTSIDE the
    // branch `_load` guards, so the screen errored out and never started its
    // poll timer: an error banner on a device whose credential the app was
    // already holding, until the user backed out and came in again.
    unawaited(_refreshMissingCredentials().whenComplete(_load));
    unawaited(_watchKeyboard());
  }

  /// Apply a keyboard-focus reading, unless a fresher one already landed. The
  /// generation guard is what keeps an in-flight poll's stale answer from
  /// clobbering a `textedit` notice that arrived while it was on the wire.
  void _setKeyboardFocused(bool focused) {
    if (!mounted) return;
    setState(() {
      _keyboardFocused = focused;
      _keyboardStateGen++;
    });
  }

  /// Track whether the device's on-screen keyboard is usable, so the text card
  /// is placed by that (above the channels when a field is focused, at the foot
  /// when unknown). The signal lives on the ECP2 session — plain ECP cannot
  /// answer it — so this is a no-op unless the device has a `text` entity and
  /// answered the `roku:ecp` search target.
  ///
  /// The session volunteers a `textedit` notice on focus changes; a 3 s poll
  /// backs that up, since whether a given firmware sends the notice is not
  /// guaranteed. Any failure leaves [_keyboardFocused] null and the card shows
  /// at the foot — the keyboard is never hidden on a device this cannot read.
  Future<void> _watchKeyboard() async {
    final hasKeyboard = _drawableEntities.any((e) => e.platform == 'text');
    // The focus signal lives on the signed session, which the SPEC declares
    // (its ecp2 block, surfaced as a capability) — not a discovery string.
    if (!hasKeyboard || widget.controls.capabilities?.signedSession != 'ecp2') {
      return;
    }
    final session = await _sender.openSignedSession();
    if (session == null || !mounted) return;
    _keyboardSub = session.textEditFocusChanges.listen(_setKeyboardFocused);
    Future<void> poll() async {
      final gen = _keyboardStateGen;
      try {
        final focused = await session.queryTextEditFocused();
        // Drop a reply a notice has already superseded (see _keyboardStateGen).
        if (gen == _keyboardStateGen) _setKeyboardFocused(focused);
      } catch (e) {
        Log.net.debug('textedit-state poll failed for ${widget.device.host}: '
            '$e');
      }
    }

    await poll();
    // A disposed widget cancels _keyboardPoll — but only a poll that already
    // exists. This runs after an await, so guard against a dispose that landed
    // during it, or the periodic timer would fire forever on a closed session.
    if (!mounted) return;
    _keyboardPoll = Timer.periodic(const Duration(seconds: 3), (_) => poll());
  }

  /// The surface settled against the device's own state replies — variants
  /// the spec identifies by reply shape (`state_probe`) resolve strictly
  /// once the first poll answers, so a Kasa bulb sheds the plug family's
  /// relay switch and gains its light. Null until then: the optimistic
  /// pre-poll surface the resolver handed over draws meanwhile.
  List<NetworkEntityDto>? _refinedEntities;
  List<String>? _refinedHiddenNames;
  bool _surfaceRefined = false;

  List<NetworkEntityDto> get _entities =>
      _refinedEntities ?? widget.controls.entities;

  List<String> get _hiddenNames =>
      _refinedHiddenNames ?? widget.controls.hiddenNames;

  /// Settle the surface on the state replies, once: variant identity does
  /// not change while a screen is open, so one resolution after the first
  /// successful poll is the whole job.
  Future<void> _refineSurface() async {
    if (_surfaceRefined || _stateByCommand.isEmpty) return;
    _surfaceRefined = true;
    try {
      final surface =
          await ref.read(specCodecProvider).networkEntitiesForStateKeys(
                specYaml: widget.controls.specYaml,
                ssdpTargets: widget.device.ssdpTargets,
                stateKeys: _stateByCommand,
              );
      if (!mounted) return;
      setState(() {
        _refinedEntities = surface.entities;
        _refinedHiddenNames = surface.hiddenNames;
      });
    } catch (e) {
      Log.spec.warning('surface refinement failed for ${widget.device.host}',
          error: e);
    }
  }

  /// Every distinct state call the declared entities need — usually one.
  ///
  /// A `button` entity carries an empty state command (a keypress has no
  /// state to poll), and rendering a request from the empty string would ask
  /// the device a malformed question.
  Set<String> get _stateCommands => _entities
      .map((e) => e.stateCommand)
      .where((command) => command.isNotEmpty)
      .toSet();

  /// The Kasa transport constant, matched as a bare string exactly as `'http'`
  /// is — one spec's actions are all one transport, so this labels the device.
  static const _kasaTransport = 'tcp-json';

  /// The TP-Link Smart Home port, the fallback when discovery did not carry one
  /// (a manually added device, a mock). Real discovery reports 9999.
  static const _kasaPort = 9999;

  /// Whether this device is driven over the Kasa TCP-JSON transport rather than
  /// SOAP/HTTP. It has no `setup.xml` and no UPnP control URLs; state and sends
  /// go over a raw socket instead, so the load and refresh paths fork on it.
  bool get _isKasa =>
      _entities.any((e) => e.actions.any((a) => a.transport == _kasaTransport));

  /// Whether an instanced entity enumerated any children this poll — a power
  /// strip. Drives the render fork: per-outlet switches instead of the single
  /// "Outlet" switch, which on a strip would only ever read "State unknown".
  bool get _hasInstanceChildren => _entities
      .any((e) => e.isInstanced && (_instances[e.name]?.isNotEmpty ?? false));

  /// The address a Kasa send/poll uses.
  int get _kasaHostPort => widget.device.port ?? _kasaPort;

  /// The Rabbit Air transport constant — the encrypted-JSON-over-UDP LAN
  /// protocol. Unlike Kasa, a Rabbit Air surface can be ALL readings (the
  /// sensors carry no actions), so the entity transport — which the codec
  /// fills from the state command's own declaration — counts too.
  static const _rabbitAirTransport = 'udp';

  /// Whether this device is driven over the Rabbit Air UDP transport. It has
  /// no `setup.xml`, and every exchange wants the stored user key, so the
  /// load, refresh and send paths all fork on this.
  bool get _isRabbitAir => _entities.any((e) =>
      e.transport == _rabbitAirTransport ||
      e.actions.any((a) => a.transport == _rabbitAirTransport));

  /// The address a Rabbit Air send/poll uses. Real discovery reports the
  /// mDNS SRV port (9009); the constant is the fallback.
  int get _rabbitAirHostPort =>
      widget.device.port ?? RabbitAirControlClient.defaultPort;

  /// The identity the user key is stored under: the Thing ID, which IS the
  /// device's mDNS hostname, falling back to the host when discovery carried
  /// no hostname (a manual entry — DHCP moving then means a re-prompt, not a
  /// key offered to the wrong device).
  String get _rabbitAirKeyScope => widget.device.hostname ?? widget.device.host;

  /// The shared Rabbit Air panel this screen delegates to — key handling,
  /// clock sync, polling and sends all live there now, one implementation
  /// serving this screen and the BLE device screen. The key lets the app
  /// bar's refresh button forward into it.
  final GlobalKey<RabbitAirControlsPanelState> _rabbitAirPanelKey =
      GlobalKey<RabbitAirControlsPanelState>();

  /// The transport a state command rides, taken from any entity bound to it.
  /// The codec sets an entity's transport from the command's own declaration
  /// (`http` for the Envoy's production poll, `tcp-json` for a Kasa read); a
  /// SOAP command declares none, so null here means the SOAP path.
  String? _stateTransport(String command) {
    for (final entity in _entities) {
      final transport = entity.transport;
      if (entity.stateCommand == command && transport != null) {
        return transport;
      }
    }
    return null;
  }

  /// Whether this device's readings arrive over MQTT — a Roomba, a Hisense
  /// set, a Dyson purifier.
  ///
  /// Like [_isKasa] this forks the load path, but for the opposite reason.
  /// Kasa has no description to fetch and polls instead; an MQTT device has no
  /// description AND nothing to poll, because it pushes. There is no request
  /// whose reply is the battery level.
  bool get _speaksMqtt => _entities.any((e) =>
      e.transport == roombaTransport ||
      e.actions.any((a) => a.transport == roombaTransport));

  /// Whether this device's commands ride the spec-declared WebSocket surface
  /// — a Samsung or LG set. Like [_speaksMqtt]: no description to fetch and
  /// nothing to poll, and nothing to open either — the sender opens and
  /// pairs the session on the first send, so a screen the user only looks at
  /// never raises the television's Allow prompt.
  bool get _speaksWebsocket => _entities.any((e) =>
      e.transport == NetworkCommandSender.websocketTransport ||
      e.actions
          .any((a) => a.transport == NetworkCommandSender.websocketTransport));

  /// Whether this device is specifically a Roomba, which has a bespoke load
  /// path — credentials, an HA route, a controller holding the robot's one
  /// client slot — that no other MQTT device wants.
  ///
  /// Keyed on the spec's own `protocol_handler`, not on the transport: the
  /// transport string is `mqtt` for a Hisense set too, and taking the robot's
  /// path for a television would look up a BLID that does not exist.
  bool get _isRoomba =>
      widget.controls.capabilities?.protocolHandler == roombaProtocolHandler;

  /// The robot's BLID, from the discovery announcement. Null means this screen
  /// was reached without one, which for a Roomba is not drivable.
  ///
  /// An EMPTY value counts as absent: a TXT record can carry a bare flag with
  /// no value, which the parser stores as `''`, and an empty BLID looks up no
  /// password and addresses no robot.
  String? get _blid {
    final blid = widget.device.txt['blid'];
    return blid == null || blid.isEmpty ? null : blid;
  }

  /// Entities this transport can actually drive.
  ///
  /// rest980 publishes no locate endpoint, so in server mode the Locate button
  /// is not drawn at all. A button whose every press reports "unsupported" is
  /// worse than an absent one — it reads as a broken robot rather than as a
  /// server that does not offer that call.
  ///
  /// EVERY render path reads this rather than [_entities] — the switches, the
  /// selects, the keyboard, the instanced children, and what is handed to a
  /// child panel. Filtering one path and not its siblings draws exactly the
  /// dead control this exists to remove; it is latent today only because the
  /// robot spec happens to declare buttons and readings alone. [_entities]
  /// stays for the questions that are about the SPEC rather than about what
  /// to draw (does it declare a Kasa transport, does it need a description).
  List<NetworkEntityDto> get _drawableEntities {
    final roomba = _roomba;
    if (roomba == null) return _entities;
    return _entities
        .where((entity) =>
            entity.actions.isEmpty ||
            entity.actions.every((a) => roomba.supports(a.commandName)))
        .toList();
  }

  /// Whether anything on this screen needs the UPnP description document.
  ///
  /// SOAP is what it exists for and the only transport that needs it: a SOAP
  /// send and a SOAP state read both resolve their control URL out of it. A
  /// device whose surface is plain HTTP (a Roku's buttons, an Envoy's poll),
  /// binary UDP (a LIFX strip) or a raw socket (Kasa) has no `setup.xml` to
  /// fetch, and asking for one turns a working device into a permanent error
  /// screen: the request burns its full timeout, `_description` stays null and
  /// `_ready` never becomes true.
  ///
  /// Asked POSITIVELY — "does anything here ride SOAP" — and that is the
  /// point. It used to be the negative "is any state command NOT http",
  /// carved out per transport as each one arrived, which meant every transport
  /// added afterwards was included by default and had to remember to opt out.
  /// Two already had not: once the Kasa renderer was gated on
  /// `protocol_handler: tplink_smarthome`, the Tuya gas sensor and the
  /// Yeelight cube resolved no actions at all, `_isKasa` went false, and their
  /// tcp-json state commands sent both devices off to fetch a UPnP document
  /// from hardware that speaks framed JSON on a raw socket.
  bool get _needsDescription => _entities.any((e) =>
      e.actions.any((action) => action.transport == 'soap') ||
      (e.stateCommand.isNotEmpty && e.transport == 'soap'));

  /// Loaded enough to draw controls: the description is fetched, or nothing
  /// on this screen wants it.
  bool get _ready => _description != null || !_needsDescription;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isRoomba) {
        // Nothing to fetch and nothing to poll: the robot pushes. Opening the
        // session IS the load, and state arrives on a stream from here on.
        await _connectRoomba();
      } else if (_isKasa) {
        // No description to fetch and no control URLs to resolve — poll the
        // relay state straight over the socket. The port is 9999, not a UPnP
        // LOCATION, so the SOAP port check below does not apply.
        await _refreshState();
      } else if (_speaksMqtt) {
        // Any other device that pushes over MQTT — a Hisense set, a Dyson
        // purifier. Nothing to fetch and nothing to poll — but the pushed
        // readings only exist if someone SUBSCRIBES, so that is what loading
        // means here. Refused quietly when the device is unpaired: the
        // credentials card is the ask, and a screen the user only looks at
        // must not become an error page over a reading. Without this arm the
        // else below demands a UPnP control port these devices never
        // advertise, and a working set loads as an error.
        await _subscribeMqttState();
      } else if (_speaksWebsocket) {
        // A television driven over its WebSocket surface. Nothing to fetch
        // (no UPnP description), nothing to poll, nothing to open here — the
        // sender opens and pairs the session on the first send. Without this
        // arm the else below demands a control port and, when the spec
        // declares one as a fallback, tries to fetch /setup.xml from a set
        // that serves no such document.
      } else if (_isRabbitAir) {
        // No description either — and the whole encrypted exchange (key,
        // clock sync, poll) is the shared panel's job. Forward the refresh;
        // a no-op on first load, when the panel has not mounted yet and its
        // own initState will do the loading.
        await _rabbitAirPanelKey.currentState?.refresh();
      } else {
        // Asked of the sender, which owns the rule: discovery first, then the
        // port the spec declares. Reading `widget.device.controlPort` here
        // meant only the discovered one, so a device added by hand — or found
        // by a transport carrying an address and no port — failed on this line
        // with its own spec naming the port two fields away.
        final port = _sender.controlPort;
        if (port == null) {
          // Nothing advertised a port and no spec declares one — not a device
          // this screen can drive.
          throw const SoapTransportException(
              'the device did not advertise a control port');
        }
        if (_needsDescription) {
          final client = ref.read(soapControlClientProvider);
          _description ??= await client.fetchDescription(
            widget.device.host,
            port,
            // Where the device said its description lives, when it said —
            // /setup.xml is the fallback, not the rule (a Viera's LOCATION
            // names /nrc/ddd.xml).
            path: widget.device.ssdpDescriptionPath ?? '/setup.xml',
          );
        }
        // Outside the description branch: a device that needs no description
        // can still have state to poll (the Envoy's plain-HTTP telemetry). A
        // remote of stateless buttons has none, and the poll is a no-op.
        await _refreshState();
      }
      // Drop the spinner now — the buttons, readings and D-pad are ready. The
      // device-sourced option lists (a Roku's channels) are a slower, gated
      // fetch that must not hold the remote hostage: they load in the
      // background under the select card's own indicator. See [_loadingOptions].
      if (mounted) setState(() => _loading = false);
      _startStatePoll();
      unawaited(_refreshQuerySources());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyErrorText(
          e,
          context: 'device control',
          fallback: 'Could not reach the device. It may have moved ports — '
              'try scanning again.',
        );
      });
    }
  }

  /// The device's own identity in the credential store — the same handle the
  /// certificate pin is keyed by, for the same reason: a DHCP lease is not a
  /// device, and a value filed under one would be lost on the next renewal.
  String get _credentialIdentity => widget.device.credentialIdentity;

  /// Work out what this device still needs from a person: the credentials its
  /// spec says must be asked for, minus whatever is already stored.
  ///
  /// Failures are swallowed to an empty list. A screen that cannot read its
  /// own credential requirements must not become an error page — the device
  /// may well be one of the many that need none, and the sends themselves
  /// still fail visibly if it is not.
  Future<void> _refreshMissingCredentials() async {
    try {
      final declared = await ref
          .read(specCodecProvider)
          .credentialsForDevice(widget.controls.specYaml);
      // A device that names none never opens the credential store. Most of
      // the catalogue is that device, and the store is the platform keychain.
      // A WebSocket TV is no longer a carve-out here: required_credentials
      // reports its pairing token itself now, which is what wires the reader
      // for the group runner too — the screen-only exception this used to
      // carry left group runs re-pairing (Allow prompt and all) a set the
      // screen drove fine.
      if (declared.isEmpty) {
        if (mounted && _missingCredentials.isNotEmpty) {
          setState(() => _missingCredentials = const []);
        }
        return;
      }
      // This spec names some (or pairs at runtime), so the sends need the
      // store. Idempotent, and it is the only route by which this screen's
      // sender ever reads one.
      final store = ref.read(deviceCredentialStoreProvider);
      _sender.useCredentials(() => store.credentials(_credentialIdentity));
      final held = await _sender.currentCredentials();
      final asked = declared.where((c) => c.mustBeAskedFor).toList();
      final missing = asked
          .where((c) => (held[c.name] ?? '').isEmpty)
          .toList(growable: false);
      if (mounted) setState(() => _missingCredentials = missing);
    } catch (e) {
      Log.net.debug('credential requirements unreadable: $e');
    }
  }

  /// Store one credential under the name its spec gave it, then reload.
  ///
  /// The reload is the point: the value that was missing is now held, so the
  /// state poll that failed on it can succeed, and the card that asked for it
  /// can leave.
  Future<void> _saveCredential(String name, String value) async {
    // A failed write (a locked keystore) propagates: the credentials card
    // catches it and tells the person, which nothing here used to.
    await ref
        .read(deviceCredentialStoreProvider)
        .save(_credentialIdentity, name, value);
    // The screen can be gone by the time the keychain answers, and the
    // refresh below reads providers through a ref that death disposed.
    if (!mounted) return;
    // The sender holds what it read; this is the moment that changed.
    _sender.refreshCredentials();
    await _refreshMissingCredentials();
    if (mounted) await _load();
  }

  /// Begin (or restart) the background state poll. A device with no state
  /// commands — a Roku's stateless button remote — has nothing to poll and
  /// never starts a timer. Idempotent: cancels any prior timer first, so a
  /// re-load does not leave two running.
  void _startStatePoll() {
    _statePoll?.cancel();
    if (_stateCommands.isEmpty) return;
    _statePoll = Timer.periodic(
        const Duration(seconds: 4), (_) => unawaited(_tickStatePoll()));
  }

  /// One background state refresh. Skips its turn — rather than stacking —
  /// while a read is already in flight, the screen is still loading, or the
  /// user is mid-send (don't fight an optimistic toggle). Transient errors are
  /// swallowed so a momentary blip does not blank a working screen; [_load] and
  /// the manual Refresh still surface failures.
  Future<void> _tickStatePoll() async {
    if (!mounted || _polling || _loading || _sending.isNotEmpty) return;
    _polling = true;
    try {
      await _refreshState();
    } catch (_) {
      // Keep the last-known readings until a poll succeeds.
    } finally {
      _polling = false;
    }
  }

  /// Send every state request and re-decode every entity from the replies.
  Future<void> _refreshState() async {
    if (_isKasa) {
      await _refreshStateKasa();
      return;
    }
    // An MQTT device PUSHES. There is no request whose reply is the battery
    // level, so there is nothing to poll here — [_subscribeMqttState]'s
    // stream fills the cards once the device is paired, and until then the
    // readings are honestly unknown. Without this branch the spec's state
    // topic falls through to the SOAP path below, which dereferences a
    // description this device never had, and every SUCCESSFUL command ends
    // in an error banner.
    if (_speaksMqtt) return;
    // A WebSocket device is push-shaped the same way: state, where a spec
    // declares any, arrives on the session's frames, and there is no request
    // whose reply is a reading.
    if (_speaksWebsocket) return;
    final codec = ref.read(specCodecProvider);
    final client = ref.read(soapControlClientProvider);

    for (final command in _stateCommands) {
      if (_stateTransport(command) == 'http') {
        await _refreshStateHttp(command);
        continue;
      }
      // Everything left resolves its address out of the description, so
      // without one there is no poll to make. Skipped rather than asserted
      // on: `_description` is legitimately null now that fetching one is
      // asked positively — a Tuya gas sensor's tcp-json `dp_query` reaches
      // here on a device that serves no UPnP document, and `!` would turn a
      // reading it simply cannot take into a crash.
      final description = _description;
      if (description == null) {
        Log.net.debug('no state poll for "$command" on ${widget.device.host}: '
            'transport ${_stateTransport(command) ?? '<unknown>'} needs a '
            'device description and this device serves none');
        continue;
      }
      final request = await codec.renderNetworkStateRequest(
        specYaml: widget.controls.specYaml,
        stateCommand: command,
      );
      final path = description.controlPathFor(request);
      if (path == null) continue;
      _stateByCommand[command] =
          await client.send(description.host, description.port, path, request);
    }
    await _decodeEntities();
  }

  /// The plain-HTTP state poll (the Envoy's production summary): render the
  /// request, send it, and flatten the reply into the name→value pairs the
  /// entity decoder reads. The Kasa poll's structural twin over HTTP — fill
  /// `_stateByCommand`, then the shared decode — but through
  /// [HttpControlClient], with the reply flattened here.
  ///
  /// `command` is whatever the entity's state binding resolved to: a command
  /// name on the Envoy, a bare path on a device whose spec declares its
  /// readings as `state_topic` (`/json/state` on a WLED controller). The Rust
  /// renderer owns that distinction; both arrive here as a request to send.
  ///
  /// A refusal (403, or 401 from the Envoy's JWT-gated firmware) is the same
  /// device-side policy a refused write is, so it raises the standing note
  /// and leaves the readings unknown rather than erroring the screen of a
  /// device that is otherwise answering.
  Future<void> _refreshStateHttp(String command) async {
    final codec = ref.read(specCodecProvider);
    final request = await codec.renderNetworkHttpStateRequest(
      specYaml: widget.controls.specYaml,
      stateCommand: command,
      // A READ needs the credential as much as a write does: the Hue bridge's
      // sensor path embeds the whitelist username, and a poll rendered from an
      // empty map fails on a value the app is holding two lines away.
      // A READ needs the credential as much as a write does: the Hue bridge's
      // sensor path embeds the whitelist username. Empty for the devices that
      // declare none, which never opened the store.
      values: await _sender.currentCredentials(),
    );
    try {
      final body = await _sendNetworkHttp(request);
      _stateByCommand[command] = httpStateFields(body);
    } on ControlRefusedException {
      _controlRefused = true;
    }
  }

  /// The Kasa state poll: render `get_sysinfo`, send it over the socket, and
  /// flatten the reply into the name→value pairs the entity decoder reads.
  ///
  /// The SOAP path's structural twin — fill `_stateByCommand`, then decode —
  /// but over a raw socket with no control URL to resolve, and the reply is
  /// JSON flattened here rather than XML parsed by the transport client.
  /// [kasaStateFields] dispatches per reply shape: sysinfo lifts flat (the
  /// switch's `relay_state`), an emeter reply flattens to the dotted paths
  /// the HS110's sensors name.
  Future<void> _refreshStateKasa() async {
    final codec = ref.read(specCodecProvider);
    final client = ref.read(kasaControlClientProvider);

    for (final command in _stateCommands) {
      final request = await codec.renderNetworkKasaStateRequest(
        specYaml: widget.controls.specYaml,
        stateCommand: command,
      );
      final reply =
          await client.send(widget.device.host, _kasaHostPort, request);
      _stateByCommand[command] = kasaStateFields(reply);
      _rawStateReply[command] = reply;
      // The reply, so an "unknown state" is diagnosable from a log instead of a
      // blank card — a Kasa device that answers a shape we don't decode (a
      // bulb's light_state, a variant's renamed fields) is exactly where this
      // earns its keep.
      Log.net.debug('kasa $command <- ${widget.device.host}: $reply');
    }
    await _decodeInstances();
    await _decodeEntities();
  }

  /// Enumerate each instanced entity's children from the raw reply and read
  /// each child's roles — a Kasa power strip's per-outlet on/off. A
  /// single-outlet plug reports no `children`, so this finds none and the plain
  /// switch renders instead. Kept beside [_decodeEntities] so a poll refreshes
  /// the outlets the same way it refreshes a plain reading.
  Future<void> _decodeInstances() async {
    final codec = ref.read(specCodecProvider);
    for (final entity in _entities.where((e) => e.isInstanced)) {
      final reply = _rawStateReply[entity.stateCommand];
      if (reply == null) continue;
      final children = await codec.listNetworkInstances(
        specYaml: widget.controls.specYaml,
        entityName: entity.name,
        stateReply: reply,
      );
      _instances[entity.name] = children;
      for (final child in children) {
        final readings = await codec.readNetworkInstance(
          specYaml: widget.controls.specYaml,
          entityName: entity.name,
          stateReply: reply,
          instanceId: child.id,
        );
        _instanceReadings['${entity.name}/${child.id}'] = {
          for (final reading in readings) reading.role: reading.reading,
        };
      }
    }
  }

  /// The Home Assistant entity driving this robot, if any.
  ///
  /// Either the device came FROM Home Assistant's own list — in which case the
  /// entity id is the only identity it has — or a robot found on the network
  /// has since been pointed at HA by the transport chooser.
  String? get _haEntityId => widget.device.txt['ha_entity_id'];

  /// Open the robot's session and start taking its state pushes.
  ///
  /// Which transport this builds — Home Assistant, a rest980 server, or the
  /// robot's own protocol — is decided by the device and its stored
  /// credential. Nothing else on this screen branches on the choice, because
  /// all three hand back state keyed by the same dotted paths.
  Future<void> _connectRoomba() async {
    // Retry re-enters this. Without releasing first, each attempt orphans the
    // previous controller — its 2-second poll timer keeps firing, its state
    // subscription keeps delivering, and the listenManual handle keeps
    // roombaClientProvider alive forever. On the direct path that pins the
    // robot's ONE client slot open, which is precisely the failure the handle
    // exists to prevent.
    await _releaseRoomba();

    // A device that came FROM Home Assistant's list carries its entity id and
    // nothing else — no BLID to look anything up by — so that case is settled
    // before the store is consulted at all.
    //
    // A robot HA drives needs no BLID and no password in THIS app, because HA
    // is holding them. That is a real advantage of the route rather than an
    // implementation detail, and it is the only route that works for a robot
    // this phone cannot reach.
    //
    // The absent BLID is what makes this an HA device, so it is part of the
    // test. A robot with both — seen once through HA and later adopted
    // directly on the LAN, its cached TXT holding the union — is a robot this
    // phone CAN reach, and the store below is what knows which route the user
    // last chose (`credentials.haEntityId`). Taking the HA route on the mere
    // presence of the key made that choice unchangeable: the key survives
    // every later sighting, so a direct adoption could never take effect and
    // the robot hard-failed whenever HA was not connected.
    final blid = _blid;
    final deviceEntityId = _haEntityId;
    if (blid == null && deviceEntityId != null && deviceEntityId.isNotEmpty) {
      await _connectViaHomeAssistant(deviceEntityId);
      return;
    }

    if (blid == null) {
      throw const RoombaConnectionException(
        'This robot did not announce a BLID, so there is no identity to look '
        'a password up by. Scan again.',
      );
    }
    final credentials =
        await ref.read(roombaCredentialStoreProvider).credentials(blid);
    if (credentials == null) {
      // Nothing to drive it directly with. An entity id on the sighting is
      // then the only route left, so a robot known to both this LAN and Home
      // Assistant still opens — it just prefers the direct password when one
      // exists, which is the choice the user made by adopting it.
      if (deviceEntityId != null && deviceEntityId.isNotEmpty) {
        await _connectViaHomeAssistant(deviceEntityId);
        return;
      }
      throw const RoombaConnectionException(
        'No password saved for this robot yet. Go back and adopt it first.',
      );
    }

    // A robot found on the network that the transport chooser has since
    // pointed at Home Assistant.
    final storedEntityId = credentials.haEntityId;
    if (storedEntityId != null && storedEntityId.isNotEmpty) {
      await _connectViaHomeAssistant(storedEntityId);
      return;
    }

    final controller = roombaControllerFor(
      credentials: credentials,
      host: widget.device.host,
      specYaml: widget.controls.specYaml,
      codec: ref.read(specCodecProvider),
      directClient: () {
        // Held, not read: see [_directClientHandle]. The callback only runs on
        // the direct path, so the rest980 path never takes the subscription.
        final handle = ref.listenManual(
          roombaClientProvider(blid),
          (_, __) {},
        );
        _directClientHandle = handle;
        return handle.read();
      },
      restClient: () => ref.read(rest980ClientProvider),
    );
    _roomba = controller;
    _startRoombaState(controller);
    await controller.connect();
  }

  Future<void> _connectViaHomeAssistant(String entityId) async {
    final haClient = ref.read(haRoombaClientProvider);
    if (haClient == null) {
      throw const RoombaConnectionException(
        'This robot is driven through Home Assistant, but Home Assistant is '
        'not connected in this app. Connect it in Settings.',
      );
    }
    final controller = HaRoombaController(client: haClient, entityId: entityId);
    _roomba = controller;
    _startRoombaState(controller);
    await controller.connect();
  }

  /// Let go of whatever Roomba session this screen is holding.
  ///
  /// Order matters: stop listening before closing, so a controller that emits
  /// on its way down does not land on a screen that has moved on. Awaited
  /// rather than fire-and-forget, because the caller is usually about to build
  /// a replacement and the robot only serves one client at a time.
  Future<void> _releaseRoomba() async {
    await _roombaState?.cancel();
    _roombaState = null;
    await _roomba?.close();
    _roomba = null;
    _directClientHandle?.close();
    _directClientHandle = null;
  }

  /// Subscribe BEFORE connecting: the robot pushes its whole shadow the moment
  /// a client subscribes, and a listener attached afterwards would miss the one
  /// message that fills the screen.
  void _startRoombaState(RoombaController controller) {
    _roombaState = controller.state.listen(
      _onRoombaState,
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = friendlyErrorText(
              e,
              context: 'roomba state',
              fallback: 'Lost contact with the robot.',
            ));
      },
    );
  }

  /// One state push, decoded into the readings the cards draw.
  ///
  /// The push is filed under every state topic the entities name, so
  /// [_decodeEntities] — which is the SOAP and Kasa paths' decoder, unchanged —
  /// finds it where it expects to. That shared decode is what makes a battery
  /// percentage mean the same thing whichever transport carried it.
  Future<void> _onRoombaState(Map<String, String> fields) async {
    for (final command in _stateCommands) {
      _stateByCommand[command] = {
        ...?_stateByCommand[command],
        ...fields,
      };
    }
    await _decodeEntities();
    if (mounted) setState(() {});
  }

  Future<void> _sendRoomba(NetworkActionDto action) async {
    final controller = _roomba;
    if (controller == null) {
      throw const RoombaConnectionException('Not connected to the robot.');
    }
    await controller.sendCommand(action.commandName);
  }

  /// Decode every entity from whatever `_stateByCommand` currently holds — the
  /// step shared by both transports' state refresh, so a reading means the
  /// same thing whichever socket carried it.
  /// The pushed readings a non-Roomba MQTT device serves, routed into the
  /// shared decode. Subscribes to every distinct state topic the entities
  /// bind — `stateCommand` IS the topic for an MQTT binding — through the
  /// sender's session, so state and sends share one broker connection and
  /// one client identity.
  Future<void> _subscribeMqttState() async {
    // A fresh attempt supersedes any scheduled retry.
    _mqttRetry?.cancel();
    _mqttRetry = null;
    final declaredTopics = <String>{
      for (final entity in _entities)
        if (!entity.isInstanced &&
            entity.stateCommand.isNotEmpty &&
            entity.transport == roombaTransport)
          entity.stateCommand,
    };
    if (declaredTopics.isEmpty) return;
    // An action carries the richest credential mapping when the device has
    // one; a readings-only device (a Dyson: entities, zero commands) has
    // none, and the session then logs in from stored credentials under the
    // literal names. Requiring an action here is what left exactly those
    // devices — the ones this subscription exists for — permanently silent.
    final action = _entities
        .expand((e) => e.actions)
        .where((a) => a.transport == roombaTransport)
        .firstOrNull;
    // Topics are subscribed as the DEVICE speaks them: `{serial}`-style
    // placeholders filled from what the app holds — the discovery TXT facts
    // (a Dyson's serial rides its mDNS record) and the stored credentials.
    // A topic still carrying a placeholder is NOT subscribed: a literal
    // "{serial}" matches nothing on any broker, and subscribing to it is
    // how these cards spent a release looking live while permanently
    // Unknown. Readings decode under the DECLARED topic, so the map back.
    final codec = ref.read(specCodecProvider);
    final values = <String, String>{
      ...widget.device.txt,
      ...await _sender.currentCredentials(),
    };
    final declaredByFilled = <String, String>{};
    for (final declared in declaredTopics) {
      final String filled;
      try {
        filled =
            await codec.fillMqttStateTopic(topic: declared, values: values);
      } catch (e) {
        // The fill refuses a value carrying the MQTT topic language (`/`,
        // `+`, `#`): a spoofed or malformed serial would not fill a level, it
        // would widen this subscription to topics the spec never named. One
        // refused topic costs its own reading, never the whole screen.
        Log.net.warning(
            'mqtt state topic "$declared" was refused on ${widget.device.host}'
            ' — not subscribing: $e');
        continue;
      }
      if (filled.contains('{')) {
        Log.net.info('mqtt state topic "$declared" still carries a '
            'placeholder after filling from discovery and stored '
            'credentials — not subscribing; the reading stays unknown '
            'until the missing value is known');
        continue;
      }
      declaredByFilled[filled] = declared;
    }
    if (declaredByFilled.isEmpty || !mounted) return;
    try {
      final stream = await _sender.subscribeMqttState(
          action, declaredByFilled.keys.toList());
      await _mqttStateSub?.cancel();
      _mqttStateSub = stream.listen((message) {
        final declared = declaredByFilled[message.topic];
        if (declared == null || !mounted) return;
        _stateByCommand[declared] = httpStateFields(message.payload);
        _scheduleDecode();
      }, onError: (Object e) {
        Log.net.debug('mqtt state stream on ${widget.device.host}: $e');
        // A broker drop errors the stream; re-subscribe so pushed readings
        // resume instead of freezing until the screen is reopened.
        _scheduleMqttResubscribe();
      });
      // Subscribed cleanly: reset the backoff for the next drop.
      _mqttBackoff = Duration.zero;
    } on Exception catch (e) {
      // Unpaired (no client id yet) or unreachable. The credentials card is
      // the ask; the readings stay honestly unknown until it is answered.
      Log.net.debug('mqtt state unavailable on ${widget.device.host}: $e');
    }
  }

  /// Re-subscribe the MQTT state stream after it errored, on a bounded,
  /// growing backoff. Only one retry is ever pending, and none is scheduled
  /// once the screen is disposed.
  void _scheduleMqttResubscribe() {
    if (!mounted || _mqttRetry != null) return;
    _mqttBackoff = _mqttBackoff == Duration.zero
        ? const Duration(seconds: 2)
        : Duration(seconds: (_mqttBackoff.inSeconds * 2).clamp(2, 30));
    _mqttRetry = Timer(_mqttBackoff, () {
      _mqttRetry = null;
      if (mounted) unawaited(_subscribeMqttState());
    });
  }

  /// Whether a decode pass is running, and whether pushes arrived during it.
  ///
  /// The poll path coalesces with [_polling]; this is the push path's
  /// equivalent. A broker replaying its retained messages delivers a burst —
  /// one per topic, back to back — and without this each push ran its own
  /// full-entity decode concurrently and rebuilt the whole screen per frame.
  bool _decoding = false;
  bool _decodeQueued = false;

  /// Decode once for however many pushes arrived, and never let a decode
  /// failure escape as an unhandled zone error: the stream outlives any one
  /// bad payload, and the next push gets another chance.
  void _scheduleDecode() {
    if (_decoding) {
      _decodeQueued = true;
      return;
    }
    _decoding = true;
    unawaited(() async {
      try {
        do {
          _decodeQueued = false;
          await _decodeEntities();
        } while (_decodeQueued && mounted);
      } catch (e) {
        Log.net.warning(
            'decode after mqtt push on ${widget.device.host} failed: $e');
      } finally {
        _decoding = false;
      }
    }());
  }

  Future<void> _decodeEntities() async {
    await _refineSurface();
    final codec = ref.read(specCodecProvider);
    for (final entity in _entities) {
      // Instanced entities are read per-child in _decodeInstances, not here.
      if (entity.isInstanced) continue;
      final returned = _stateByCommand[entity.stateCommand];
      final reading = returned == null
          ? null
          : await codec.readNetworkEntity(
              specYaml: widget.controls.specYaml,
              entityName: entity.name,
              returned: returned,
            );
      _readings[entity.name] = reading;
      // A fresh decode supersedes a slider position the user was holding —
      // the device has now said where it actually is.
      if (reading != null) _pendingSetpoints.remove(entity.name);
      // Say WHY a card reads "State unknown": the state command answered, but
      // no field in it mapped to this entity's reading. Without this the app is
      // silent about a real gap (a bulb's light_state, a variant's renamed
      // keys), which is exactly the "nothing's logged" complaint.
      if (reading == null &&
          returned != null &&
          entity.stateCommand.isNotEmpty) {
        Log.net.debug('kasa/${entity.name}: state command '
            '"${entity.stateCommand}" answered but no field mapped to a reading '
            '(keys: ${returned.keys.join(", ")})');
      }
    }
    if (mounted) setState(() {});
  }

  /// Fetch the option lists — and current selections — that live on the
  /// device rather than in the spec.
  ///
  /// Separate from [_refreshState] because it is a different transport and a
  /// different failure: these are plain GETs whose answers are XML lists, and
  /// on the devices this exists for they keep answering even when commands
  /// are refused. So a failure here costs the list and nothing else — the
  /// buttons beside it still work, and the screen must not become an error
  /// page over a channel list.
  Future<void> _refreshQuerySources() async {
    if (_sender.controlPort == null) return;
    if (!_entities.any((e) => e.optionsSource != null)) return;

    if (mounted) setState(() => _loadingOptions = true);
    try {
      await _fetchQuerySources();
    } finally {
      if (mounted) setState(() => _loadingOptions = false);
    }
  }

  Future<void> _fetchQuerySources() async {
    for (final entity in _entities) {
      final options = entity.optionsSource;
      if (options == null) continue;
      try {
        final body = await _sendNetworkHttp(
          HttpRequestDto(method: options.method, path: options.path, body: ''),
        );
        _fetchedOptions[entity.name] = readQuerySource(body, options);
        _optionsUnavailable.remove(entity.name);

        final state = entity.stateSource;
        if (state == null) continue;
        final current = await _sendNetworkHttp(
          HttpRequestDto(method: state.method, path: state.path, body: ''),
        );
        _currentOption[entity.name] = readCurrentValue(current, state);
      } on ControlRefusedException {
        // A refused list is the same device-side gate as a refused keypress —
        // show the note that names the setting. Without this the user sees an
        // empty channel list on a TV they know has channels, with no hint why.
        _controlRefused = true;
      } catch (e) {
        // Not an error-page failure — the buttons beside the list still work —
        // but not silent either: the card says the list could not be loaded,
        // which is a different thing from the device listing nothing.
        _optionsUnavailable.add(entity.name);
        Log.net.debug('query source failed for ${entity.name}: $e');
      }
    }
    if (mounted) setState(() {});
  }

  /// Send one action, with its read-back values fetched fresh first.
  Future<void> _send(
    NetworkEntityDto entity,
    NetworkActionDto action, {
    String? value,
    Map<String, String>? values,
  }) async {
    // Everything but SOAP is independent — no read-back coupling — so it does
    // not serialize behind the single-SOAP-write gate the Crock-Pot needs.
    // Asked of the sender rather than restated here: this was a third copy of
    // the list and it had already fallen two transports behind, so a
    // television's button and a Bambu's pause both queued behind a SOAP write
    // that was never going to happen.
    final independent = NetworkCommandSender.isIndependentTransport(action);
    // The disabled controls are the visible gate; this is the real one — a
    // tap can race the rebuild that greys the SOAP controls out.
    if (!independent && _soapSending != null) return;
    setState(() {
      _sending.add(entity.name);
      if (!independent) _soapSending = entity.name;
      _error = null;
    });
    try {
      final sent = <String, String>{...?values};
      if (value != null && action.userParams.isNotEmpty) {
        sent[action.userParams.first] = value;
      }
      // The ROBOT's path, not the transport's. `roombaTransport` is literally
      // 'mqtt', so keying the fork on it alone sent every Hisense key press
      // and every Bambu print command into `_sendRoomba`, which answered
      // "Not connected to the robot." — 43 commands across two devices that
      // have no BLID and never wanted one. `_isRoomba` asks the spec's
      // `protocol_handler`, which is the question this fork is really about:
      // the Roomba is the device with a bespoke credential store, an HA route
      // and a controller holding its one client slot. Every other MQTT device
      // takes the generic arm, which renders through the spec.
      if (_isRoomba && action.transport == roombaTransport) {
        await _sendRoomba(action);
      } else {
        await _sender.sendAction(
          action,
          sent,
          description: _description,
          // Null by construction: a Rabbit Air device forks to
          // RabbitAirControlsPanel above, and that panel's transport owns
          // the user key. Nothing that reaches this generic send is on the
          // Rabbit Air transport.
          rabbitAirKey: null,
        );
      }
      // The reply acknowledges the request, it does not report the resulting
      // state — the Crock-Pot doesn't always take a setting. Read back
      // whatever state this screen polls; a remote of stateless buttons has
      // none.
      if (_stateCommands.isNotEmpty) await _refreshState();
      // A launch changes which option is current, and nothing else reports
      // that — re-read the selection the device now names.
      if (entity.stateSource != null) await _refreshQuerySources();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A refusal is a device setting, not a transient failure: remember it
        // so the screen can explain the gate instead of leaving the user to
        // read one error at a time.
        if (e is ControlRefusedException) _controlRefused = true;
        _error = friendlyErrorText(
          e,
          context: 'device control',
          fallback: 'The device did not accept that. Try again.',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending.remove(entity.name);
          if (_soapSending == entity.name) _soapSending = null;
        });
      }
    }
  }

  /// One plain-HTTP exchange through the sender, which owns the ECP2
  /// session and the plain-ECP fallback alike.
  Future<String> _sendNetworkHttp(HttpRequestDto request) =>
      _sender.sendHttpRequest(request);

  /// Whether [action]'s control must sit out the current SOAP write. Only a
  /// SOAP action locks out — see [_soapSending]. Same question as the
  /// `independent` gate in [_send], asked of the same place, so the greyed-out
  /// control and the refused tap cannot disagree about which is which.
  bool _lockedFor(NetworkActionDto? action) =>
      action != null &&
      !NetworkCommandSender.isIndependentTransport(action) &&
      _soapSending != null;

  /// Toggle one outlet of a power strip: render the child-scoped command with
  /// the outlet's id threaded into `context.child_ids` (via the action's
  /// instance params), send it, and re-poll so the switch snaps to the strip's
  /// true state. The busy key is "entity/childId", so one outlet's spinner
  /// does not disable its siblings.
  Future<void> _sendKasaChild(
      NetworkEntityDto entity, NetworkInstanceDto child, bool on) async {
    final action = _actionFor(entity, on ? 'turn_on' : 'turn_off');
    if (action == null) return;
    final key = '${entity.name}/${child.id}';
    setState(() {
      _sending.add(key);
      _error = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final request = await codec.renderNetworkKasaCommand(
        specYaml: widget.controls.specYaml,
        commandName: action.commandName,
        values: {
          for (final param in action.instanceParams) param.param: child.id,
        },
      );
      await ref
          .read(kasaControlClientProvider)
          .send(widget.device.host, _kasaHostPort, request);
      await _refreshState();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyErrorText(e,
          context: 'device control',
          fallback: 'The outlet did not accept that. Try again.'));
    } finally {
      if (mounted) setState(() => _sending.remove(key));
    }
  }

  NetworkActionDto? _actionFor(NetworkEntityDto entity, String role) {
    for (final action in entity.actions) {
      if (action.role == role) return action;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final description = _description;

    return Scaffold(
      backgroundColor: scheme.surface,
      // The device-targeted promotion: label-roll supplies for a label printer,
      // filter kits for a Rabbit Air, etc., falling back to the global shop
      // banner for a device nothing targets. Zero-height when there is nothing
      // to show.
      bottomNavigationBar: DeviceAdBannerBar(
        category: widget.category,
        specKey: widget.specKey,
      ),
      appBar: AppBar(
        title: Text(description?.friendlyName ?? widget.device.displayName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            // Live camera, for a device whose spec declares one (Snapmaker U1).
            // Renders nothing otherwise.
            CameraViewCard(
              specYaml: widget.controls.specYaml,
              host: widget.device.host,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: text.bodyMedium?.copyWith(color: scheme.error),
                ),
              ),
            if (_loading) ...[
              const SizedBox(height: 48),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Center(
                child: Text('Asking the device...',
                    style: text.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ] else if (!_ready) ...[
              // Never reached the device: no cards. A toggle for a device
              // whose description was never fetched has nowhere to send.
              // Controls that need nothing fetched (a remote of plain-HTTP
              // buttons) never take this branch.
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: FilledButton.icon(
                    onPressed: () => unawaited(_load()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ),
              ),
            ] else if (_isRabbitAir) ...[
              // The whole Rabbit Air surface — the key-entry card when no key
              // is stored, the entity cards otherwise — is the shared panel's;
              // this screen only supplies the LAN transport and the info rows.
              RabbitAirControlsPanel(
                key: _rabbitAirPanelKey,
                specYaml: widget.controls.specYaml,
                entities: _drawableEntities,
                transport: RabbitAirLanTransport(
                  host: widget.device.host,
                  port: _rabbitAirHostPort,
                  keyScope: _rabbitAirKeyScope,
                  client: ref.read(rabbitAirControlClientProvider),
                  keyStore: ref.read(rabbitAirKeyStoreProvider),
                ),
              ),
              const SizedBox(height: 16),
              _deviceInfo(description),
            ] else ...[
              // Something the SPEC says this device needs and the app has not
              // been given — a printer's serial, read off its own touchscreen.
              // Above the controls because it is why they do not work: every
              // send below fails on the missing name until it is here.
              if (_missingCredentials.isNotEmpty) ...[
                DeviceCredentialsCard(
                  missing: _missingCredentials,
                  onSave: _saveCredential,
                ),
                const SizedBox(height: 12),
              ],
              // The device answered our questions but refused a command. That
              // is a setting on the device, and saying so beats leaving the
              // user to conclude the app is broken — discovery worked, the
              // lists loaded, only control is gated.
              if (_controlRefused) ...[
                _controlGateNote(),
                const SizedBox(height: 12),
              ],
              // Readings and plain controls first, in the order the spec
              // declares them — but not a select (the channel picker goes below
              // the pad) and not the keyboard (placed by whether it's usable,
              // below), so a Roku's remote keeps a stable position whether the
              // app list is still loading or just came back.
              for (final entity in _drawableEntities.where((entity) =>
                  entity.platform != 'button' &&
                  entity.platform != 'select' &&
                  entity.platform != 'text' &&
                  // Instanced entities render per-outlet below, not here.
                  // Which family's controls apply (a strip's per-outlet
                  // switches, a bulb's light, a plug's relay) is the spec's
                  // variant scoping, settled by _refineSurface — not a rule
                  // here.
                  !entity.isInstanced)) ...[
                _entityCard(entity),
                const SizedBox(height: 12),
              ],
              // A power strip's outlets: one switch per child, named by its
              // alias, under a header that names it a strip. Empty (so nothing
              // renders) on a single-outlet plug.
              if (_hasInstanceChildren) ...[
                Row(
                  children: [
                    PowerStripIcon(
                        size: 22,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text('Outlets',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              for (final entity
                  in _drawableEntities.where((e) => e.isInstanced))
                for (final child in _instances[entity.name] ??
                    const <NetworkInstanceDto>[]) ...[
                  _instanceSwitchCard(entity, child),
                  const SizedBox(height: 12),
                ],
              // The remote's buttons share one card: twenty-seven separate
              // cards would bury the D-pad below the fold, and a remote is
              // one control surface, not a list of readings.
              if (_buttons.isNotEmpty) ...[
                _remoteCard(_buttons),
                const SizedBox(height: 12),
              ],
              // The keyboard when the device says a field is focused: right
              // under the controls, where a hand reaches after steering the
              // D-pad onto a search box — and above the channel picker, which
              // is the once-a-session tap.
              if (_keyboardFocused == true)
                for (final entity in _textEntities) ...[
                  _entityCard(entity),
                  const SizedBox(height: 12),
                ],
              // The channel picker is the foot of the remote: launching Plex
              // or Prime matters, but it is the tap you reach for once —
              // not the D-pad you steer with — so it waits under the pad
              // rather than pushing the pad down when its options arrive.
              for (final entity in _drawableEntities
                  .where((entity) => entity.platform == 'select')) ...[
                _entityCard(entity),
                const SizedBox(height: 12),
              ],
              // The keyboard when we cannot tell whether it's usable (no signed
              // session, or the query failed): parked at the very foot, out of
              // the way but still reachable — hiding a control the user might
              // need is worse than one extra card down here. A positive "no
              // field focused" is the one case it shows nowhere at all.
              if (_keyboardFocused == null)
                for (final entity in _textEntities) ...[
                  _entityCard(entity),
                  const SizedBox(height: 12),
                ],
              if (_hiddenNames.isNotEmpty) ...[
                _hiddenControlsNote(),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 16),
              _deviceInfo(description),
            ],
          ],
        ),
      ),
    );
  }

  List<NetworkEntityDto> get _buttons =>
      _drawableEntities.where((entity) => entity.platform == 'button').toList();

  /// The `text` entities (a Roku's on-screen keyboard). Placed by
  /// [_keyboardFocused] rather than in the ordinary entity list — above the
  /// channel picker when a field is focused, below it when the state is
  /// unknown, nowhere when the device says nothing is focused.
  Iterable<NetworkEntityDto> get _textEntities =>
      _drawableEntities.where((entity) => entity.platform == 'text');

  /// The hide rule's honest half: the spec declares controls this app cannot
  /// offer yet (a transport it does not speak, a binding it cannot resolve),
  /// and one muted line says so instead of silently pretending they were
  /// never declared.
  Widget _hiddenControlsNote() {
    final names = _hiddenNames;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final label = names.length == 1
        ? '1 control in this device’s spec is not supported by this app '
            'yet (${names.single}).'
        : '${names.length} controls in this device’s spec are not '
            'supported by this app yet '
            '(${names.take(4).join(', ')}${names.length > 4 ? ', …' : ''}).';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ],
    );
  }

  /// The note shown once a device has refused a command.
  ///
  /// Deliberately says what still worked. A user whose TV ignores every
  /// button is entitled to wonder whether the app found the right device at
  /// all; naming the setting — and pointing out that finding it and reading
  /// from it both succeeded — turns a mystery into one toggle to flip.
  Widget _controlGateNote() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The device is refusing commands',
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSecondaryContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'It answered discovery and lets this app read from it, so '
                    'the connection is fine — it just will not take commands '
                    'over the network yet. On a Roku that is Settings > '
                    'System > Advanced system settings > "Control by mobile '
                    'apps"; other devices word it as network or external '
                    'control. Enable it there, then try again.',
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entityCard(NetworkEntityDto entity) {
    switch (entity.platform) {
      case 'switch':
        return _switchCard(entity);
      case 'select':
        return _selectCard(entity);
      case 'number':
      case 'climate':
        return _numberCard(entity);
      case 'text':
        return _textCard(entity);
      case 'cover':
        return _coverCard(entity);
      case 'fan':
        return _fanCard(entity);
      case 'light':
        // A LIFX light drives itself over UDP — it owns its own sends and
        // live reads. Any other light rides the screen's ordinary send
        // pipeline, routed by each action's declared transport; the card
        // itself only presents.
        final reading = _readings[entity.name];
        return NetworkLightCard(
          entity: entity,
          specYaml: widget.controls.specYaml,
          host: widget.device.host,
          targetMac: widget.device.advertisedMac ?? '',
          sendAction: (action, values) => _send(entity, action, values: values),
          initialOn: reading?.isOn,
          initialBrightness: reading?.number,
        );
      // A platform this switch has no branch for still shows its reading —
      // and, since the resolver may well have found it controls, its actions.
      // Without the second half this default is the same defect the unclaimed
      // rows above exist to close, one level up: a spec declaring a platform
      // the catalogue has not needed yet would draw a value and no way to
      // change it, with nothing saying so. Nothing in the catalogue reaches
      // here today; that is precisely when the branch is cheap to get right.
      default:
        return _sensorCard(entity, tail: _unclaimedActions(entity, const {}));
    }
  }

  /// Text entry into whatever field the device has focused — the on-screen
  /// keyboard's peer. The wire carries one character per send (Roku's Lit_
  /// key form), so typing is relayed a keystroke at a time: each change is
  /// diffed against what the device last saw, and removals send the press
  /// action (backspace) once per removed character. Serialized through a
  /// per-entity chain because two Lit_ POSTs in flight can land reversed.
  Widget _textCard(NetworkEntityDto entity) {
    final submit = _actionFor(entity, 'submit');
    final backspace = _actionFor(entity, 'press');
    final controller =
        _textControllers.putIfAbsent(entity.name, TextEditingController.new);
    final icon = entityIconFor(icon: entity.icon);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
              ],
              Text(entity.name,
                  style:
                      text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: submit != null,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: 'Type to the focused field on the device',
                  ),
                  onChanged: submit == null
                      ? null
                      : (value) => _onTyped(entity, submit, backspace, value),
                ),
              ),
              if (backspace != null)
                IconButton(
                  tooltip: 'Backspace',
                  icon: const Icon(Icons.backspace_outlined),
                  onPressed: submit == null
                      ? null
                      : () => _typeBackspace(entity, controller, backspace),
                ),
            ],
          ),
          // `press` is the deletion key drawn above, claimed whether or not
          // the spec bound one — the field and its backspace are this card's.
          _unclaimedActions(entity, const {'submit', 'press'}),
          const SizedBox(height: 4),
          Text('Types into whatever field is focused on the device.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// Relay one edit as keystrokes: delete what was removed, type what was
  /// added, leaving a common prefix alone.
  void _onTyped(NetworkEntityDto entity, NetworkActionDto submit,
      NetworkActionDto? backspace, String value) {
    final last = (_typedText[entity.name] ?? '').characters.toList();
    final next = value.characters.toList();
    var common = 0;
    while (common < last.length &&
        common < next.length &&
        last[common] == next[common]) {
      common++;
    }
    _typedText[entity.name] = value;
    for (var i = common; i < last.length; i++) {
      if (backspace != null) _enqueueKeystroke(entity, backspace);
    }
    for (var i = common; i < next.length; i++) {
      _enqueueKeystroke(entity, submit, value: next[i]);
    }
  }

  /// The card's backspace button: delete on the device, and keep the local
  /// picture of its field in step so the next diff starts from the truth.
  void _typeBackspace(NetworkEntityDto entity, TextEditingController controller,
      NetworkActionDto backspace) {
    final current = _typedText[entity.name] ?? '';
    if (current.isNotEmpty) {
      final shortened = current.characters.skipLast(1).toString();
      _typedText[entity.name] = shortened;
      controller.value = TextEditingValue(
        text: shortened,
        selection: TextSelection.collapsed(offset: shortened.length),
      );
    }
    _enqueueKeystroke(entity, backspace);
  }

  void _enqueueKeystroke(NetworkEntityDto entity, NetworkActionDto action,
      {String? value}) {
    final previous = _keystrokeChains[entity.name] ?? Future<void>.value();
    _keystrokeChains[entity.name] =
        previous.then((_) => _sendKeystroke(entity, action, value: value));
  }

  /// One keystroke. A refusal is the same device-side gate a button press
  /// hits, so it raises the standing note; anything else just costs the one
  /// character — logged, not surfaced, or every stray packet would steal the
  /// screen mid-word.
  Future<void> _sendKeystroke(NetworkEntityDto entity, NetworkActionDto action,
      {String? value}) async {
    final values = <String, String>{};
    if (value != null && action.userParams.isNotEmpty) {
      values[action.userParams.first] = value;
    }
    try {
      if (action.transport == 'http') {
        await _sender.sendAction(action, values);
      } else {
        await _sender.sendAction(action, values, description: _description);
      }
    } on ControlRefusedException {
      if (mounted) setState(() => _controlRefused = true);
    } catch (e) {
      Log.net.debug('keystroke failed for ${entity.name}: $e');
    }
  }

  /// The remote's buttons as one remote-shaped card: power up top, a D-pad
  /// with OK in the middle, transport keys beneath it, then volume and
  /// channel rockers — the arrangement a hand expects from the physical
  /// remote, rather than one long wrap. Buttons are placed by the entity
  /// names the spec declares (it names them after the keys they send);
  /// anything this layout does not know by name lands in a wrap at the
  /// bottom, so a spec addition never renders an unreachable control.
  Widget _remoteCard(List<NetworkEntityDto> buttons) {
    // Slots resolve by the spec's semantic `key` first, the historical
    // display-name table second (see EntityKeyIndex) — so a keyed spec lays
    // out correctly whatever it names its buttons, an un-keyed one keeps
    // today's behavior, and either way an unplaced control still renders in
    // the wrap at the foot.
    final index = EntityKeyIndex<NetworkEntityDto>(
      buttons,
      keyOf: (entity) => entity.key,
      nameOf: (entity) => entity.name,
    );
    final power = index.takeAll(EntityKeyIndex.powerSlots);
    final nav = index.takeAll(EntityKeyIndex.navSlots);
    final up = index.take(EntityKeyIndex.upSlot);
    final left = index.take(EntityKeyIndex.leftSlot);
    final ok = index.take(EntityKeyIndex.okSlot);
    final right = index.take(EntityKeyIndex.rightSlot);
    final down = index.take(EntityKeyIndex.downSlot);
    final underPad = index.takeAll(EntityKeyIndex.underPadSlots);
    final transport = index.takeAll(EntityKeyIndex.transportSlots);
    final volume = index.takeAll(EntityKeyIndex.volumeSlots);
    final channel = index.takeAll(EntityKeyIndex.channelSlots);
    final misc = index.takeAll(EntityKeyIndex.miscSlots);
    final inputs = index.takeAll(EntityKeyIndex.inputSlots);
    final leftover = index.leftovers;

    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    // A Wrap, not a Row. These rows hold whatever the spec keyed, and a keyed
    // button is a `FilledButton.tonalIcon` — icon, label and padding — so the
    // width is the spec's to decide, not this layout's. Three of them
    // (back/home/exit, which six TV specs bind) overflow a 360dp phone by
    // 131px inside the Card's padding chain and clip the last key into
    // something untappable; widget tests run at 800x600 and never see it. The
    // input row and the leftover pile already wrap for exactly this reason.
    Widget labeledRow(List<NetworkEntityDto> entities,
            {WrapAlignment alignment = WrapAlignment.center}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Wrap(
            alignment: alignment,
            spacing: 8,
            runSpacing: 8,
            children: [for (final entity in entities) _remoteButton(entity)],
          ),
        );

    Widget keyCell(NetworkEntityDto? entity) => SizedBox(
          width: 72,
          height: 52,
          child: entity == null ? null : Center(child: _remoteKey(entity)),
        );

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Remote',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (power.isNotEmpty) labeledRow(power, alignment: WrapAlignment.end),
          if (nav.isNotEmpty) labeledRow(nav),
          if (up != null ||
              left != null ||
              ok != null ||
              right != null ||
              down != null)
            Center(
              child: Column(
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    keyCell(null),
                    keyCell(up),
                    keyCell(null),
                  ]),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    keyCell(left),
                    keyCell(ok),
                    keyCell(right),
                  ]),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    keyCell(null),
                    keyCell(down),
                    keyCell(null),
                  ]),
                ],
              ),
            ),
          if (underPad.isNotEmpty) labeledRow(underPad),
          // Transport keys are icons on every physical remote; labels here
          // are what overflowed the old wrap on narrow screens.
          if (transport.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final entity in transport)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: _remoteKey(entity),
                    ),
                ],
              ),
            ),
          if (volume.isNotEmpty || channel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (volume.isNotEmpty)
                    Column(children: [
                      for (final entity in volume)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: _remoteKey(entity),
                        ),
                    ]),
                  if (channel.isNotEmpty)
                    Column(children: [
                      for (final entity in channel)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: _remoteKey(entity),
                        ),
                    ]),
                ],
              ),
            ),
          if (misc.isNotEmpty) labeledRow(misc),
          if (inputs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Inputs',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final entity in inputs) _remoteButton(entity)],
            ),
          ],
          if (leftover.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final entity in leftover) _remoteButton(entity)],
            ),
          ],
        ],
      ),
    );
  }

  /// An icon-only remote key for the D-pad and rockers, where a fixed shape
  /// reads as the pad it is. Falls back to the labeled button when the spec
  /// names no drawable icon — for a key like OK the name IS the picture.
  Widget _remoteKey(NetworkEntityDto entity) {
    final action = _actionFor(entity, 'press');
    final busy = _sending.contains(entity.name);
    final icon = entityIconFor(icon: entity.icon);
    if (icon == null && !busy) return _remoteButton(entity);
    return IconButton.filledTonal(
      tooltip: entity.name,
      onPressed: (busy || action == null)
          ? null
          : () => unawaited(_send(entity, action)),
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon),
    );
  }

  Widget _remoteButton(NetworkEntityDto entity) {
    final action = _actionFor(entity, 'press');
    final busy = _sending.contains(entity.name);
    final icon = entityIconFor(icon: entity.icon);
    final label = Text(entity.name);
    final onPressed = (busy || action == null)
        ? null
        : () => unawaited(_send(entity, action));
    // The spec's icon when it names one this app can draw; a plain label
    // otherwise — for a remote key like OK the name IS the picture.
    if (icon == null && !busy) {
      return FilledButton.tonal(onPressed: onPressed, child: label);
    }
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon),
      label: label,
    );
  }

  Widget _card({required Widget child}) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: child,
        ),
      );

  /// The tail every curated card below ends with: the actions this entity
  /// resolved that the card itself did not draw.
  ///
  /// A card asks for the handful of roles it knows by name and never learns
  /// what else the resolver produced, so a role can be bound by a spec,
  /// resolved by Rust and still reach nobody — the Hisense set, whose only
  /// power channel is `toggle`, drew a title, a state line and no control at
  /// all. [claimed] is what the card is responsible for, whether or not it is
  /// on screen this build; everything else lands here.
  ///
  /// Nothing renders — the gap included — when the card claimed every
  /// resolved role: a Padding around an empty row still takes its height, and
  /// a card that already draws everything must look exactly as it did before.
  Widget _unclaimedActions(NetworkEntityDto entity, Set<String> claimed) {
    final unclaimed = entity.actions
        .where((action) => !claimed.contains(action.role))
        .toList(growable: false);
    if (unclaimed.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: UnclaimedActions(
        actions: [
          for (final action in entity.actions)
            (role: action.role, takesValue: action.userParams.isNotEmpty),
        ],
        claimed: claimed,
        // This screen's own send path, so an unclaimed action gets the same
        // read-back, the same refusal note and the same busy flag as the
        // control drawn beside it — one sender, not two.
        onSend: (role) async {
          final action = _actionFor(entity, role);
          if (action != null) await _send(entity, action);
        },
        // `_sending` keys on the entity rather than the role, so there is no
        // per-role wait to show: the row goes inert while this entity is
        // mid-send instead of putting a spinner on the wrong button.
        enabled: !_sending.contains(entity.name) && !unclaimed.any(_lockedFor),
      ),
    );
  }

  Widget _switchCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final isOn = reading?.isOn;
    final turnOn = _actionFor(entity, 'turn_on');
    final turnOff = _actionFor(entity, 'turn_off');
    final busy = _sending.contains(entity.name);
    // A single Kasa outlet/switch names itself in get_sysinfo (alias) — a wall
    // switch called "Kitchen Lights", a plug called "Desk Lamp". Prefer that
    // over the generic "Outlet", the same way a strip's per-outlet cards show
    // each child's alias.
    final kasaState = _isKasa ? _stateByCommand[entity.stateCommand] : null;
    final alias = kasaState?['alias'];
    final title = (alias != null && alias.isNotEmpty) ? alias : entity.name;
    // A Switch needs both directions to be honest: one that can only turn off
    // is a control whose on side is broken, which is worse than no Switch.
    final drawsSwitch = turnOn != null && turnOff != null;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (isOn == null)
                      Text('State unknown',
                          style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else if (drawsSwitch)
                Switch(
                  value: isOn ?? false,
                  onChanged: (_lockedFor(turnOn) || _lockedFor(turnOff))
                      ? null
                      : (wantOn) =>
                          unawaited(_send(entity, wantOn ? turnOn : turnOff)),
                ),
            ],
          ),
          // Claimed = what this build actually DREW, not what the card knows
          // how to draw. A one-way power entity — LG and Samsung both declare
          // `commands: {turn_off: ...}` with a note saying to render it as a
          // one-way off — resolves only `turn_off`, so the Switch above cannot
          // be honest and is not drawn at all. Listing `turn_off` as claimed
          // anyway filtered the entity's ONLY sendable action out of the row
          // below, leaving a title, a state line and a dead toggle: the exact
          // shape UnclaimedActions exists to end.
          _unclaimedActions(
            entity,
            drawsSwitch ? const {'turn_on', 'turn_off'} : const {},
          ),
        ],
      ),
    );
  }

  /// One outlet of a power strip, named by its alias — the instanced twin of
  /// [_switchCard]. Its on/off reads from the child's `is_on` role and its
  /// toggle scopes the write to this outlet's id via [_sendKasaChild].
  Widget _instanceSwitchCard(
      NetworkEntityDto entity, NetworkInstanceDto child) {
    final isOn =
        _instanceReadings['${entity.name}/${child.id}']?['is_on']?.isOn;
    final turnOn = _actionFor(entity, 'turn_on');
    final turnOff = _actionFor(entity, 'turn_off');
    final busy = _sending.contains('${entity.name}/${child.id}');

    return _card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(child.label,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (isOn == null)
                  Text('State unknown',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            Switch(
              value: isOn ?? false,
              onChanged: (turnOn == null ||
                      turnOff == null ||
                      _lockedFor(turnOn) ||
                      _lockedFor(turnOff))
                  ? null
                  : (wantOn) =>
                      unawaited(_sendKasaChild(entity, child, wantOn)),
            ),
        ],
      ),
    );
  }

  Widget _selectCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final action = _actionFor(entity, 'select_option');
    final busy = _sending.contains(entity.name);
    // Options either come from the spec's own table or from the device, and
    // where they came from decides how "which is current" is answered: a
    // spec-optioned select decodes it from a state reading, a device-optioned
    // one is told directly by the query the options came from.
    final fetched = _fetchedOptions[entity.name];
    final options = fetched != null
        ? [
            for (final entry in fetched)
              if (entry.value != null)
                NetworkOptionDto(
                    raw: entry.value!,
                    label: entry.label.isEmpty ? entry.value! : entry.label),
          ]
        : entity.options;
    final currentRaw = fetched != null
        ? _currentOption[entity.name]
        : (reading?.kind == NetworkReadingKind.option ? reading?.raw : null);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(entity.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (busy)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (reading?.kind == NetworkReadingKind.unknownOption)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // Never renamed to a known option: an unrecognised Crock-Pot
                // mode shown as "off" tells a user their cooker is off while
                // it is heating.
                'Unrecognized state (${reading!.raw})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          // A device-sourced list that came back empty is worth a word: the
          // chips are simply absent otherwise, which reads as a bug rather
          // than as a device that answered with nothing. A refusal reads
          // differently again — the list exists, the device will not share
          // it until its control setting changes — and a query that never
          // got an answer is different from both.
          if (entity.optionsSource != null && options.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                (_loading || _loadingOptions)
                    ? 'Asking the device...'
                    : _controlRefused
                        ? 'The device is refusing to share this list. Enable '
                            'control by mobile apps on it, then refresh.'
                        : _optionsUnavailable.contains(entity.name)
                            ? 'The device did not answer. It may be asleep — '
                                'refresh to try again.'
                            : 'The device listed nothing here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text(option.label),
                  selected: option.raw == currentRaw,
                  onSelected: (busy || action == null || _lockedFor(action))
                      ? null
                      : (_) =>
                          unawaited(_send(entity, action, value: option.raw)),
                ),
            ],
          ),
          _unclaimedActions(entity, const {'select_option'}),
        ],
      ),
    );
  }

  Widget _numberCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final action = _actionFor(entity, 'set_value');
    final busy = _sending.contains(entity.name);
    final unit = displayUnit(entity.unit);
    final min = entity.setpointMin;
    final max = entity.setpointMax;
    final step = entity.setpointStep;
    // A slider needs a bounded range to be honest; without one the edit
    // dialog (which can validate what it is told after the fact) stays.
    final hasRange = action != null && min != null && max != null && max > min;
    final pending = _pendingSetpoints[entity.name];
    final shown = pending ?? reading?.number;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entity.name,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                      shown == null
                          ? (reading == null
                              ? 'Unknown'
                              : '${reading.raw}${unit == null ? '' : ' $unit'}')
                          : '${_trimNumber(shown)}${unit == null ? '' : ' $unit'}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else if (action != null && !hasRange)
                IconButton(
                  tooltip: 'Set ${entity.name}',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _lockedFor(action)
                      ? null
                      : () => unawaited(_editNumber(entity, action)),
                ),
            ],
          ),
          if (hasRange)
            Slider(
              semanticFormatterCallback: (v) =>
                  '${entity.name} ${_trimNumber(v)}'
                  '${unit == null ? '' : ' $unit'}',
              value: (shown ?? min).clamp(min, max),
              min: min,
              max: max,
              divisions: _sliderDivisions(min, max, step),
              label: shown == null ? null : _trimNumber(shown),
              onChanged: (busy || _lockedFor(action))
                  ? null
                  : (value) =>
                      setState(() => _pendingSetpoints[entity.name] = value),
              onChangeEnd: (busy || _lockedFor(action))
                  ? null
                  : (value) => unawaited(
                      _send(entity, action, value: _trimNumber(value))),
            ),
          _unclaimedActions(entity, const {'set_value'}),
        ],
      ),
    );
  }

  /// A number rendered the way it will be sent: whole when it is whole, one
  /// decimal otherwise (the finest step the specs declare).
  static String _trimNumber(double value) => value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);

  /// Slider detents from the declared step, capped so a wide range with a
  /// tiny step does not build thousands of divisions.
  static int? _sliderDivisions(double min, double max, double? step) {
    if (step == null || step <= 0) return null;
    final count = ((max - min) / step).round();
    return (count >= 1 && count <= 400) ? count : null;
  }

  Future<void> _editNumber(
      NetworkEntityDto entity, NetworkActionDto action) async {
    final controller = TextEditingController(
        text: _readings[entity.name]?.number?.toStringAsFixed(0) ?? '');
    final min = entity.setpointMin;
    final max = entity.setpointMax;
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Set ${entity.name}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            suffixText: displayUnit(entity.unit),
            helperText: switch ((min, max)) {
              (final double lo, final double hi) =>
                'Between ${lo.toStringAsFixed(0)} and ${hi.toStringAsFixed(0)}',
              (final double lo, null) => 'At least ${lo.toStringAsFixed(0)}',
              _ => null,
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null || entered.isEmpty || !mounted) return;
    final value = double.tryParse(entered);
    if (value == null ||
        (min != null && value < min) ||
        (max != null && value > max)) {
      setState(() => _error = 'That is not a value the device accepts.');
      return;
    }
    await _send(entity, action, value: value.toStringAsFixed(0));
  }

  /// A cover — the garage-door shape: three motion buttons that are always
  /// honest (they command travel, not state), a state line when the device
  /// reports one, and a position slider only when there is a live position
  /// to anchor it to.
  Widget _coverCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final open = _actionFor(entity, 'open_cover');
    final close = _actionFor(entity, 'close_cover');
    final stop = _actionFor(entity, 'stop_cover');
    final position = _actionFor(entity, 'set_cover_position');
    final busy = _sending.contains(entity.name);
    final icon = entityIconFor(icon: entity.icon) ??
        (entity.deviceClass == 'garage'
            ? Icons.garage_outlined
            : Icons.curtains_outlined);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final positionValue = reading?.number;
    final positionMin = position?.min ?? 0;
    final positionMax = position?.max ?? 1;

    Widget motion(NetworkActionDto? action, IconData icon, String label) =>
        Expanded(
          child: OutlinedButton.icon(
            onPressed: (action == null || busy || _lockedFor(action))
                ? null
                : () => unawaited(_send(entity, action)),
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(entity.name,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (busy)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else if (reading != null)
                Text(reading.label ?? reading.raw, style: text.bodyMedium),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              motion(open, Icons.arrow_upward, 'Open'),
              const SizedBox(width: 8),
              motion(stop, Icons.stop, 'Stop'),
              const SizedBox(width: 8),
              motion(close, Icons.arrow_downward, 'Close'),
            ],
          ),
          // The slider claims to show where the door is, so it is earned
          // only by a live position reading; the motions above need no such
          // proof.
          if (position != null &&
              positionValue != null &&
              positionMax > positionMin)
            Slider(
              // A cover's position slider reads as a bare fraction otherwise,
              // and this one drives a garage door.
              semanticFormatterCallback: (v) =>
                  '${entity.name} position ${_trimNumber(v)}',
              value: positionValue.clamp(positionMin, positionMax),
              min: positionMin,
              max: positionMax,
              onChanged: (busy || _lockedFor(position)) ? null : (_) {},
              onChangeEnd: (busy || _lockedFor(position))
                  ? null
                  : (value) => unawaited(
                      _send(entity, position, value: value.toString())),
            ),
          _unclaimedActions(entity, const {
            'open_cover',
            'close_cover',
            'stop_cover',
            'set_cover_position',
          }),
        ],
      ),
    );
  }

  /// A fan: power, a percentage slider, and oscillation — each rendered only
  /// when its role resolved.
  Widget _fanCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final turnOn = _actionFor(entity, 'turn_on');
    final turnOff = _actionFor(entity, 'turn_off');
    final percentage = _actionFor(entity, 'set_percentage');
    final oscillating = _actionFor(entity, 'set_oscillating');
    final busy = _sending.contains(entity.name);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isOn = reading?.isOn;
    final min = percentage?.min ?? 0;
    final max = percentage?.max ?? 100;
    final pending = _pendingSetpoints[entity.name];
    final speed = pending ?? reading?.number;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mode_fan_off_outlined,
                  size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(entity.name,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (busy)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else if (turnOn != null && turnOff != null)
                Switch(
                  value: isOn ?? false,
                  onChanged: (_lockedFor(turnOn) || _lockedFor(turnOff))
                      ? null
                      : (wantOn) =>
                          unawaited(_send(entity, wantOn ? turnOn : turnOff)),
                ),
            ],
          ),
          if (percentage != null && max > min)
            Slider(
              semanticFormatterCallback: (v) =>
                  '${entity.name} speed ${_trimNumber(v)}',
              value: (speed ?? min).clamp(min, max),
              min: min,
              max: max,
              label: speed == null ? null : _trimNumber(speed),
              onChanged: (busy || _lockedFor(percentage))
                  ? null
                  : (value) =>
                      setState(() => _pendingSetpoints[entity.name] = value),
              onChangeEnd: (busy || _lockedFor(percentage))
                  ? null
                  : (value) => unawaited(
                      _send(entity, percentage, value: _trimNumber(value))),
            ),
          if (oscillating != null)
            Row(
              children: [
                Text('Oscillate', style: text.bodyMedium),
                const Spacer(),
                OutlinedButton(
                  onPressed: (busy || _lockedFor(oscillating))
                      ? null
                      : () => unawaited(_send(entity, oscillating, value: '1')),
                  child: const Text('On'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: (busy || _lockedFor(oscillating))
                      ? null
                      : () => unawaited(_send(entity, oscillating, value: '0')),
                  child: const Text('Off'),
                ),
              ],
            ),
          _unclaimedActions(entity, const {
            'turn_on',
            'turn_off',
            'set_percentage',
            'set_oscillating',
          }),
        ],
      ),
    );
  }

  /// A reading, with an optional [tail] beneath it — the unclaimed-actions row
  /// for the `default:` arm of [_entityCard], whose entity may have resolved
  /// controls this screen has no card for. Every named platform passes none.
  Widget _sensorCard(NetworkEntityDto entity, {Widget? tail}) {
    final reading = _readings[entity.name];
    final unit = displayUnit(entity.unit);
    final value = switch (reading?.kind) {
      null => 'Unknown',
      NetworkReadingKind.option => reading!.label ?? reading.raw,
      NetworkReadingKind.onOff => (reading!.isOn ?? false) ? 'On' : 'Off',
      _ => '${reading!.raw}${unit == null ? '' : ' $unit'}',
    };
    // The BLE readings' presentation, ported: the spec's icon (or what the
    // device_class implies) and — where a healthy band is established
    // (CO₂, radon, humidity, battery…) — a one-word verdict chip, because
    // "934 ppm" answers a question nobody asked.
    final icon =
        entityIconFor(icon: entity.icon, deviceClass: entity.deviceClass);
    final level = sensorReadingLevel(
      deviceClass: entity.deviceClass,
      unit: unit,
      value: reading?.number,
    );
    final showLevel = level != null &&
        sensorLevelVisible(deviceClass: entity.deviceClass, level: level);
    final row = Row(
      children: [
        if (icon != null) ...[
          Icon(icon,
              size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(entity.name,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ),
        if (showLevel) ...[
          SensorLevelChip(level: level),
          const SizedBox(width: 8),
        ],
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );
    return _card(
      child: tail == null
          ? row
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [row, tail],
            ),
    );
  }

  Widget _deviceInfo(SoapDeviceDescription? description) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String)>[
      // The control address, not the advertised one: this screen's whole
      // subject is what it sends and where, and a row naming a port nothing
      // here talks to is what makes a wrong-port bug invisible.
      ('Address', '${widget.device.host}:${widget.device.controlPort ?? '?'}'),
      if (description?.serialNumber != null)
        ('Serial', description!.serialNumber!),
      if (description?.firmwareVersion != null)
        ('Firmware', description!.firmwareVersion!),
      if (description?.udn != null) ('UDN', description!.udn!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90,
                  child: Text(label,
                      style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
                ),
                Expanded(child: SelectableText(value, style: text.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}
