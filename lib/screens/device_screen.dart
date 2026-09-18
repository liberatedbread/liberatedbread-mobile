// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../providers/adopt_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/device_description_provider.dart';
import '../providers/device_setup_help_provider.dart';
import '../providers/device_spec_match_provider.dart';
import '../providers/ha_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../providers/saved_device_provider.dart';
import '../providers/scan_match_provider.dart';
import '../services/ble_service.dart';
import '../services/spec_codec.dart' show BleHandshakeDto;
import '../widgets/ad_banner_bar.dart';
import '../widgets/device_control_panel.dart';
import '../widgets/safety_advisory_gate.dart';
import '../widgets/radar_scanner.dart';
import '../core/error_text.dart';
import '../core/log.dart';
import '../widgets/rabbit_air_setup_info_panel.dart';
import 'find_device_screen.dart';
import 'setup_instructions_screen.dart';

enum _ScreenState { connecting, discovering, ready, error, disconnected }

/// Execute a spec's connect-time handshake, step by step, and hand back the
/// notification subscriptions it opened.
///
/// A thin executor ON PURPOSE. Every decision — which steps exist, what order
/// they run in, which service each characteristic lives under, and which of
/// them can be carried out at all — was made in Rust from the spec's
/// `initialization` blocks; this loop holds none of it. What it does own is
/// the two things only a client can: the BLE calls, and the subscriptions'
/// lifetime, which is the connection's (the caller cancels them when the link
/// goes).
///
/// Within one step the order is subscribe, write, read, wait: a step that
/// opens notifications is opening them for what follows, and a step that both
/// writes and reads (SpotLED's `04 14 00 00`) is reading the answer to its
/// own write.
///
/// A step that fails STOPS the handshake — the steps are ordered because they
/// depend on each other, and running the rest against a device that refused
/// step two is how a half-initialized device comes to look initialized. The
/// throw carries no list back, so anything this opened before it is cancelled
/// here rather than left running with no owner.
@visibleForTesting
Future<List<StreamSubscription<List<int>>>> runBleHandshake({
  required BleService ble,
  required String deviceId,
  required BleHandshakeDto handshake,
}) async {
  // Prose, not instructions: schlage's session resumption is a fresh SPAKE2
  // exchange per connect and no spec can hold its bytes. Said out loud rather
  // than silently skipped, because "the handshake ran" and "the executable
  // part of the handshake ran" are different claims.
  for (final described in handshake.described) {
    Log.ble.warning(
      'the spec asks for a handshake step this app cannot perform on '
      '$deviceId: $described',
    );
  }
  final opened = <StreamSubscription<List<int>>>[];
  try {
    for (final step in handshake.steps) {
      final serviceUuid = step.serviceUuid;
      if (serviceUuid == null) {
        // No service declares the characteristic and the step named no owner,
        // so there is nothing to address the operation to. Skipped rather
        // than guessed: a write to the wrong service is not a handshake.
        Log.ble.warning(
          'skipping a handshake step on $deviceId: no service declares '
          '${step.characteristicUuid}',
        );
        continue;
      }
      if (step.subscribe) {
        opened.add(
          ble
              .subscribeCharacteristic(
                deviceId,
                serviceUuid,
                step.characteristicUuid,
              )
              .listen(
                // The payloads matter to the device, not to us: what the spec
                // asks for is that notifications be RUNNING. The service's own
                // ring keeps what arrives for whoever wants it later.
                (_) {},
                onError: (Object e) => Log.ble.debug(
                  'handshake notification on ${step.characteristicUuid}: $e',
                ),
              ),
        );
      }
      final write = step.write;
      if (write != null) {
        await ble.writeCharacteristic(
          deviceId,
          serviceUuid,
          step.characteristicUuid,
          write,
        );
      }
      if (step.read) {
        await ble.readCharacteristic(
          deviceId,
          serviceUuid,
          step.characteristicUuid,
        );
      }
      if (step.delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: step.delayMs));
      }
    }
  } catch (_) {
    for (final sub in opened) {
      unawaited(sub.cancel());
    }
    rethrow;
  }
  return opened;
}

class DeviceScreen extends ConsumerStatefulWidget {
  final IoTDevice device;

  const DeviceScreen({super.key, required this.device});

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
  /// How long the connect path waits for the spec match before opening the
  /// screen without having run the device's handshake. See
  /// [_runSpecHandshake].
  static const _specMatchWait = Duration(seconds: 3);

  /// Set by the first Disconnect tap; see onDisconnect.
  bool _leaving = false;

  _ScreenState _state = _ScreenState.connecting;
  // Set when "Try to find device" started the current connect attempt: the
  // find screen needs a live link for its RSSI ping, so from the failed and
  // disconnected states finding is connect-first. Cleared on failure — a
  // later manual Retry must not surprise-open the find screen.
  bool _openFindWhenReady = false;
  String? _error;
  List<BleDiscoveredService> _services = [];
  late final BleService _bleService;
  StreamSubscription<BleConnectionState>? _connSub;

  /// Notification streams the spec's connect-time handshake asked to be
  /// opened, held for the life of THIS connection. A handshake that says
  /// `subscribe` means "have notifications running before anything else
  /// happens" (SmartDawn opens both of its DDP channels first), so the
  /// subscriptions cannot be dropped the moment the handshake returns — and
  /// they have to go when the link does, or the next connect stacks another
  /// set on top.
  final List<StreamSubscription<List<int>>> _handshakeSubs = [];

  /// The bounded wait for the spec match, and the deadline that bounds it.
  ///
  /// Owned as fields rather than left inside a `Future.timeout` because both
  /// have to be let go when the screen is: a timer still pending after the
  /// tree is disposed is a leak (and a test failure), and a wait nothing
  /// completes would strand [_connect] mid-flight — with the link it
  /// established never torn down.
  Completer<SpecMatchOutcome>? _matchGate;
  Timer? _matchDeadline;
  // Watches the spec match for the connected device and records the outcome
  // (category + spec key) on the saved-device record, so grouping can
  // classify this device while it is out of range. A listener rather than a
  // one-shot read: the user answering the spec chooser resolves the same
  // family later, and that answer must be captured too.
  ProviderSubscription<AsyncValue<SpecMatchOutcome>>? _matchSub;

  /// The matched spec's category and identity, captured from [_matchSub] so the
  /// device-targeted ad banner (e.g. label-roll supplies for a BLE thermal
  /// label printer) can be shown here — those specs open THIS screen, which had
  /// no ad bar, so their promos never surfaced. Null until a spec matches.
  String? _adCategory;
  String? _adSpecKey;

  /// The in-flight saved-record write from [_connect]'s `touch()`. The spec
  /// match listener awaits it before `recordMatch`, because the two write the
  /// same record and recordMatch treats "not saved yet" as "never saved".
  /// Errors are already swallowed at the source, so awaiting cannot throw.
  Future<void>? _saveInFlight;
  // True once connect() has established a link we still own. Guards teardown so
  // exactly one disconnect() runs per established connection.
  bool _connected = false;

  /// Bumped by every [_connect]. Retry, Try-to-find and the reconnect the
  /// connection watcher fires all call it, and nothing stopped a second call
  /// from overlapping the first: the older attempt was left suspended inside
  /// `connect()` or `discoverServices()`, and when it finally resolved it
  /// carried on as though it owned the screen — worst of all in its catch,
  /// where `_cleanupConnection()` tore down the link the NEWER attempt had
  /// just established and then painted the error state over a working
  /// screen. An attempt that is no longer the current one now does nothing
  /// at all: it does not disconnect (the peripheral is the same one the
  /// live attempt is holding), it does not setState, it just stops.
  int _connectGeneration = 0;

  /// Whether a newer [_connect] has taken over from the attempt that started
  /// at [generation].
  bool _superseded(int generation) => generation != _connectGeneration;

  @override
  void initState() {
    super.initState();
    _bleService = ref.read(bleServiceProvider);
    _connect();
  }

  Future<void> _connect() async {
    final generation = ++_connectGeneration;
    // Drop any connection this screen still owns + cached services first, so a
    // retry or reconnect doesn't run against an already-connected peripheral
    // with a stale service cache.
    await _cleanupConnection();
    // Even the teardown is an await: a second tap during it supersedes us
    // before we have started.
    if (_superseded(generation) || !mounted) return;

    setState(() {
      _state = _ScreenState.connecting;
      _error = null;
    });

    try {
      await _bleService.connect(widget.device.id);
      // A newer attempt is driving now. It targets the same peripheral, so
      // the link this call established is the one it is about to use (or
      // already using): hand it over untouched rather than disconnecting it,
      // and let the newer attempt's own `_connected` own the teardown.
      if (_superseded(generation)) return;
      // We now own a live connection — record it BEFORE the mounted check so an
      // unmount-during-connect still tears it down instead of leaking it.
      _connected = true;

      // If the screen was disposed while connect() was in flight, dispose()
      // couldn't disconnect (the peripheral wasn't connected yet); clean up the
      // now-live connection here instead of leaving it ownerless.
      if (!mounted) {
        await _cleanupConnection();
        return;
      }
      // Give the HA forwarder a friendly name for this device's entities.
      ref
          .read(haForwarderProvider)
          .noteDeviceName(widget.device.id, widget.device.displayName);

      // Persist on a *successful* connect, not on discovery: History should
      // list devices the user actually paired with, not everything that ever
      // appeared in a scan. Fire-and-forget — a preferences write failure must
      // not take down a live connection.
      //
      // The try/catch is what makes that true. `catchError` only covers the
      // returned future, and the first `ref.read` here builds the notifier,
      // which reads the store synchronously — so an unreadable store throws
      // *before* there is a future to attach to, straight out into the connect
      // path's own catch, and the user sees a connection that worked reported
      // as one that failed.
      try {
        // Kept, not just fired: the spec-match listener awaits this before
        // recordMatch, so the two writes can't race (see [_saveInFlight]).
        _saveInFlight = ref
            .read(savedDevicesProvider.notifier)
            .touch(
              id: widget.device.id,
              name: widget.device.displayName,
              seenAt: DateTime.now(),
            )
            .catchError((Object _) {});
      } catch (e) {
        Log.ble.warning(
          'could not record ${widget.device.id} in saved devices',
          error: e,
        );
      }
      _watchConnection();
      setState(() => _state = _ScreenState.discovering);

      final services = await _bleService.discoverServices(widget.device.id);

      if (_superseded(generation)) return;
      // Same hazard as above: discovery can return after unmount.
      if (!mounted) {
        await _cleanupConnection();
        return;
      }
      // The spec's own handshake, BEFORE the controls exist — six vendored
      // specs declare one ("ordered handshake / setup steps executed after
      // connecting and before normal commands", in the schema's words) and
      // until this nothing ran them, so a SpotLED panel's first tap went out
      // without the three writes the device is waiting for. Never fatal: a
      // handshake that fails is a device that may ignore its commands, and a
      // screen that refuses to open is a device that certainly does.
      await _runSpecHandshake(services);
      if (_superseded(generation)) return;
      if (!mounted) {
        await _cleanupConnection();
        return;
      }
      setState(() {
        _services = services;
        _state = _ScreenState.ready;
      });
      _watchSpecMatch(services);
      if (_openFindWhenReady) {
        _openFindWhenReady = false;
        _openFind();
      }
    } catch (e) {
      // A stale attempt's failure is not the screen's failure. Returning
      // here is the whole point of the generation: `_cleanupConnection()`
      // below would disconnect the peripheral the newer attempt is using,
      // and the setState after it would replace a connected screen with
      // "Could not connect to this device."
      if (_superseded(generation)) return;
      // Drop any half-open link + cached services so the error path / Retry
      // starts from a clean slate (no-op if we never connected).
      await _cleanupConnection();
      _openFindWhenReady = false;
      if (mounted) {
        setState(() {
          _error = friendlyErrorText(
            e,
            context: 'connect/discover ${widget.device.id}',
            fallback:
                'Could not connect to this device. Move closer, check '
                'it is powered on, then try again.',
          );
          _state = _ScreenState.error;
        });
      }
    }
  }

  /// Push the hot/cold locator for the (connected) device. One method for
  /// both entrances — the connected header's button and the try-to-find path
  /// out of the failed/disconnected states — so they cannot drift.
  void _openFind() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => FindDeviceScreen(
          deviceId: widget.device.id,
          deviceName: widget.device.displayName,
          services: _services,
        ),
      ),
    );
  }

  /// Connect, then open the find screen — the find affordance for the states
  /// with no link to measure. "Try", honestly: if the device is genuinely out
  /// of range the connect fails and the error state says so, which is itself
  /// the answer to "is it near me".
  Future<void> _tryToFind() {
    _openFindWhenReady = true;
    return _connect();
  }

  /// Open the matched spec's pairing/troubleshooting instructions. Read-only
  /// prose, so it is safe from an error state with no live link — for many
  /// devices its rejoin note ("a phone is still holding the one connection") is
  /// the actual answer to why the connect just failed.
  void _openSetupHelp(DeviceSetupHelp help) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SetupInstructionsScreen(
          deviceName: help.deviceName,
          instructions: help.instructions,
        ),
      ),
    );
  }

  /// Tear down the connection this screen owns: cancel the connection-state
  /// subscription and, if we established a link, disconnect it. Idempotent via
  /// the [_connected] guard so the unmount-cleanup and dispose() paths can't
  /// double-disconnect. Shared by the unmounted, discovery-failure, retry, and
  /// dispose paths so they all tear down identically.
  Future<void> _cleanupConnection() async {
    // Cancel is fire-and-forget: it synchronously stops delivery, and awaiting
    // subscription teardown can stall inside the widget-test fake zone.
    unawaited(_connSub?.cancel());
    _connSub = null;
    _matchSub?.close();
    _matchSub = null;
    _releaseMatchWait();
    for (final sub in _handshakeSubs) {
      unawaited(sub.cancel());
    }
    _handshakeSubs.clear();
    if (_connected) {
      _connected = false;
      await _bleService.disconnect(widget.device.id).catchError((Object _) {});
    }
  }

  /// Stop waiting for the spec match: cancel the deadline and let whoever is
  /// awaiting it through with no spec.
  ///
  /// Both halves matter. The timer must not outlive the tree; and the wait
  /// must be COMPLETED rather than abandoned, because [_connect] suspends on
  /// it while owning a live connection it tears down on the way out.
  void _releaseMatchWait() {
    _matchDeadline?.cancel();
    _matchDeadline = null;
    final gate = _matchGate;
    _matchGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete(const SpecMatchOutcome.none());
    }
  }

  /// Run the matched spec's `initialization` handshake against this
  /// connection, if it declares one.
  ///
  /// The decision of what to send is entirely the catalogue's, resolved in
  /// Rust: which steps, in which order, against which service. This waits for
  /// the match because the handshake is the SPEC's, and the match is where
  /// the spec comes from — the same cached family entry the control panel
  /// reads, so it costs no extra FFI.
  Future<void> _runSpecHandshake(List<BleDiscoveredService> services) async {
    if (services.isEmpty) return;
    try {
      // Bounded, and both bounds answer the same way — no spec, no handshake,
      // open the screen. The match is what the control panel is waiting on
      // too, so waiting for it costs the user nothing they were not already
      // waiting for; but a catalogue that never resolves (an asset read that
      // hangs) must not hold a connected device behind a spinner, and a
      // handshake skipped is exactly where this device was yesterday.
      final gate = _matchGate = Completer<SpecMatchOutcome>();
      void settle([SpecMatchOutcome outcome = const SpecMatchOutcome.none()]) {
        if (!gate.isCompleted) gate.complete(outcome);
      }

      _matchDeadline = Timer(_specMatchWait, settle);
      unawaited(
        ref
            .read(
              matchedDeviceSpecProvider(
                SpecMatchRequest.forServices(
                  deviceId: widget.device.id,
                  deviceName: widget.device.displayName,
                  services: services,
                ),
              ).future,
            )
            .then(settle, onError: (Object _) => settle()),
      );
      final outcome = await gate.future;
      _releaseMatchWait();
      final chosen = outcome.chosen;
      if (chosen == null) return;
      final handshake = await ref
          .read(specCodecProvider)
          .specBleHandshake(specYaml: chosen.yaml);
      if (handshake.steps.isEmpty && handshake.described.isEmpty) return;
      if (!mounted || !_connected) return;
      _handshakeSubs.addAll(
        await runBleHandshake(
          ble: _bleService,
          deviceId: widget.device.id,
          handshake: handshake,
        ),
      );
    } catch (e) {
      // Logged, not surfaced: the user's question is "do my controls work",
      // and the answer to a half-run handshake is found by trying one.
      Log.ble.warning(
        'the spec handshake for ${widget.device.id} did not complete',
        error: e,
      );
    }
  }

  /// Record what spec this device matched on its saved record.
  ///
  /// The request is built exactly the way [DeviceControlPanel] builds its own
  /// (same normalization, same sort), so both hit one cached family entry and
  /// this adds no FFI work. `fireImmediately` catches a match that already
  /// resolved; later firings catch the user answering the spec chooser.
  void _watchSpecMatch(List<BleDiscoveredService> services) {
    _matchSub?.close();
    if (services.isEmpty) return;
    _matchSub = ref.listenManual(
      matchedDeviceSpecProvider(
        SpecMatchRequest.forServices(
          deviceId: widget.device.id,
          deviceName: widget.device.displayName,
          services: services,
        ),
      ),
      fireImmediately: true,
      (previous, next) async {
        final chosen = next.valueOrNull?.chosen;
        if (chosen == null) return;
        if (mounted) {
          setState(() {
            _adCategory = chosen.spec.category;
            _adSpecKey = specKeyFor(chosen.spec);
          });
        }
        // Let _connect()'s touch() land first. recordMatch treats an absent
        // record as "never saved" and skips silently — without this order a
        // match resolving faster than the first preferences write would drop
        // the category until the next connect.
        await _saveInFlight;
        if (!mounted) return;
        // Same shape as the touch() call in _connect(), for the same reason:
        // the first notifier read builds it, which reads the store
        // synchronously — a throw there must not become an unhandled error.
        try {
          unawaited(
            ref
                .read(savedDevicesProvider.notifier)
                .recordMatch(
                  id: widget.device.id,
                  category: chosen.spec.category,
                  specKey: specKeyFor(chosen.spec),
                )
                .catchError((Object _) {}),
          );
        } catch (e) {
          Log.ble.warning(
            'could not record the spec match for ${widget.device.id}',
            error: e,
          );
        }
      },
    );
  }

  /// Observe the live connection state so an unexpected disconnect flips the
  /// screen to a disconnected state (controls hidden, reconnect offered)
  /// instead of leaving stale controls that fail one-by-one.
  void _watchConnection() {
    _connSub?.cancel();
    _connSub = _bleService.connectionState(widget.device.id).listen((state) {
      if (!mounted) return;
      final lostConnection =
          state == BleConnectionState.disconnected ||
          state == BleConnectionState.disconnecting;
      if (lostConnection &&
          (_state == _ScreenState.ready ||
              _state == _ScreenState.discovering)) {
        setState(() => _state = _ScreenState.disconnected);
      }
    });
  }

  @override
  void dispose() {
    // Fire-and-forget teardown (dispose() can't await). Only disconnect a link
    // we actually own: if connect() is still in flight, _connected is false and
    // _connect()'s own !mounted branch will disconnect once it resolves, so we
    // neither leak the pending connection nor double-disconnect here.
    unawaited(_connSub?.cancel());
    _connSub = null;
    _matchSub?.close();
    _matchSub = null;
    _releaseMatchWait();
    for (final sub in _handshakeSubs) {
      unawaited(sub.cancel());
    }
    _handshakeSubs.clear();
    if (_connected) {
      _connected = false;
      // unawaited() does not swallow errors, so attach a catchError to keep a
      // throw during teardown from surfacing as an unhandled async error.
      unawaited(
        _bleService.disconnect(widget.device.id).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasBanner = _adCategory != null || _adSpecKey != null;
    return Scaffold(
      // The device-targeted promo (label-roll supplies for a BLE label printer,
      // a filter kit for a Rabbit Air, …), shown only ONCE a spec has matched —
      // the connecting/failed/unmatched states get no bar, so no shop banner
      // clutters an error screen (and its ~48 px does not squeeze those layouts).
      bottomNavigationBar: hasBanner
          ? DeviceAdBannerBar(category: _adCategory, specKey: _adSpecKey)
          : null,
      appBar: AppBar(
        // The default 56pt toolbar clips a two-line title, which silently hid
        // the status row.
        toolbarHeight: 72,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.device.displayName),
            // A live status line under the name: connection state was
            // previously only inferable from whichever body state happened to
            // be on screen.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).appBarTheme.foregroundColor,
                  ),
                ),
                Text(
                  _statusLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).appBarTheme.foregroundColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      // Landscape is declared for iPhone, so without this the body's 16-24 pt
      // padding sits under the notch / Dynamic Island on one side and the home
      // indicator below, while the app bar above it is inset correctly. When
      // the ad bar is present it owns the bottom inset itself.
      body: SafeArea(bottom: !hasBanner, child: _buildBody()),
    );
  }

  String get _statusLabel => switch (_state) {
    _ScreenState.connecting => 'Connecting',
    _ScreenState.discovering => 'Discovering services',
    _ScreenState.ready => 'Connected',
    _ScreenState.error => 'Connection failed',
    _ScreenState.disconnected => 'Disconnected',
  };

  Widget _buildBody() {
    switch (_state) {
      // Pairing is two distinct steps and can take several seconds on real
      // hardware, so it gets a step list rather than an unlabelled spinner:
      // when it stalls, the user can see *which* step stalled.
      case _ScreenState.connecting:
        return const _PairingProgress(
          label: 'Connecting...',
          step: 0,
          deviceName: null,
        );

      case _ScreenState.discovering:
        return const _PairingProgress(
          label: 'Discovering services...',
          step: 1,
          deviceName: null,
        );

      // Both dead-end states carry the find affordance too: a failed or lost
      // connection usually MEANS out of range or powered off, which makes
      // "where is it?" the natural next question, not a follow-up one.
      case _ScreenState.error:
        final help = ref
            .watch(deviceSetupHelpProvider(ScanIdentity.of(widget.device)))
            .valueOrNull;
        return _StatusState(
          icon: Icons.error_outline,
          severity: _Severity.error,
          title: 'Connection failed',
          message: _error ?? 'Connection failed',
          actionLabel: 'Retry',
          onAction: _connect,
          secondaryActionLabel: 'Try to find device',
          secondaryActionIcon: Icons.radar,
          onSecondaryAction: _tryToFind,
          tertiaryActionLabel: help == null ? null : 'How to connect',
          tertiaryActionIcon: Icons.menu_book_outlined,
          onTertiaryAction: help == null ? null : () => _openSetupHelp(help),
        );

      case _ScreenState.disconnected:
        final help = ref
            .watch(deviceSetupHelpProvider(ScanIdentity.of(widget.device)))
            .valueOrNull;
        return _StatusState(
          icon: Icons.bluetooth_disabled,
          severity: _Severity.warning,
          title: 'Device disconnected',
          message:
              'The connection was lost. Move closer or check the device '
              'is powered on, then reconnect.',
          actionLabel: 'Reconnect',
          onAction: _connect,
          secondaryActionLabel: 'Try to find device',
          secondaryActionIcon: Icons.radar,
          onSecondaryAction: _tryToFind,
          tertiaryActionLabel: help == null ? null : 'How to connect',
          tertiaryActionIcon: Icons.menu_book_outlined,
          onTertiaryAction: help == null ? null : () => _openSetupHelp(help),
        );

      case _ScreenState.ready:
        // The one place the advertised-name decision lives — and it is the
        // catalogue's decision, not this screen's: a peripheral whose name
        // matches some spec's `ble_provisioning` advertised name (under that
        // spec's own exact/prefix rule) is a unit waiting to be set up, and
        // gets the read-only setup-info view — which carries the "Set up
        // Wi-Fi" way into the onboarding flow. Anything else gets the
        // spec-matched control panel (which itself forks to the keyed Rabbit
        // Air BLE controls for a provisioned purifier). Unresolved reads as
        // "not in setup mode", so the ordinary panel renders immediately
        // rather than the screen waiting on the catalogue.
        final isRabbitAirSetup =
            ref
                .watch(bleSetupModeMatchProvider(widget.device.name))
                .valueOrNull !=
            null;
        // The matched spec's physical-safety advisory, if it declares one (an
        // IPL handset). Read from the same cached match the control panel uses,
        // so it costs no extra FFI. Unlike a security advisory it does not
        // suppress the controls — [SafetyAdvisoryGate] shows a banner over them
        // and, when the spec asks, gates them behind a one-time acknowledgement.
        final safety = ref
            .watch(
              matchedDeviceSpecProvider(
                SpecMatchRequest.forServices(
                  deviceId: widget.device.id,
                  deviceName: widget.device.displayName,
                  services: _services,
                ),
              ),
            )
            .valueOrNull
            ?.chosen
            ?.spec
            .safetyAdvisory;
        final panel = DeviceControlPanel(
          deviceId: widget.device.id,
          deviceName: widget.device.displayName,
          services: _services,
          manufacturerData: widget.device.manufacturerData,
        );
        return Column(
          children: [
            _ConnectedHeader(
              name: widget.device.displayName,
              device: widget.device,
              // The registry is indexed once for the app's lifetime and this
              // returns DeviceDescription.none until it is, so the header
              // renders immediately and gains its identity rows a frame later
              // rather than holding the whole screen on an asset load.
              description: describeWith(
                ref.watch(numberRegistryProvider),
                widget.device,
              ),
              serviceCount: _services.length,
              onFind: _openFind,
              onDisconnect: () async {
                // A deliberate disconnect means "done with this device", so
                // return to the listing it was opened from. The reconnect
                // state stays reserved for links *lost* (_watchConnection):
                // parking a chosen disconnect there read as an error. The
                // navigator is captured before the await so no BuildContext
                // crosses the async gap, and the mounted guard keeps a
                // pop-during-teardown from popping the listing itself.
                // Once. A second tap while the first is still tearing down
                // popped again after the screen had gone — the HomeShell
                // underneath, leaving an empty Navigator.
                if (_leaving) return;
                _leaving = true;
                final navigator = Navigator.of(context);
                await _cleanupConnection();
                if (!mounted || !navigator.canPop()) return;
                navigator.pop();
              },
            ),
            Expanded(
              child: isRabbitAirSetup
                  ? RabbitAirSetupInfoPanel(
                      device: widget.device,
                      services: _services,
                    )
                  : safety == null
                  ? panel
                  : SafetyAdvisoryGate(
                      advisory: safety,
                      ackKey: widget.device.id,
                      child: panel,
                    ),
            ),
          ],
        );
    }
  }
}

/// Live summary above the controls: what's connected, how much was discovered,
/// and the connection-level actions (find the physical device, disconnect).
///
/// Previously the only cue that a device was connected was the presence of
/// controls; disconnecting meant backing out of the screen. The actions get
/// their own row rather than sharing the identity row: two labeled buttons
/// beside the name left it a few dozen pixels on narrow phones.
class _ConnectedHeader extends StatelessWidget {
  final String name;
  final IoTDevice device;
  final DeviceDescription description;
  final int serviceCount;
  final VoidCallback onFind;
  final Future<void> Function() onDisconnect;

  const _ConnectedHeader({
    required this.name,
    required this.device,
    required this.description,
    required this.serviceCount,
    required this.onFind,
    required this.onDisconnect,
  });

  /// Identity rows, in descending order of how much each is worth.
  ///
  /// Deliberately NOT collapsed into one "manufacturer" line. The two sources
  /// answer different questions and only one of them is about the product: a
  /// company ID is something this device put in its own advertisement, while
  /// an address block names whoever bought the block — frequently the radio
  /// module's vendor rather than the product's, which is why the Caséta
  /// bridge's address resolves to Texas Instruments. Labelling them apart is
  /// the whole reason the registry is safe to show at all.
  ///
  /// Empty when nothing resolved, which is the normal case on Apple platforms:
  /// CoreBluetooth substitutes a per-host UUID for the address, so there is no
  /// block to look up and `macAddress` is null.
  List<({String label, String value})> get _identity => [
    if (device.macAddress != null)
      (label: 'Address', value: device.macAddress!),
    for (final company in description.companies.take(1))
      (label: 'Advertises as', value: company),
    if (description.addressVendor != null)
      (label: 'Address block', value: description.addressVendor!),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.memory, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.secondary,
                          ),
                        ),
                        Text(
                          'Connected  ·  $serviceCount service'
                          '${serviceCount == 1 ? '' : 's'}',
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    for (final row in _identity) ...[
                      const SizedBox(height: 3),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 92,
                            child: Text(
                              row.label,
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: 0.75,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            // Selectable: an address is a thing people copy into a
                            // bug report or another tool, and the whole point of
                            // showing it is that it can be acted on.
                            child: SelectableText(
                              row.value,
                              style: text.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              maxLines: 2,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onFind,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  icon: const Icon(Icons.radar, size: 18),
                  label: const Text('Find device'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: onDisconnect,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  child: const Text('Disconnect'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Two-step pairing progress: connect, then discover services.
class _PairingProgress extends StatelessWidget {
  final String label;
  final int step;
  final String? deviceName;

  const _PairingProgress({
    required this.label,
    required this.step,
    required this.deviceName,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    const steps = ['Connecting', 'Discovering services'];

    // Scrollable, not a bare Column: in landscape the body is ~320 pt tall
    // and this stack needs more, which pushed the actions off-screen; at a
    // large text size the same happens in portrait. Center keeps it centred
    // whenever it does fit.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const RadarScanner(scanning: true, size: 168),
            const SizedBox(height: 32),
            Text(
              label,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Keep the device powered on and nearby.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Done steps get a check, the active step a filled dot, and
                    // pending steps a hollow ring — readable without colour.
                    if (i < step)
                      Icon(
                        Icons.check_circle,
                        size: 18,
                        color: scheme.secondary,
                      )
                    else if (i == step)
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: scheme.secondary,
                        ),
                      )
                    else
                      Icon(
                        Icons.circle_outlined,
                        size: 18,
                        color: scheme.outlineVariant,
                      ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        steps[i],
                        style: text.bodyMedium?.copyWith(
                          color: i <= step
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                          fontWeight: i == step
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Severity { error, warning }

/// Full-screen connection status with a recovery action.
///
/// Mirrors the scan screen's empty-state layout so connect failures, drops and
/// empty scans all read as the same kind of moment instead of three different
/// one-off layouts. Severity picks the semantic colour role, so the states stay
/// legible in dark mode where the previous hardcoded red/orange/grey did not.
class _StatusState extends StatelessWidget {
  final IconData icon;
  final _Severity severity;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  /// Optional second, visually quieter action under the primary one — how the
  /// dead-end states offer "Try to find device" without competing with their
  /// Retry/Reconnect.
  final String? secondaryActionLabel;
  final IconData? secondaryActionIcon;
  final VoidCallback? onSecondaryAction;

  /// Optional third, quietest action — a text button under the outlined one.
  /// The dead-end states offer "How to connect" here (the matched spec's setup
  /// instructions) without competing with Retry or Find.
  final String? tertiaryActionLabel;
  final IconData? tertiaryActionIcon;
  final VoidCallback? onTertiaryAction;

  const _StatusState({
    required this.icon,
    required this.severity,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.secondaryActionLabel,
    this.secondaryActionIcon,
    this.onSecondaryAction,
    this.tertiaryActionLabel,
    this.tertiaryActionIcon,
    this.onTertiaryAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isError = severity == _Severity.error;
    final disc = isError ? scheme.errorContainer : scheme.tertiaryContainer;
    final accent = isError
        ? scheme.onErrorContainer
        : scheme.onTertiaryContainer;

    // Scrollable, not a bare Column: in landscape the body is ~320 pt tall
    // and this stack needs more, which pushed the actions off-screen; at a
    // large text size the same happens in portrait. Center keeps it centred
    // whenever it does fit.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: disc, shape: BoxShape.circle),
              child: Icon(icon, size: 44, color: accent),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh),
              label: Text(actionLabel),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
            ),
            if (secondaryActionLabel != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onSecondaryAction,
                icon: Icon(secondaryActionIcon ?? Icons.radar, size: 18),
                label: Text(secondaryActionLabel!),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
              ),
            ],
            if (tertiaryActionLabel != null) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: onTertiaryAction,
                icon: Icon(
                  tertiaryActionIcon ?? Icons.menu_book_outlined,
                  size: 18,
                ),
                label: Text(tertiaryActionLabel!),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
