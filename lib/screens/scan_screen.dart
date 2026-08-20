// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/constants.dart';
import '../core/device_category.dart';
import '../core/error_text.dart';
import '../core/find_device.dart' show signalBars;
import '../core/value_format.dart' show shortAge;
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/device_description_provider.dart';
import '../providers/scan_match_provider.dart';
import '../services/ble_service.dart';
import '../services/device_manager.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/black_hat_icon.dart';
import '../widgets/device_list_tile.dart';
import '../widgets/radar_scanner.dart';
import 'device_screen.dart';
import 'ha_settings_screen.dart';
import 'security_warning_screen.dart';
import 'spec_pack_settings_screen.dart';

class ScanScreen extends ConsumerStatefulWidget {
  /// Whether this screen is the one on screen.
  ///
  /// [HomeShell] keeps all three tabs alive in an IndexedStack so a scan in
  /// progress survives a glance at another tab — which, now that the scan runs
  /// continuously, would mean driving the BLE radio for a list nobody is
  /// looking at. The shell passes false while another tab is selected and the
  /// scan pauses; it resumes on return, with whatever it found still listed
  /// (and aged accordingly).
  ///
  /// Defaults to true so mounting a ScanScreen on its own — a test, a deep
  /// link, anything that is not the shell — scans, rather than sitting inert
  /// waiting for a flag nobody set.
  final bool active;

  const ScanScreen({super.key, this.active = true});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

/// How often the screen re-examines how long ago each device was last heard.
///
/// Only a clock tick: nothing arrives on this interval, it exists so a row
/// crossing the stale threshold updates without waiting for the next
/// advertisement — which, for a device that has just been switched off, is
/// never.
const Duration _ageTick = Duration(seconds: 5);

/// How long a Scan press keeps the radio in its low-latency mode before the
/// scan downshifts to the ambient duty cycle.
///
/// The press buys a burst, not a mode: someone who taps Scan is hunting for a
/// device right now, and thirty seconds of continuous listening — the app's
/// original scan window — is enough to find anything that is going to be
/// found quickly. Left permanent, one tap would re-pin the radio for the rest
/// of the session, and the tab's whole energy story would hinge on nobody
/// ever pressing its most prominent button. The downshift is a seamless
/// restart: the device list survives scan restarts by design.
const Duration _activeBurst =
    Duration(seconds: AppConstants.defaultScanDuration);

/// How long a switch away from this tab must last before the radio is
/// actually stopped.
///
/// Stopping instantly would be correct in isolation and wrong in aggregate,
/// for two reasons. Every return to the tab is a native scan START, and
/// Android blocks an app that starts more than five scans in thirty seconds
/// (SCAN_FAILED_SCANNING_TOO_FREQUENTLY) — a block that reads as "scanning,
/// finding nothing" for its whole cooldown. And cycling the radio costs more
/// than it saves when the gap is a glance: the scan controller setup/teardown
/// is work too. Two seconds is longer than checking a name on the Saved tab
/// and shorter than actually reading anything there.
const Duration _offTabStopDelay = Duration(seconds: 2);

/// Longest the list waits before repainting for changed values.
///
/// A continuous scan asks the platform for every advertisement, so a busy room
/// can deliver dozens of rssi updates a second — each one worth a pixel or two
/// of signal meter and not worth a rebuild. New devices are exempt: those
/// repaint immediately, because appearing half a second late is the one thing
/// a scan screen must not do.
const Duration _repaintInterval = Duration(milliseconds: 400);

/// Whether a clock tick has anything to draw.
///
/// [dropped] is true when the tick evicted a device, [stale] the ids currently
/// past the warning threshold, [previouslyStale] the same set as of the last
/// repaint.
///
/// The non-obvious clause is `stale.isNotEmpty`. A stale row's subtitle counts
/// ("Not seen for 45s"), and nothing else is coming to repaint it — a device
/// that stopped advertising is, by definition, not going to advertise — so
/// while any row is stale the tick itself IS the change. Comparing the sets
/// alone would leave that number frozen at whatever it read when the row
/// crossed the threshold, quietly turning a live readout into a lie. With no
/// stale rows nothing on screen ages, so a tick that changed no classification
/// draws nothing.
///
/// Extracted as a pure top-level function because the widget test around it
/// cannot see the difference: a scan screen repaints for several other reasons
/// during a pump, so a frozen counter still looks correct from outside.
bool ageTickNeedsRepaint({
  required bool dropped,
  required Set<String> stale,
  required Set<String> previouslyStale,
}) =>
    dropped || stale.isNotEmpty || !setEquals(stale, previouslyStale);

class _ScanScreenState extends ConsumerState<ScanScreen>
    with WidgetsBindingObserver {
  final DeviceManager _deviceManager = DeviceManager();
  bool _isScanning = false;
  // True once at least one scan has run (successfully or with an error).
  // Distinguishes the "never scanned" prompt from the "scanned, found nothing"
  // dead-end.
  bool _hasScanned = false;
  // Set when the user stopped the scan from the FAB. Kept apart from
  // _isScanning because it is what decides whether returning from a device
  // screen — or from the background — resumes scanning: an app that quietly
  // restarted the radio someone had just turned off would be worse than one
  // that never scanned by itself at all.
  bool _pausedByUser = false;
  String? _error;
  // Set when scanning failed because BLE permissions were denied; drives a
  // permission-specific state with an open-settings recovery path.
  bool _permissionDenied = false;
  late final BleService _bleService;
  // Owned scan subscription so a device tap (or dispose) can cancel the active
  // scan instead of leaving it running behind the pushed route.
  StreamSubscription<IoTDevice>? _scanSub;
  // Clock tick for ageing devices, and the pending coalesced repaint. Both are
  // cancelled in dispose.
  Timer? _ageTicker;
  Timer? _repaint;
  // Which rows were stale as of the last repaint, so a tick can tell a change
  // worth drawing from one where nothing moved.
  Set<String> _staleIds = const {};
  // True while a device screen is pushed over this one. The scan is stopped for
  // the duration (a connect on a scanning adapter is flaky), so every automatic
  // resume has to know not to undo that.
  bool _onDeviceScreen = false;
  // Ends the low-latency burst an explicit Scan press buys — see
  // [_activeBurst]. Armed only for active-intensity scans.
  Timer? _burstDownshift;
  // Pending off-tab stop (see [_offTabStopDelay]); armed when the shell
  // switches away, disarmed if it switches back inside the grace window.
  Timer? _offTabStop;
  // Watches the radio so "Bluetooth is turned off" is a state the screen can
  // leave by itself — see the listener in initState.
  StreamSubscription<bool>? _adapterSub;

  @override
  void initState() {
    super.initState();
    _bleService = ref.read(bleServiceProvider);
    WidgetsBinding.instance.addObserver(this);
    // Scan on arrival, and keep scanning. Discovery is not a thing the user
    // should have to ask for: BLE devices appear when they are powered on,
    // walked into the room, or woken from sleep, and a screen that only looks
    // when a button is pressed shows a snapshot of the moment someone last
    // pressed it. The FAB stays, as a way to stop.
    //
    // The ticker runs whether or not the scan does: devices keep ageing while
    // the tab is away or the scan is stopped, and coming back to a list of
    // rows still claiming a live signal would be a lie the clock had already
    // disproved.
    _ageTicker = Timer.periodic(_ageTick, (_) => _ageDevices());
    // Radio coming back is a resume signal the lifecycle observer never
    // hears: on Android, Bluetooth is toggled from quick settings without the
    // app losing focus. Whoever turned it back on did it so Bluetooth things
    // would work again — leaving "Bluetooth is turned off" on screen after
    // that, with a Retry button for a problem already fixed, is the screen
    // being the last to know. _resumeIfIdle carries all the reasons NOT to
    // (mid-scan, user-stopped, off-tab, device screen open), so a ready
    // signal in any of those states changes nothing.
    _adapterSub = _bleService.adapterReady().listen(
      (ready) {
        if (ready && mounted) _resumeIfIdle();
      },
      // A host with no BLE stack at all (the desktop test runner) errors this
      // stream the same way it errors scan() — and scan()'s own error path is
      // already the messenger for that. A watcher that exists to improve an
      // error state must not be able to crash the screen showing it.
      onError: (Object _) {},
    );
    if (widget.active) unawaited(_startScan(ScanIntensity.ambient));
  }

  /// React to the shell switching tabs (see [ScanScreen.active]).
  ///
  /// The stop is deferred by [_offTabStopDelay] rather than immediate, so a
  /// glance at another tab and back never cycles the radio — see the constant
  /// for why that matters beyond politeness. A return inside the grace window
  /// just disarms the pending stop: the scan never stopped, so there is
  /// nothing to resume.
  @override
  void didUpdateWidget(ScanScreen old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    if (widget.active) {
      _offTabStop?.cancel();
      _offTabStop = null;
      _resumeIfIdle();
    } else if (_isScanning) {
      _offTabStop = Timer(_offTabStopDelay, () {
        _offTabStop = null;
        // Re-checked at fire time: the app may have backgrounded (lifecycle
        // already stopped the scan) or the tab may be current again.
        if (mounted && !widget.active && _isScanning) {
          unawaited(_stopScan(byUser: false));
        }
      });
    }
  }

  /// Start scanning again unless something says not to.
  ///
  /// Every automatic resume — a tab coming back, the app returning from the
  /// background, a pop off the device screen, the radio coming back — goes
  /// through here, because they share the same reasons to stay off: the user
  /// stopped the scan, this is not the visible tab, or a device screen is
  /// open in front of us. That last one is not hypothetical: backgrounding
  /// the app while connected and coming back would otherwise restart the
  /// radio behind the device screen, undoing the stop [_connect] performs
  /// precisely to keep the connection off a scanning adapter. It covers the
  /// whole pushed stack, Find Device included — that screen navigates by the
  /// connection's RSSI, and a scan underneath it would add radio contention
  /// to the readings while being unable to see a connected (and therefore
  /// non-advertising) device at all.
  /// Always ambient: nothing that resumes by itself gets to claim the user
  /// just asked for it — the low-latency burst is the Scan button's alone.
  void _resumeIfIdle() {
    if (_isScanning || _pausedByUser || !widget.active || _onDeviceScreen) {
      return;
    }
    unawaited(_startScan(ScanIntensity.ambient));
  }

  /// Stop scanning while the app is in the background, resume when it returns.
  ///
  /// Not a nicety: a continuous BLE scan is the single most expensive thing
  /// this app does, Android throttles background scans anyway, and iOS stops
  /// delivering them to an app without the bluetooth-central background mode.
  /// So a scan left running while the app is away burns battery for results
  /// that will not arrive.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        // Including out of an error state: the usual reason someone leaves
        // this screen after "Bluetooth is turned off" is to go and turn it on,
        // and coming back to the same dead screen with a Retry button on it
        // would be a poor reward for having done what it asked.
        _resumeIfIdle();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        if (_isScanning) unawaited(_stopScan(byUser: false));
      // Transient — a notification shade or an incoming call. Stopping the
      // scan here would restart it seconds later for nothing.
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _startScan(ScanIntensity intensity) async {
    if (!mounted) return;
    // Tear down any in-flight scan before starting a new one. Cancel is
    // fire-and-forget: it synchronously stops delivery, and awaiting the
    // teardown future can stall inside the widget-test fake zone.
    unawaited(_scanSub?.cancel());
    _scanSub = null;
    _burstDownshift?.cancel();
    _burstDownshift = null;

    setState(() {
      _isScanning = true;
      _pausedByUser = false;
      _error = null;
      _permissionDenied = false;
      // Devices found so far are kept. They age out on their own now (see
      // DeviceManager.forgetAfter), so a restart — a retry, a return from the
      // background, a resume after a connect — no longer has to choose between
      // dropping everything and keeping it forever.
    });

    // A null timeout scans until we stop: the point is to keep listening, so a
    // device powered on two minutes from now still shows up. The intensity
    // decides how hard the radio listens meanwhile — an explicit press gets a
    // low-latency burst (downshifted below), everything self-started runs on
    // the balanced duty cycle.
    if (intensity == ScanIntensity.active) {
      _burstDownshift = Timer(_activeBurst, () {
        _burstDownshift = null;
        // Only a scan still running in the foreground gets downshifted; a
        // stop, a tab switch or a backgrounding has already ended the burst.
        if (mounted && _isScanning && widget.active) {
          unawaited(_startScan(ScanIntensity.ambient));
        }
      });
    }
    _scanSub = _bleService.scan(timeout: null, intensity: intensity).listen(
      (device) {
        if (!mounted) return;
        final isNew = _deviceManager.getById(device.id) == null;
        _deviceManager.addOrUpdate(device);
        // A new device is worth a frame of its own; an rssi tick on a known
        // one can wait for the next coalesced repaint.
        if (isNew) {
          _repaintNow();
        } else {
          _scheduleRepaint();
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _hasScanned = true;
          if (e is BlePermissionDeniedException) {
            _permissionDenied = true;
            _error = null;
          } else {
            _error = friendlyErrorText(
              e,
              context: 'BLE scan',
              fallback: 'Scanning failed. Check that Bluetooth is on, then '
                  'try again.',
            );
          }
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _hasScanned = true;
        });
      },
      cancelOnError: true,
    );
  }

  /// Stop the scan. [byUser] separates "they pressed stop" from the automatic
  /// stops (backgrounding, opening a device) that should resume by themselves.
  Future<void> _stopScan({required bool byUser}) async {
    unawaited(_scanSub?.cancel());
    _scanSub = null;
    _burstDownshift?.cancel();
    _burstDownshift = null;
    if (mounted) {
      setState(() {
        _isScanning = false;
        if (byUser) {
          _pausedByUser = true;
          _hasScanned = true;
        }
      });
    }
    await _bleService.stopScan().catchError((Object _) {});
  }

  /// Repaint at most every [_repaintInterval], for changes that are not worth
  /// a frame of their own.
  void _scheduleRepaint() {
    _repaint ??= Timer(_repaintInterval, () {
      _repaint = null;
      if (mounted) setState(() {});
    });
  }

  void _repaintNow() {
    _repaint?.cancel();
    _repaint = null;
    setState(() {});
  }

  /// Re-examine freshness: drop what has been silent too long, and repaint if
  /// any row's stale/live classification changed.
  void _ageDevices() {
    if (!mounted) return;
    final now = DateTime.now();
    final dropped = _deviceManager.forgetGone(now);
    final stale = _deviceManager.staleIds(now);
    if (!ageTickNeedsRepaint(
      dropped: dropped,
      stale: stale,
      previouslyStale: _staleIds,
    )) {
      return;
    }
    setState(() => _staleIds = stale);
  }

  /// Stop the active scan, then navigate to the device screen (which owns the
  /// connect). Stopping first keeps the native scan from running behind the
  /// pushed route, which otherwise makes connections flaky.
  Future<void> _connect(IoTDevice device) async {
    _onDeviceScreen = true;
    await _stopScan(byUser: false);
    if (!mounted) {
      _onDeviceScreen = false;
      return;
    }
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DeviceScreen(device: device)),
      );
    } finally {
      _onDeviceScreen = false;
    }
    // Back on the list: pick the scan up again, unless something says not to.
    if (mounted) _resumeIfIdle();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ageTicker?.cancel();
    _repaint?.cancel();
    _offTabStop?.cancel();
    _burstDownshift?.cancel();
    unawaited(_adapterSub?.cancel());
    // Fire-and-forget: unawaited() does not swallow errors, so attach a
    // catchError to keep a throw during teardown from surfacing as an
    // unhandled async error.
    unawaited(_scanSub?.cancel());
    unawaited(_bleService.stopScan().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.extension_outlined),
            tooltip: 'Device Spec Packs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SpecPackSettingsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Home Assistant',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HaSettingsScreen()),
            ),
          ),
          if (isMockMode) const _MockBadge(),
        ],
      ),
      body: SafeArea(child: _buildBody()),
      // House-ad bar. Renders zero-height until the provider has a banner, and
      // the provider never blocks: bundled/cached content first, network later.
      bottomNavigationBar: const AdBannerBar(),
      // Two buttons, sized by how much they have to say for themselves.
      //
      // While a scan runs, the useful control is the one that turns the radio
      // off, and it wants as little of the screen as it can get away with: the
      // radar is already saying "scanning", the list below it is the thing
      // worth looking at, and a wide bar reading "Stop" over the results would
      // be shouting an offer nobody came here for. A small round stop button is
      // enough, with the reason for pressing it in its tooltip.
      //
      // Stopped, the opposite is true: nothing is happening, so the way back to
      // scanning has to be the most obvious thing on the screen.
      //
      // The hero tag is explicit (and shared, since the two are never on screen
      // together) because HomeShell keeps this screen and the Wi-Fi one alive in
      // an IndexedStack, so both tabs' FABs are in the tree at once and the
      // default tag would collide. That is not a layout nit: it throws out of
      // the hero controller the moment any route is pushed, which is every tap
      // on a device.
      floatingActionButton: _isScanning
          ? FloatingActionButton.small(
              heroTag: 'scan-fab',
              tooltip: 'Stop scanning — saves battery',
              onPressed: () => _stopScan(byUser: true),
              child: const Icon(Icons.stop),
            )
          : FloatingActionButton.extended(
              heroTag: 'scan-fab',
              tooltip: 'Scan for devices',
              // An explicit press is the one thing that buys the low-latency
              // burst; everything the screen starts by itself is ambient.
              onPressed: () => _startScan(ScanIntensity.active),
              icon: const Icon(Icons.search),
              label: const Text('Scan'),
            ),
    );
  }

  /// Headline under the radar. Doubles as the scan status readout, so the
  /// screen never needs a separate progress caption.
  String get _headline {
    if (_permissionDenied) return 'Bluetooth permission needed';
    if (_error != null) return 'Scan failed';
    if (_deviceManager.count > 0) {
      final n = _deviceManager.count;
      return '$n device${n == 1 ? '' : 's'} found';
    }
    if (_isScanning) return 'Searching for devices...';
    if (_hasScanned) return 'No devices found';
    return 'Scan for BLE Devices';
  }

  String get _subhead {
    if (_permissionDenied) {
      return 'Grant Bluetooth (and, on Android, nearby-devices/location) '
          'access so the app can scan for devices.';
    }
    if (_error != null) return _error!;
    if (_deviceManager.count > 0) {
      // Says the quiet part: the list is live, so a row appearing or picking
      // up a warning a minute from now is the screen working, not a glitch.
      return _isScanning
          ? 'Tap a device to connect. Still scanning for more.'
          : 'Tap a device to connect. Scanning stopped.';
    }
    if (_isScanning) return 'Make sure your device is powered on and nearby.';
    if (_hasScanned) {
      return 'Move closer or check the device is powered on, then scan again.';
    }
    return AppConstants.appTagline;
  }

  /// One row in either found-devices group.
  Widget _deviceCard(
    RankedDevice entry,
    DeviceDescription description,
    DateTime now,
  ) {
    final device = entry.device;
    final stale = DeviceManager.isStale(device, now);
    final age = shortAge(device.ageAt(now));
    final guess = entry.guess;
    // A device the catalogue flagged as a known security risk is not an
    // ordinary row: it opens a warning, not the controls; it is tappable even
    // when it is not connectable (the warning is the point); and its glyph is
    // drawn in the theme's error/caution colour so it reads as a warning.
    final warning = guess?.advisory;
    final scheme = Theme.of(context).colorScheme;
    return DeviceListTile(
      title: deviceTitle(device, description),
      // A stale row's signal reading is history, so it stops claiming one and
      // says how long the device has been quiet instead.
      subtitle: stale
          ? 'Not seen for $age'
          : (device.isConnectable
              ? _signalLabel(device.rssi)
              : 'Not connectable'),
      detail: stale ? 'last ${device.rssi} dBm' : '${device.rssi} dBm',
      rssi: device.rssi,
      stale: stale,
      staleReason: 'No advertisement for $age — the device may be out of '
          'range or powered off',
      icon: guess?.iconOr(unknownDeviceIcon) ?? unknownDeviceIcon,
      // A suspected-malicious device (a skimmer) gets the black-hat pictogram,
      // not a Material glyph; other warnings keep their category icon, tinted.
      iconWidget: guess?.isMalicious == true
          ? BlackHatIcon(size: 24, color: scheme.error)
          : null,
      iconColor: warning == null
          ? null
          : (guess!.isMalicious || warning.severity == 'vulnerable'
              ? scheme.error
              : scheme.tertiary),
      badge: warning == null ? guess?.label : _warningBadge(guess!),
      badgeIsClaim: warning == null && entry.isLikelySupported,
      // Only worth saying for a device the badge could not place. Once the
      // badge names a product, "Ember Technologies · Battery Service"
      // underneath it is noise — but a guess that does NOT name a product
      // (a shared OUI, or a tie) leaves the row titled with the maker, and
      // two unnamed same-OUI devices are then the same row twice. The
      // address is the only thing that tells them apart, which is exactly
      // what deviceSubtitle documents itself as being for.
      description: entry.guess?.namesAProduct == true
          ? null
          : deviceSubtitle(device, description),
      // A warning row is always tappable, connectable or not — the warning is
      // what the tap is for.
      enabled: warning != null || device.isConnectable,
      onTap: warning != null
          ? () => _openWarning(device, guess!)
          : (device.isConnectable ? () => _connect(device) : null),
    );
  }

  /// The scan badge for a security-warning row — short, and worded by severity.
  String _warningBadge(ScanGuess guess) => switch (guess.advisory!.severity) {
        'malicious' => 'Possible skimmer',
        'vulnerable' => 'Security risk',
        _ => 'Reported issue',
      };

  /// Open the warning page for a flagged device — not the control screen. Does
  /// not touch the scan the way [_connect] does: nothing connects, so the scan
  /// keeps running behind the pushed route.
  Future<void> _openWarning(IoTDevice device, ScanGuess guess) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SecurityWarningScreen(
          device: device,
          advisory: guess.advisory!,
          guess: guess,
        ),
      ),
    );
  }

  Widget _buildBody() {
    final registry = ref.watch(numberRegistryProvider);
    final found = _deviceManager.devices;
    // One instant for the whole pass, so every row is classified against the
    // same clock and the ordering below agrees with the badges above it.
    final now = DateTime.now();
    // Each device gets its own matching future, keyed on its identity rather
    // than its id — an rssi tick reuses the cached result instead of asking
    // again. A guess that has not resolved yet reads as "no guess", so a row
    // appears immediately and gains its badge a frame later rather than the
    // whole list waiting on the catalogue.
    final ranked = rankScannedDevices(
      found,
      (device) =>
          ref.watch(scanGuessProvider(ScanIdentity.of(device))).valueOrNull,
      isStale: (device) => DeviceManager.isStale(device, now),
    );
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListView(
      // Bottom inset clears the extended FAB so the last row is never parked
      // underneath it.
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      children: [
        const SizedBox(height: 16),
        Center(child: RadarScanner(scanning: _isScanning)),
        const SizedBox(height: 32),
        Text(
          _headline,
          textAlign: TextAlign.center,
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: ConstrainedBox(
            // Constrained measure keeps guidance text at a readable line length
            // instead of running edge to edge.
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              _subhead,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: _error != null ? scheme.error : scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ),
        if (_permissionDenied) ...[
          const SizedBox(height: 24),
          Center(
            child: ActionPillButton(
              // Fire-and-forget like the other teardown calls in this file: a
              // failure to open the settings app must not become an unhandled
              // async error.
              onPressed: () =>
                  unawaited(openAppSettings().catchError((Object _) => false)),
              icon: Icons.settings,
              label: 'Open settings',
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed:
                  _isScanning ? null : () => _startScan(ScanIntensity.active),
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              child: const Text('Retry'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 24),
          Center(
            child: ActionPillButton(
              onPressed:
                  _isScanning ? null : () => _startScan(ScanIntensity.active),
              icon: Icons.refresh,
              label: 'Retry',
            ),
          ),
        ],
        // A completed empty scan gets its own call to action rather than
        // relying on the user finding the FAB again.
        if (_hasScanned &&
            !_isScanning &&
            found.isEmpty &&
            _error == null &&
            !_permissionDenied) ...[
          const SizedBox(height: 24),
          Center(
            child: ActionPillButton(
              onPressed: () => _startScan(ScanIntensity.active),
              icon: Icons.refresh,
              label: 'Scan again',
            ),
          ),
        ],
        if (found.isNotEmpty) ...[
          if (ranked.likelySupported.isNotEmpty) ...[
            const SizedBox(height: 36),
            SectionHeader(
              label: 'Likely supported',
              count: ranked.likelySupported.length,
            ),
            const SizedBox(height: 12),
            for (final entry in ranked.likelySupported) ...[
              _deviceCard(entry, describeWith(registry, entry.device), now),
              const SizedBox(height: 10),
            ],
          ],
          if (ranked.other.isNotEmpty) ...[
            const SizedBox(height: 36),
            SectionHeader(
              // Only worth distinguishing from the group above when there IS
              // a group above; otherwise this is simply everything found.
              label: ranked.likelySupported.isEmpty ? 'Found' : 'Other devices',
              count: ranked.other.length,
            ),
            const SizedBox(height: 12),
            for (final entry in ranked.other) ...[
              _deviceCard(entry, describeWith(registry, entry.device), now),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ],
    );
  }

  /// Prose rendering of [signalBars], so the words and the meter beside them
  /// are the same judgement. They used to carry their own thresholds, and at
  /// -75 dBm the row said "Good signal" over two bars — and now that the list
  /// ORDERS by the band as well, a stray third opinion would let a row sort
  /// below one it out-describes.
  static String _signalLabel(int rssi) => switch (signalBars(rssi)) {
        4 => 'Strong signal',
        3 => 'Good signal',
        2 => 'Fair signal',
        _ => 'Weak signal',
      };
}

class _MockBadge extends StatelessWidget {
  const _MockBadge();

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).appBarTheme.foregroundColor;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: fg?.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: fg?.withValues(alpha: 0.4) ?? fg!),
          ),
          child: Text(
            'MOCK',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
          ),
        ),
      ),
    );
  }
}
