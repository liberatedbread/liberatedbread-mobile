// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/device_description_provider.dart';
import '../providers/device_spec_match_provider.dart';
import '../providers/ha_provider.dart';
import '../providers/saved_device_provider.dart';
import '../services/ble_service.dart';
import '../widgets/device_control_panel.dart';
import '../widgets/radar_scanner.dart';
import '../core/error_text.dart';
import '../core/log.dart';
import 'find_device_screen.dart';

enum _ScreenState { connecting, discovering, ready, error, disconnected }

class DeviceScreen extends ConsumerStatefulWidget {
  final IoTDevice device;

  const DeviceScreen({super.key, required this.device});

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
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
  // Watches the spec match for the connected device and records the outcome
  // (category + spec key) on the saved-device record, so grouping can
  // classify this device while it is out of range. A listener rather than a
  // one-shot read: the user answering the spec chooser resolves the same
  // family later, and that answer must be captured too.
  ProviderSubscription<AsyncValue<SpecMatchOutcome>>? _matchSub;

  /// The in-flight saved-record write from [_connect]'s `touch()`. The spec
  /// match listener awaits it before `recordMatch`, because the two write the
  /// same record and recordMatch treats "not saved yet" as "never saved".
  /// Errors are already swallowed at the source, so awaiting cannot throw.
  Future<void>? _saveInFlight;
  // True once connect() has established a link we still own. Guards teardown so
  // exactly one disconnect() runs per established connection.
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _bleService = ref.read(bleServiceProvider);
    _connect();
  }

  Future<void> _connect() async {
    // Drop any connection this screen still owns + cached services first, so a
    // retry or reconnect doesn't run against an already-connected peripheral
    // with a stale service cache.
    await _cleanupConnection();

    setState(() {
      _state = _ScreenState.connecting;
      _error = null;
    });

    try {
      await _bleService.connect(widget.device.id);
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

      // Same hazard as above: discovery can return after unmount.
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
      // Drop any half-open link + cached services so the error path / Retry
      // starts from a clean slate (no-op if we never connected).
      await _cleanupConnection();
      _openFindWhenReady = false;
      if (mounted) {
        setState(() {
          _error = friendlyErrorText(
            e,
            context: 'connect/discover ${widget.device.id}',
            fallback: 'Could not connect to this device. Move closer, check '
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
      MaterialPageRoute(
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
    if (_connected) {
      _connected = false;
      await _bleService.disconnect(widget.device.id).catchError((Object _) {});
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
      matchedDeviceSpecProvider(SpecMatchRequest.forServices(
        deviceId: widget.device.id,
        deviceName: widget.device.displayName,
        services: services,
      )),
      fireImmediately: true,
      (previous, next) async {
        final chosen = next.valueOrNull?.chosen;
        if (chosen == null) return;
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
      final lostConnection = state == BleConnectionState.disconnected ||
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
    return Scaffold(
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
      body: _buildBody(),
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
        );

      case _ScreenState.disconnected:
        return _StatusState(
          icon: Icons.bluetooth_disabled,
          severity: _Severity.warning,
          title: 'Device disconnected',
          message: 'The connection was lost. Move closer or check the device '
              'is powered on, then reconnect.',
          actionLabel: 'Reconnect',
          onAction: _connect,
          secondaryActionLabel: 'Try to find device',
          secondaryActionIcon: Icons.radar,
          onSecondaryAction: _tryToFind,
        );

      case _ScreenState.ready:
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
                  ref.watch(numberRegistryProvider), widget.device),
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
                final navigator = Navigator.of(context);
                await _cleanupConnection();
                if (!mounted) return;
                navigator.pop();
              },
            ),
            Expanded(
              child: DeviceControlPanel(
                deviceId: widget.device.id,
                deviceName: widget.device.displayName,
                services: _services,
                manufacturerData: widget.device.manufacturerData,
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
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
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
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
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
                              style: text.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
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
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
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

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
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
                      Icon(Icons.check_circle,
                          size: 18, color: scheme.secondary)
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
                      Icon(Icons.circle_outlined,
                          size: 18, color: scheme.outlineVariant),
                    const SizedBox(width: 10),
                    Text(
                      steps[i],
                      style: text.bodyMedium?.copyWith(
                        color: i <= step
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight:
                            i == step ? FontWeight.w600 : FontWeight.w400,
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
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isError = severity == _Severity.error;
    final disc = isError ? scheme.errorContainer : scheme.tertiaryContainer;
    final accent =
        isError ? scheme.onErrorContainer : scheme.onTertiaryContainer;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
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
          ],
        ),
      ),
    );
  }
}
