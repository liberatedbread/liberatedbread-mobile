// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/entity_icon.dart';
import '../core/error_text.dart';
import '../core/log.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/http_control_service.dart';
import '../services/json_fields.dart';
import '../services/kasa_control_service.dart';
import '../services/network_command_sender.dart';
import '../services/query_source_reader.dart';
import '../services/rabbit_air_control_service.dart';
import '../services/rabbit_air_key_store.dart';
import '../services/soap_control_service.dart';
import '../services/spec_codec.dart';
import '../widgets/network_light_card.dart';
import '../widgets/power_strip_icon.dart';

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

  const NetworkDeviceScreen({
    super.key,
    required this.device,
    required this.controls,
  });

  @override
  ConsumerState<NetworkDeviceScreen> createState() =>
      _NetworkDeviceScreenState();
}

class _NetworkDeviceScreenState extends ConsumerState<NetworkDeviceScreen> {
  SoapDeviceDescription? _description;
  final Map<String, Map<String, String>> _stateByCommand = {};
  final Map<String, NetworkReadingDto?> _readings = {};

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
  double? _kasaBrightnessDraft;

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

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    _keyboardPoll?.cancel();
    _statePoll?.cancel();
    unawaited(_keyboardSub?.cancel());
    unawaited(_sender.close());
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _sender = ref.read(networkCommandSenderFactoryProvider)(
      device: widget.device,
      specYaml: widget.controls.specYaml,
    );
    unawaited(_load());
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
    final hasKeyboard = _entities.any((e) => e.platform == 'text');
    if (!hasKeyboard || !widget.device.ssdpTargets.contains('roku:ecp')) return;
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

  List<NetworkEntityDto> get _entities => widget.controls.entities;

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

  /// A Kasa SMARTBULB (KL430 and kin) answering the plug spec: it reports a
  /// `light_state` object, not a top-level `relay_state`, so the plug's on/off
  /// switch would be a dead control — no state to read, and the bulb ignores
  /// set_relay_state. We recognise it and hide that switch, pointing on/off and
  /// brightness at the Kasa app for now, rather than render a switch that lies.
  bool get _isKasaBulb =>
      _rawStateReply.values.any((reply) => reply.contains('"light_state"'));

  /// A Kasa light STRIP (KL400/KL430) rather than a bulb: it is SMARTBULB-class
  /// but switches and dims through smartlife.iot.lightStrip.set_light_state, not
  /// the bulb's lightingservice.transition_light_state — a strip silently
  /// ignores the bulb call. Told apart by the `length` (LED count) field
  /// get_sysinfo carries. Selects the strip_* commands over the bulb light_*.
  bool get _isKasaLightStrip =>
      _stateByCommand['get_sysinfo']?.containsKey('length') ?? false;

  /// The bulb's current on/off and brightness, parsed from the raw get_sysinfo
  /// light_state. When off, on_off is 0 and the last brightness lives under
  /// `dft_on_state`; when on it is at the top of light_state. Null when there
  /// is no light_state to read.
  ({bool on, int brightness})? get _kasaLight {
    for (final reply in _rawStateReply.values) {
      try {
        final decoded = jsonDecode(reply);
        final system = decoded is Map ? decoded['system'] : null;
        final sysinfo = system is Map ? system['get_sysinfo'] : null;
        final ls = sysinfo is Map ? sysinfo['light_state'] : null;
        if (ls is! Map) continue;
        final on = ls['on_off'] is num && (ls['on_off'] as num) != 0;
        final source = on
            ? ls
            : (ls['dft_on_state'] is Map ? ls['dft_on_state'] as Map : ls);
        final b = source['brightness'];
        return (on: on, brightness: b is num ? b.toInt() : 0);
      } catch (_) {
        // Malformed reply — fall through to the note.
      }
    }
    return null;
  }

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

  /// The user key this session is driving the device under, or null when none
  /// is stored — which is what brings up the key-entry card instead of the
  /// controls.
  String? _rabbitAirKey;

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

  /// Whether anything on this screen needs the UPnP description document.
  ///
  /// SOAP is what it exists for, and the only transport that needs it: state
  /// reads and SOAP sends resolve their control URL from it. A device whose
  /// surface is entirely plain HTTP (a Roku remote's buttons, an Envoy's
  /// state poll), binary UDP (a LIFX strip) or Kasa (a raw socket) has no
  /// `setup.xml` to fetch — asking for one turns a working device into a
  /// permanent error screen. So this keys on `soap` specifically and on state
  /// commands whose transport is not `http`, and excludes Kasa and Rabbit Air
  /// outright: their entities carry a `state_command` (get_sysinfo /
  /// get_state) but poll it over their own sockets, not from a description.
  bool get _needsDescription =>
      !_isKasa &&
      !_isRabbitAir &&
      (_stateCommands.any((command) => _stateTransport(command) != 'http') ||
          _entities.any(
              (e) => e.actions.any((action) => action.transport == 'soap')));

  /// Loaded enough to draw controls: the description is fetched, or nothing
  /// on this screen wants it.
  bool get _ready => _description != null || !_needsDescription;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isKasa) {
        // No description to fetch and no control URLs to resolve — poll the
        // relay state straight over the socket. The port is 9999, not a UPnP
        // LOCATION, so the SOAP port check below does not apply.
        await _refreshState();
      } else if (_isRabbitAir) {
        // No description either — but every exchange is encrypted under the
        // per-device user key, so load it first; without it there is nothing
        // to poll, and the key-entry card shows instead of the controls.
        _rabbitAirKey = await ref
            .read(rabbitAirKeyStoreProvider)
            .userKey(_rabbitAirKeyScope);
        if (_rabbitAirKey != null) await _refreshState();
      } else {
        final port = widget.device.controlPort;
        if (port == null) {
          // Nothing advertised a port at all — not a device this screen can
          // drive.
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
    if (_isRabbitAir) {
      await _refreshStateRabbitAir();
      return;
    }
    final codec = ref.read(specCodecProvider);
    final client = ref.read(soapControlClientProvider);

    for (final command in _stateCommands) {
      if (_stateTransport(command) == 'http') {
        await _refreshStateHttp(command);
        continue;
      }
      final description = _description!;
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
  /// GET, send it, and flatten the JSON reply into the name→value pairs the
  /// entity decoder reads. The Kasa poll's structural twin over HTTP — fill
  /// `_stateByCommand`, then the shared decode — but through
  /// [HttpControlClient], with the reply flattened here.
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
      values: const {},
    );
    try {
      final body = await _sendNetworkHttp(request);
      _stateByCommand[command] = jsonStateFields(body);
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

  /// The Rabbit Air state poll: sync the device clock (once per session, via
  /// the spec's `time_sync` command), then render `get_state`, encrypt it
  /// under the user key, and send it as one UDP datagram — the Kasa poll's
  /// structural twin, one transport over. The decrypted reply's `data` object
  /// is flattened into the name→value pairs the entity decoder reads (the
  /// spec's state_mapping paths are rooted at that object), then the shared
  /// decode runs.
  Future<void> _refreshStateRabbitAir() async {
    final key = _rabbitAirKey;
    if (key == null) return; // No key, nothing to poll — the card is up.
    final codec = ref.read(specCodecProvider);
    final client = ref.read(rabbitAirControlClientProvider);
    final host = widget.device.host;
    final port = _rabbitAirHostPort;

    await client.syncClock(host, port,
        specYaml: widget.controls.specYaml, userKey: key);
    for (final command in _stateCommands) {
      final request = await codec.renderNetworkRabbitAirStateRequest(
        specYaml: widget.controls.specYaml,
        stateCommand: command,
        requestId: client.nextRequestId(),
        deviceTs: client.deviceTs(host),
      );
      final reply = await client.send(host, port, request, userKey: key);
      _stateByCommand[command] = rabbitAirStateFields(reply);
    }
    await _decodeEntities();
  }

  /// Decode every entity from whatever `_stateByCommand` currently holds — the
  /// step shared by both transports' state refresh, so a reading means the
  /// same thing whichever socket carried it.
  Future<void> _decodeEntities() async {
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
    if (widget.device.controlPort == null) return;
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
  }) async {
    // HTTP, Kasa and Rabbit Air sends are independent — no read-back
    // coupling — so they do not serialize behind the single-SOAP-write gate
    // the Crock-Pot needs.
    final independent = action.transport == 'http' ||
        action.transport == _kasaTransport ||
        action.transport == _rabbitAirTransport;
    // The disabled controls are the visible gate; this is the real one — a
    // tap can race the rebuild that greys the SOAP controls out.
    if (!independent && _soapSending != null) return;
    setState(() {
      _sending.add(entity.name);
      if (!independent) _soapSending = entity.name;
      _error = null;
    });
    try {
      final values = <String, String>{};
      if (value != null && action.userParams.isNotEmpty) {
        values[action.userParams.first] = value;
      }
      await _sender.sendAction(
        action,
        values,
        description: _description,
        rabbitAirKey: _rabbitAirKey,
      );
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

  /// Whether [action]'s control must sit out the current SOAP write. HTTP
  /// presses, Kasa sends and Rabbit Air sends never lock out — see
  /// [_soapSending].
  bool _lockedFor(NetworkActionDto? action) =>
      action != null &&
      action.transport != 'http' &&
      action.transport != _kasaTransport &&
      action.transport != _rabbitAirTransport &&
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

  /// Fixed busy key for the Kasa light card — one control surface, so a write
  /// disables the whole card rather than one widget.
  static const _kasaLightKey = '__kasa_light__';

  /// Send a Kasa bulb command (on/off, brightness) and re-poll so the card
  /// snaps to the bulb's true light_state.
  Future<void> _sendKasaLight(
      String commandName, Map<String, String> values) async {
    setState(() {
      _sending.add(_kasaLightKey);
      _error = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final request = await codec.renderNetworkKasaCommand(
        specYaml: widget.controls.specYaml,
        commandName: commandName,
        values: values,
      );
      await ref
          .read(kasaControlClientProvider)
          .send(widget.device.host, _kasaHostPort, request);
      await _refreshState();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyErrorText(e,
          context: 'device control',
          fallback: 'The light did not accept that. Try again.'));
    } finally {
      if (mounted) setState(() => _sending.remove(_kasaLightKey));
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
            ] else if (_isRabbitAir && _rabbitAirKey == null) ...[
              // Every exchange with this purifier is encrypted under its user
              // key, and none is stored — so the entry card IS the control
              // surface until the owner supplies one.
              _rabbitAirKeyCard(),
              const SizedBox(height: 16),
              _deviceInfo(description),
            ] else ...[
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
              for (final entity in _entities.where((entity) =>
                  entity.platform != 'button' &&
                  entity.platform != 'select' &&
                  entity.platform != 'text' &&
                  // Instanced entities render per-outlet below, not here.
                  !entity.isInstanced &&
                  // On a strip, the plain "Outlet" switch has no top-level
                  // relay_state to read, so it would only ever show "State
                  // unknown" beside the real per-outlet switches — hide it.
                  !(_hasInstanceChildren && entity.platform == 'switch') &&
                  // A Kasa light answering the plug spec has no relay to switch;
                  // hide the dead switch and show the note below instead.
                  !(_isKasaBulb && entity.platform == 'switch'))) ...[
                _entityCard(entity),
                const SizedBox(height: 12),
              ],
              if (_isKasaBulb) ...[
                _kasaLightCard(),
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
              for (final entity in _entities.where((e) => e.isInstanced))
                for (final child in _instances[entity.name] ?? const []) ...[
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
              for (final entity in _entities
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
              const SizedBox(height: 16),
              _deviceInfo(description),
            ],
          ],
        ),
      ),
    );
  }

  List<NetworkEntityDto> get _buttons =>
      _entities.where((entity) => entity.platform == 'button').toList();

  /// The `text` entities (a Roku's on-screen keyboard). Placed by
  /// [_keyboardFocused] rather than in the ordinary entity list — above the
  /// channel picker when a field is focused, below it when the state is
  /// unknown, nowhere when the device says nothing is focused.
  Iterable<NetworkEntityDto> get _textEntities =>
      _entities.where((entity) => entity.platform == 'text');

  /// The card shown for a Rabbit Air purifier with no stored user key:
  /// what the key is, where the owner finds it, and the way in. The key is a
  /// long-lived LAN secret the device generated itself — entered once here,
  /// stored in the platform keychain, and never sent anywhere but to the
  /// purifier it belongs to.
  Widget _rabbitAirKeyCard() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_outlined, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'This purifier needs its user key',
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Rabbit Air encrypts local control with a per-device key. Find '
              'it in the Rabbit Air app: open the device page, tap the '
              'three-dot menu, choose Rename, then tap the device name — the '
              'screen reveals the Thing ID and the 32-character User key.',
              style:
                  text.bodySmall?.copyWith(color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => unawaited(_promptRabbitAirKey()),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Enter user key'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The key-entry dialog: 32 hex characters, validated before anything is
  /// stored — a typo here is a purifier that never answers, so the dialog
  /// says so immediately instead. On save the screen reloads, and the first
  /// poll proves the key against the device.
  Future<void> _promptRabbitAirKey() async {
    final controller = TextEditingController();
    String? validation;
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Rabbit Air user key'),
          content: TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            maxLength: 32,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: '32 hex characters, from the Rabbit Air app',
              helperText: 'Device page → Rename → tap the device name',
              errorText: validation,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final key = controller.text.trim();
                if (!RabbitAirKeyStore.isValidUserKey(key)) {
                  setDialogState(() => validation =
                      'The user key is exactly 32 hex characters (0-9, a-f).');
                  return;
                }
                Navigator.of(context).pop(key);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    // The controller is deliberately NOT disposed here: the dialog's pop
    // animation still builds the TextField for a few frames after showDialog
    // returns, and a focused field schedules a caret frame that would touch
    // a disposed controller. It is dialog-scoped and collected with the tree.
    if (entered == null || !mounted) return;
    await ref
        .read(rabbitAirKeyStoreProvider)
        .saveUserKey(_rabbitAirKeyScope, entered);
    setState(() => _rabbitAirKey = entered);
    await _load();
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

  /// A Kasa smart light answering the plug spec: recognise it and point on/off
  /// and brightness at the Kasa app, rather than render a switch that cannot
  /// work. See [_isKasaBulb].
  Widget _kasaBulbNote() {
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
            Icon(Icons.lightbulb_outline, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This is a Kasa smart light',
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSecondaryContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'It answers the same protocol as a Kasa plug, so this app '
                    'recognises it — but it switches and dims through a '
                    'light_state the plug controls do not drive. Use the Kasa '
                    'app for on/off and brightness for now.',
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

  /// Real on/off + brightness for a Kasa smart bulb, driven over the same
  /// socket as a plug but through the lightingservice (see the spec's light_on
  /// / light_off / set_brightness). Falls back to [_kasaBulbNote] only if the
  /// light_state can't be parsed. The brightness slider commits on release.
  Widget _kasaLightCard() {
    final light = _kasaLight;
    if (light == null) return _kasaBulbNote();
    final busy = _sending.contains(_kasaLightKey);
    final alias = _stateByCommand['get_sysinfo']?['alias'];
    final title = (alias != null && alias.isNotEmpty) ? alias : 'Light';
    final brightness =
        (_kasaBrightnessDraft ?? light.brightness.toDouble()).clamp(1, 100);
    // A strip and a bulb take on/off and brightness over different services.
    final strip = _isKasaLightStrip;
    final onCmd = strip ? 'strip_on' : 'light_on';
    final offCmd = strip ? 'strip_off' : 'light_off';
    final brightnessCmd = strip ? 'strip_brightness' : 'set_brightness';
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: text.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (busy)
                const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                Switch(
                  value: light.on,
                  onChanged: (on) =>
                      unawaited(_sendKasaLight(on ? onCmd : offCmd, const {})),
                ),
            ],
          ),
          Row(
            children: [
              Icon(Icons.brightness_6_outlined, color: scheme.onSurfaceVariant),
              Expanded(
                child: Slider(
                  value: brightness.toDouble(),
                  min: 1,
                  max: 100,
                  divisions: 99,
                  label: '${brightness.round()}%',
                  onChanged: busy
                      ? null
                      : (v) => setState(() => _kasaBrightnessDraft = v),
                  onChangeEnd: (v) {
                    setState(() => _kasaBrightnessDraft = null);
                    unawaited(_sendKasaLight(
                        brightnessCmd, {'brightness': v.round().toString()}));
                  },
                ),
              ),
              SizedBox(
                width: 44,
                child: Text('${brightness.round()}%',
                    textAlign: TextAlign.end, style: text.bodyMedium),
              ),
            ],
          ),
        ],
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
        return _numberCard(entity);
      case 'text':
        return _textCard(entity);
      case 'light':
        // A LIFX light drives itself over UDP: unlike the SOAP/HTTP cards it
        // owns its own sends and live reads, so the screen just hands it the
        // entity and the device address.
        return NetworkLightCard(
          entity: entity,
          specYaml: widget.controls.specYaml,
          host: widget.device.host,
          targetMac: widget.device.advertisedMac ?? '',
        );
      default:
        return _sensorCard(entity);
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
    final byName = {for (final entity in buttons) entity.name: entity};
    final placed = <String>{};
    NetworkEntityDto? take(String name) {
      final entity = byName[name];
      if (entity != null) placed.add(name);
      return entity;
    }

    List<NetworkEntityDto> takeAll(List<String> names) {
      final taken = <NetworkEntityDto>[];
      for (final name in names) {
        final entity = take(name);
        if (entity != null) taken.add(entity);
      }
      return taken;
    }

    final power = takeAll(const ['Power On', 'Power Off']);
    final nav = takeAll(const ['Back', 'Home']);
    final up = take('Up');
    final left = take('Left');
    final ok = take('OK');
    final right = take('Right');
    final down = take('Down');
    final underPad = takeAll(const ['Replay', 'Options']);
    final transport = takeAll(const ['Rewind', 'Play/Pause', 'Fast Forward']);
    final volume = takeAll(const ['Volume Up', 'Mute', 'Volume Down']);
    final channel = takeAll(const ['Channel Up', 'Channel Down']);
    final misc = takeAll(const ['Search', 'Find Remote']);
    final inputs = takeAll(
        const ['HDMI 1', 'HDMI 2', 'HDMI 3', 'HDMI 4', 'AV', 'Antenna']);
    final leftover = [
      for (final entity in buttons)
        if (!placed.contains(entity.name)) entity,
    ];

    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    Widget labeledRow(List<NetworkEntityDto> entities,
            {MainAxisAlignment alignment = MainAxisAlignment.center}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: alignment,
            children: [
              for (final entity in entities)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _remoteButton(entity),
                ),
            ],
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
          if (power.isNotEmpty)
            labeledRow(power, alignment: MainAxisAlignment.end),
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

    return _card(
      child: Row(
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
          else
            Switch(
              value: isOn ?? false,
              onChanged: (turnOn == null ||
                      turnOff == null ||
                      _lockedFor(turnOn) ||
                      _lockedFor(turnOff))
                  ? null
                  : (wantOn) =>
                      unawaited(_send(entity, wantOn ? turnOn : turnOff)),
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
        ],
      ),
    );
  }

  Widget _numberCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final action = _actionFor(entity, 'set_value');
    final busy = _sending.contains(entity.name);
    final unit = entity.unit;

    return _card(
      child: Row(
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
                  reading == null
                      ? 'Unknown'
                      : '${reading.raw}${unit == null ? '' : ' $unit'}',
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
          else if (action != null)
            IconButton(
              tooltip: 'Set ${entity.name}',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _lockedFor(action)
                  ? null
                  : () => unawaited(_editNumber(entity, action)),
            ),
        ],
      ),
    );
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
            suffixText: entity.unit,
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

  Widget _sensorCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final unit = entity.unit;
    final value = switch (reading?.kind) {
      null => 'Unknown',
      NetworkReadingKind.option => reading!.label ?? reading.raw,
      NetworkReadingKind.onOff => (reading!.isOn ?? false) ? 'On' : 'Off',
      _ => '${reading!.raw}${unit == null ? '' : ' $unit'}',
    };
    return _card(
      child: Row(
        children: [
          Expanded(
            child: Text(entity.name,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Text(value, style: Theme.of(context).textTheme.bodyLarge),
        ],
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
