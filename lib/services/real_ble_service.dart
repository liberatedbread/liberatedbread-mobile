// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/constants.dart';
import '../core/error_text.dart';
import '../core/find_device.dart' show isPlausibleRssi;
import '../core/hex.dart';
import '../core/log.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import 'ble_service.dart';

/// Map a flutter_blue_plus connection state to our internal enum.
/// Extracted as a top-level function so it can be unit-tested without
/// a real Bluetooth adapter.
BleConnectionState mapConnectionState(BluetoothConnectionState state) {
  switch (state) {
    case BluetoothConnectionState.connected:
      return BleConnectionState.connected;
    // flutter_blue_plus marks these as deprecated because current OS callbacks
    // don't stream them, but they can still arrive from getConnectionState and
    // future/other platforms; map them precisely instead of collapsing to
    // disconnected.
    // ignore: deprecated_member_use
    case BluetoothConnectionState.connecting:
      return BleConnectionState.connecting;
    // ignore: deprecated_member_use
    case BluetoothConnectionState.disconnecting:
      return BleConnectionState.disconnecting;
    case BluetoothConnectionState.disconnected:
      return BleConnectionState.disconnected;
  }
}

/// Map a flutter_blue_plus adapter state to the error that should be raised on
/// the scan stream, or null when scanning may proceed.
///
/// [BluetoothAdapterState.unauthorized] is called out separately because it is
/// how a real Bluetooth *permission* denial surfaces: iOS reports a denied or
/// restricted CoreBluetooth authorization through the adapter state rather than
/// by failing `startScan`. Collapsing it into [BleUnavailableException] would
/// tell the user to "turn Bluetooth on" — the wrong setting, and one that looks
/// already-correct to them, leaving no way out of the empty state. Every other
/// non-`on` state keeps the previous radio-unavailable treatment.
///
/// Extracted as a pure top-level function so the mapping can be unit-tested
/// without a real Bluetooth adapter (FlutterBluePlus's API is static, so the
/// call site itself cannot be mocked).
UserFacingException? adapterStateError(BluetoothAdapterState state) {
  switch (state) {
    case BluetoothAdapterState.on:
      return null;
    case BluetoothAdapterState.unauthorized:
      return const BlePermissionDeniedException();
    case BluetoothAdapterState.off:
    case BluetoothAdapterState.turningOff:
    case BluetoothAdapterState.turningOn:
    case BluetoothAdapterState.unavailable:
    case BluetoothAdapterState.unknown:
      return const BleUnavailableException();
  }
}

/// Whether the platform is still deciding what the adapter state is.
///
/// CoreBluetooth answers `unknown` from the moment its central manager is
/// created until `centralManagerDidUpdateState` fires — asynchronously, and on
/// a first launch not until the user has answered the system Bluetooth prompt.
/// Judging that first answer ([adapterStateError] maps it to "turned off") is
/// what put 'Bluetooth is turned off' on screen underneath the permission
/// alert, and left it there after a Deny, because the denial arrived later as
/// `unauthorized` to a scan that had already given up. `turningOn` is the same
/// story a moment later. Both are states to wait out, not to report.
///
/// Extracted as a pure top-level function so the judgement can be unit-tested
/// without a real Bluetooth adapter.
bool isAdapterStateSettling(BluetoothAdapterState state) =>
    state == BluetoothAdapterState.unknown ||
    state == BluetoothAdapterState.turningOn;

/// How long [RealBleService] waits for the adapter to report a settled state
/// before treating it as unavailable.
///
/// Generous, because the wait covers a person reading a permission alert; a
/// state that has still not settled by then is a radio that is not coming, and
/// [adapterStateError] reports it as such.
const Duration adapterSettleTimeout = Duration(seconds: 90);

/// Decide whether cancelling a scan stream should stop the underlying native
/// scan.
///
/// [active] is the currently-registered scan subscription (the shared
/// `_scanSubscription` field) and [own] is the subscription belonging to the
/// scan being cancelled. The native scan is stopped only when our subscription
/// is still the active one — or the field was already cleared by our own normal
/// completion (`active == null`). If a newer `scan()` has installed a different
/// subscription, `active` points at it and we must NOT stop its native scan.
///
/// A null [own] means this scan has ALREADY been torn down — its own teardown
/// nulled the field, and that teardown is where the native scan's fate was
/// decided. Closing the stream afterwards cancels the last subscription and
/// brings us back here, and stopping the radio at that point would reach past
/// this scan's lifetime into whatever is running now. That is not theoretical:
/// superseding a scan closes the old stream milliseconds before the new one
/// calls startScan, and the late stop landed on the new scan, which then found
/// nothing at all.
///
/// Extracted as a pure top-level function so the re-entrancy guard can be
/// unit-tested without a real Bluetooth adapter.
bool shouldStopNativeScanOnCancel({
  required Object? active,
  required Object? own,
}) => own != null && (active == null || identical(active, own));

/// Delay before retrying a service discovery that returned zero services, or
/// null when [attempt] retries have already happened and the empty result
/// should be accepted as final.
///
/// A connectable GATT peripheral virtually always exposes at least the
/// Generic Access/Attribute services, so an empty discovery result is almost
/// never real — it is a race with the platform's service resolution. The
/// concrete case this fixes: flutter_blue_plus's Linux backend answers
/// discoverServices from BlueZ's current D-Bus object tree WITHOUT waiting
/// for BlueZ's ServicesResolved flag, so a discovery issued right after
/// connect sees an empty tree. The log signature is "discovered 0 service(s)"
/// only milliseconds after "connected" (observed with SmartDawn/Daniao
/// controllers: 7ms).
///
/// Resolution normally lands within a couple of seconds, so the delays grow
/// from quick to patient: ~6s total across 5 retries, enough for a slow
/// peripheral without pinning the "Discovering services" screen open forever
/// when the device genuinely exposes nothing.
///
/// Extracted as a pure top-level function so the schedule can be unit-tested
/// without a real Bluetooth adapter.
Duration? nextEmptyDiscoveryRetryDelay(int attempt) {
  const delays = [
    Duration(milliseconds: 200),
    Duration(milliseconds: 400),
    Duration(milliseconds: 800),
    Duration(milliseconds: 1600),
    Duration(milliseconds: 3200),
  ];
  return attempt < delays.length ? delays[attempt] : null;
}

/// Whether an error thrown by `setNotifyValue` is the Linux backend's
/// spurious confirmation timeout, which should be tolerated because the
/// subscription is actually live.
///
/// flutter_blue_plus_linux (3.0.2, the newest release compatible with
/// flutter_blue_plus 1.35.4) performs BlueZ StartNotify/StopNotify
/// synchronously inside the platform call — by the time the call returns,
/// notifications are flowing. But flutter_blue_plus core then waits for an
/// onDescriptorWritten event for the CCCD (0x2902), which that backend never
/// emits: BlueZ manages the CCCD internally and does not even expose it as a
/// descriptor. So on Linux every setNotifyValue "times out" AFTER succeeding.
/// Tolerating exactly (Linux && setNotifyValue && timeout) turns that into a
/// logged warning instead of a dead subscription; every other error — wrong
/// characteristic, device disconnected, a genuine unacked CCCD write on
/// Android/iOS — still surfaces.
///
/// Extracted as a pure top-level function so the tolerance can be unit-tested
/// without a real Bluetooth adapter.
bool isSpuriousLinuxNotifyTimeout(Object error, {required bool isLinux}) =>
    isLinux &&
    error is FlutterBluePlusException &&
    error.function == 'setNotifyValue' &&
    error.code == FbpErrorCode.timeout.index;

/// ATT error codes that all mean "this attribute needs a paired, encrypted
/// link and this link is not one".
///
/// These are ATT protocol codes, so Android's `GATT_INSUFFICIENT_*` constants,
/// Apple's `CBATTError` cases and BlueZ's ATT errors are all the same numbers —
/// which is why one small set covers every platform:
///   0x05 insufficient authentication, 0x08 insufficient authorization,
///   0x0F insufficient encryption.
const _attPairingErrorCodes = {0x05, 0x08, 0x0F};

/// Whether [error] is the peripheral never answering, rather than refusing.
///
/// flutter_blue_plus reports its own timeout as `ErrorPlatform.fbp` with
/// `FbpErrorCode.timeout` (1), which is a different thing from an ATT error
/// the device sent: nothing came back at all. Matched on the platform AND the
/// code, for the reason [isPairingRequiredError] gives — an fbp code and a
/// native ATT code at the same number mean unrelated things.
bool isCharacteristicSilentError(Object error) =>
    error is FlutterBluePlusException &&
    error.platform == ErrorPlatform.fbp &&
    error.code == FbpErrorCode.timeout.index;

/// Whether [error] is a peripheral refusing an operation for lack of pairing.
///
/// The platform check is the load-bearing part. `FlutterBluePlusException.code`
/// means completely different things depending on `platform`: for a NATIVE
/// error it is the ATT/GATT code the stack reported, but for
/// [ErrorPlatform.fbp] it is an index into flutter_blue_plus's own
/// [FbpErrorCode] enum, where 5 is `removeBondFailed` and 8 is
/// `characteristicNotFound`. Reading those as ATT codes would tell a user to go
/// and pair a device over a missing characteristic.
///
/// Extracted as a pure top-level function so the classification can be
/// unit-tested without a real Bluetooth adapter.
bool isPairingRequiredError(Object error) {
  if (error is FlutterBluePlusException) {
    if (error.platform == ErrorPlatform.fbp) return false;
    if (_attPairingErrorCodes.contains(error.code)) return true;
    // BlueZ answers over D-Bus with a name rather than an ATT code — the code
    // arrives as 0 or null and the description carries the meaning.
    return _namesPairing(error.description);
  }
  // Not every failure arrives wrapped. flutter_blue_plus_linux converts a
  // failed READ into a BmCharacteristicData with an error string (which becomes
  // a FlutterBluePlusException above), but it lets the D-Bus exception from
  // StartNotify propagate as-is — so a peripheral refusing a subscription for
  // lack of pairing reaches us as a raw DBusMethodResponseException. Matching
  // the phrase rather than the type keeps package:dbus out of this package's
  // dependencies for the sake of one `is` check.
  return _namesPairing(error.toString());
}

/// Whether [text] is a stack saying, in words, that the link must be paired.
///
/// The phrases are the D-Bus/BlueZ renderings; every numeric platform is
/// handled by the ATT codes above. Matched narrowly on purpose: BlueZ also
/// raises `org.bluez.Error.NotPermitted` for an ordinary write to a read-only
/// characteristic, so the error NAME alone would send users to pair a device
/// over something pairing cannot fix.
bool _namesPairing(String? text) {
  final lower = text?.toLowerCase() ?? '';
  return lower.contains('not paired') ||
      lower.contains('insufficient authentication') ||
      lower.contains('insufficient encryption') ||
      lower.contains('not authorized');
}

/// Decide whether a write should be sent WITHOUT a response, given a
/// characteristic's advertised write properties.
///
/// Prefer write-with-response when the characteristic supports it (it's
/// acknowledged and more reliable); fall back to write-without-response only
/// when that is the characteristic's ONLY writable mode. Many real BLE control
/// characteristics are write-without-response only — sending them a
/// with-response write silently fails, so the mode must be chosen per
/// characteristic rather than always calling `write(value)`.
///
/// Extracted as a pure top-level function so the mode selection can be
/// unit-tested without a real Bluetooth adapter.
bool useWriteWithoutResponse({
  required bool canWriteWithResponse,
  required bool canWriteWithoutResponse,
}) => !canWriteWithResponse && canWriteWithoutResponse;

/// How long an unchanged advertisement may go unreported before the coalescer
/// re-emits it anyway.
///
/// Without this, a device whose advertisement never changes — same name, same
/// service UUIDs, and an rssi that quantises to the same dBm reading twice in a
/// row — would be reported once and never again, and the consumer would have no
/// way to tell it apart from one that had been switched off. The heartbeat puts
/// a ceiling on how out-of-date [IoTDevice.lastSeen] can be for a device that is
/// still on air; it is well under `DeviceManager.staleAfter` so a live device
/// never drifts into the warning state on the strength of a quiet advertisement.
const Duration scanHeartbeat = Duration(seconds: 5);

/// Per-scan coalescing of flutter_blue_plus scan results.
///
/// The scan asks for every advertisement (continuous updates, one by one), so
/// a device that advertises ten times a second would otherwise reach the
/// consumer ten times a second — constantly refreshing `discoveredAt` and
/// flooding the DeviceManager with no-op updates. [next] returns an
/// [IoTDevice] only when the device is new to this scan, when something about
/// it changed (so rssi updates still flow), or when [scanHeartbeat] has passed
/// since it was last reported; it returns null for an unchanged sighting inside
/// that window. The first-seen `discoveredAt` is preserved for known ids, while
/// `lastSeen` advances with each sighting. State is keyed by id, so the cost of
/// a sighting does not grow with the number of devices already found.
///
/// `seenAt` is the advertisement's own timestamp, not the wall clock at the
/// moment it is processed. One-by-one delivery makes the two nearly equal, but
/// the advertisement's is the truthful one — and it is what fbp would hand
/// over for a re-pushed entry if the scan were ever switched back to
/// accumulated lists, where reading the clock would refresh a dead device's
/// `lastSeen` every time a live one advertised.
///
/// Extracted as a pure class so the coalescing rules can be unit-tested
/// without a real Bluetooth adapter.
class ScanResultCoalescer {
  final Map<String, IoTDevice> _emitted = {};

  /// Distinct devices emitted so far in this scan, for the scan-finished log.
  int get deviceCount => _emitted.length;

  IoTDevice? next({
    required String id,
    required String name,
    required int rssi,
    required bool isConnectable,
    List<String> serviceUuids = const [],
    List<int> companyIds = const [],
    Map<int, List<int>> manufacturerData = const {},
    DateTime? seenAt,
  }) {
    final at = seenAt ?? DateTime.now();
    final prev = _emitted[id];
    // Reject before constructing: this runs for every device in every
    // advertisement batch, and the common case is "nothing changed". The field
    // list mirrors IoTDevice.hasSameIdentity plus the two mutable fields.
    if (prev != null &&
        prev.rssi == rssi &&
        prev.isConnectable == isConnectable &&
        prev.name == name &&
        listEquals(prev.serviceUuids, serviceUuids) &&
        listEquals(prev.companyIds, companyIds) &&
        at.difference(prev.lastSeen) < scanHeartbeat) {
      return null;
    }
    final device = IoTDevice(
      id: id,
      name: name,
      rssi: rssi,
      isConnectable: isConnectable,
      discoveredAt: prev?.discoveredAt ?? at,
      lastSeen: at,
      serviceUuids: serviceUuids,
      companyIds: companyIds,
      manufacturerData: manufacturerData,
    );
    _emitted[id] = device;
    return device;
  }
}

/// Seconds to wait for an RSSI read before giving up, overriding
/// flutter_blue_plus's 15s default. The Find Device view polls once a second
/// and treats three consecutive failures as a lost signal, so a 15s wait
/// would stretch "signal lost" to ~45 seconds of stale-looking-live data.
const int rssiReadTimeoutSeconds = 3;

/// Report one advertisement in this many, per device, on an ACTIVE scan.
///
/// Continuous scanning asks the platform for EVERY advertisement (that is what
/// `continuousUpdates` means: allowDuplicates on Apple platforms, no
/// same-payload suppression on Android), and under a low-latency scan a chatty
/// peripheral emits ten a second. Every one of those crosses the platform
/// channel, so halving them halves the cost. Two, not ten: the divisor also
/// decides how quickly a device's last-seen stamp refreshes, and a slow
/// advertiser must still stay comfortably inside the stale threshold.
///
/// Ambient scans on Android do not use it (see [continuousDivisorFor]): the
/// balanced duty cycle has already thinned receptions at the radio, and
/// stacking the divisor on top would double a sleepy sensor's already-long
/// reception gaps for a channel saving that no longer exists. Apple platforms
/// have no such duty cycle — see [appleAmbientScanDivisor].
const int continuousScanDivisor = 2;

/// The ambient divisor on Apple platforms, where it is the ONLY thinning
/// there is.
///
/// Apple exposes no scan-mode knob, so the duty cycle that lets Android's
/// ambient scan run undivided does not exist there: `continuousUpdates` is
/// allowDuplicates, and every advertisement from every device in range crosses
/// the platform channel unless the divisor drops it. Undivided, the always-on
/// ambient scan was the most expensive configuration the app has — twice the
/// channel traffic of the explicit burst it is meant to be cheaper than.
/// Four keeps a once-a-second advertiser refreshing `lastSeen` every few
/// seconds, inside [scanHeartbeat] and far inside `DeviceManager.staleAfter`.
const int appleAmbientScanDivisor = 4;

/// The Android scan mode a [ScanIntensity] asks for.
///
/// This is the single biggest energy dial the scan has: low latency keeps the
/// radio receiving continuously, balanced duty-cycles it to roughly a quarter
/// (1024ms windows on a 4096ms interval in AOSP). An active scan — the user
/// pressed Scan and is watching — buys the continuous listen; the ambient
/// watch the tab runs on its own does not need discoveries within a second,
/// so it takes the duty cycle. Android-only by nature: Apple platforms expose
/// no scan-mode knob, and their cost is bounded instead by the tab/lifecycle
/// gating that keeps the scan foreground-only.
///
/// Extracted as a pure top-level function so the mapping can be unit-tested
/// without a real Bluetooth adapter.
AndroidScanMode androidScanModeFor(ScanIntensity intensity) =>
    switch (intensity) {
      ScanIntensity.active => AndroidScanMode.lowLatency,
      ScanIntensity.ambient => AndroidScanMode.balanced,
    };

/// The per-device advertisement divisor a [ScanIntensity] asks for.
///
/// [isApple] is a parameter rather than a platform check so the transport
/// logic stays platform-neutral and both answers run on any CI host; the one
/// `Platform` read is at the call site. See [continuousScanDivisor] for why
/// ambient is 1 where the radio duty-cycles, and [appleAmbientScanDivisor] for
/// why it is not where it does not.
///
/// Extracted as a pure top-level function for the same reason as
/// [androidScanModeFor].
int continuousDivisorFor(ScanIntensity intensity, {required bool isApple}) =>
    switch (intensity) {
      ScanIntensity.active => continuousScanDivisor,
      ScanIntensity.ambient => isApple ? appleAmbientScanDivisor : 1,
    };

/// How often a continuous scan restarts the underlying platform scan.
///
/// Android converts a scan that has been running for 30 minutes into an
/// opportunistic one — it keeps the callback registered but stops driving the
/// radio, so the app silently goes deaf while still believing it is scanning.
/// Restarting well inside that window keeps a long-lived scan real. Every
/// platform takes the same treatment: a restart is cheap, and one code path is
/// worth more here than shaving a stop/start off iOS every quarter of an hour.
/// Results are NOT lost across it — the coalescer's state, and the caller's
/// device list, both outlive the platform scan.
const Duration continuousScanRefresh = Duration(minutes: 15);

/// How soon a failed refresh is retried.
///
/// A refresh failure is not a missed tick, it is a stopped scan: flutter_blue_plus
/// stops the running scan before starting the replacement and unwinds itself if
/// the platform call fails, so there is nothing scanning afterwards. Short
/// enough that a transient failure — the adapter busy, a bonding in flight — is
/// a blip rather than fifteen dead minutes behind a screen that says
/// "searching".
const Duration continuousScanRetry = Duration(seconds: 30);

/// How long to look for a saved device whose Apple identifier the system has
/// forgotten, before telling the user it has not been heard.
///
/// Short on purpose: this runs inside a reconnect the user is waiting on, and
/// a device that is powered on and in range advertises within a second or two.
/// Anything longer turns "not there" into a hang.
///
/// Not `const`: an emulated test drives the whole rediscovery sequence, and
/// the scan it waits on ends when this window does, so a test that could not
/// shrink it would spend six seconds per case.
@visibleForTesting
Duration appleRediscoveryWindow = const Duration(seconds: 6);

/// Real BLE implementation using flutter_blue_plus.
class RealBleService implements BleService, BleAuthorizationWatcher {
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  final Map<String, List<BluetoothService>> _servicesCache = {};

  /// Overridable so a test can watch the refresh happen without waiting a
  /// quarter of an hour for it.
  @visibleForTesting
  Duration continuousScanRefreshInterval = continuousScanRefresh;

  /// Overridable for the same reason as [continuousScanRefreshInterval].
  @visibleForTesting
  Duration continuousScanRetryInterval = continuousScanRetry;

  /// Overridable so a test can watch [_settledAdapterState] give up without
  /// waiting a minute and a half for it.
  @visibleForTesting
  Duration adapterSettleWindow = adapterSettleTimeout;

  /// Whether this is an Apple platform, for the decisions that differ there:
  /// the scan divisor ([continuousDivisorFor]), the identifier-rediscovery
  /// connect path ([_isAppleUnknownPeripheral]) and the wording of a pairing
  /// refusal. Injectable so a test can exercise both answers on whatever host
  /// CI is — without it the rediscovery path is dead code on Linux, which is
  /// every job in .github/workflows/ci.yml.
  @visibleForTesting
  bool isApple = Platform.isIOS || Platform.isMacOS;

  /// The adapter state once the platform has actually reported one.
  ///
  /// `FlutterBluePlus.adapterState.first` answers with whatever the platform
  /// says RIGHT NOW, and on Apple platforms that is `unknown` until
  /// CoreBluetooth's asynchronous state callback fires — on a first launch,
  /// not until the user has answered the system Bluetooth prompt. So this
  /// waits out the settling states ([isAdapterStateSettling]) and answers
  /// with the first real one; a Deny lands here as `unauthorized`, an Allow
  /// as `on`. Past [adapterSettleWindow] it answers `unknown`, which the
  /// callers' [adapterStateError] reports as the radio being unavailable.
  ///
  /// Listened to explicitly rather than `firstWhere(...).timeout(...)`, so a
  /// timeout also cancels the wait instead of leaving a listener on the
  /// adapter stream until the state eventually settles.
  Future<BluetoothAdapterState> _settledAdapterState() async {
    final settled = Completer<BluetoothAdapterState>();
    final sub = FlutterBluePlus.adapterState.listen(
      (state) {
        if (settled.isCompleted || isAdapterStateSettling(state)) return;
        settled.complete(state);
      },
      onError: (Object error, StackTrace stack) {
        if (!settled.isCompleted) settled.completeError(error, stack);
      },
      onDone: () {
        if (settled.isCompleted) return;
        settled.complete(BluetoothAdapterState.unknown);
      },
    );
    try {
      return await settled.future.timeout(
        adapterSettleWindow,
        onTimeout: () {
          Log.ble.warning(
            'adapter state did not settle within '
            '${adapterSettleWindow.inSeconds}s; treating it as unavailable',
          );
          return BluetoothAdapterState.unknown;
        },
      );
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      return statuses.values.every((s) => s.isGranted);
    }
    // iOS deliberately has NO branch here and falls through to true.
    //
    // CoreBluetooth raises the system Bluetooth prompt itself, natively, the
    // first time a CBCentralManager starts scanning — flutter_blue_plus does
    // that for us, and Info.plist already carries the required
    // NSBluetoothAlwaysUsageDescription / NSBluetoothPeripheralUsageDescription
    // strings. So there is nothing for a permission plugin to ask for up front.
    //
    // We must NOT ask permission_handler either: its iOS Bluetooth strategy is
    // compiled out unless the CocoaPods post_install hook defines
    // PERMISSION_BLUETOOTH=1. permission_handler_apple's PermissionHandlerEnums.h
    // defaults it to 0, which declares BluetoothPermissionStrategy as an
    // UnknownPermissionStrategy — and that answers every request with
    // PermissionStatusPermanentlyDenied. Calling Permission.bluetooth.request()
    // here therefore returned false unconditionally on a real iPhone, so scan()
    // raised BlePermissionDeniedException before it ever reached CoreBluetooth
    // and the OS prompt was never shown. Only mock/simulator paths were exercised
    // in CI, so nothing caught it.
    //
    // A genuine iOS denial is not lost by returning true: it surfaces as
    // BluetoothAdapterState.unauthorized on the adapter-state check in scan(),
    // which adapterStateError maps back to BlePermissionDeniedException. That
    // check WAITS for CoreBluetooth to settle (_settledAdapterState), so it
    // holds for the first scan too — the one whose start raises the prompt —
    // and not only for scans issued after the prompt has been answered.
    return true;
  }

  @override
  Stream<IoTDevice> scan({
    Duration? timeout = const Duration(
      seconds: AppConstants.defaultScanDuration,
    ),
    ScanIntensity intensity = ScanIntensity.active,
  }) {
    final controller = StreamController<IoTDevice>();

    // Subscription local to this scan invocation. Kept local (rather than
    // relying solely on the shared _scanSubscription field) so a concurrent
    // scan() call can't orphan or cancel the wrong subscription.
    StreamSubscription<List<ScanResult>>? sub;
    // Keeps a continuous scan off Android's 30-minute opportunistic cliff;
    // null for a bounded scan, which ends long before that matters.
    Timer? refresh;
    // Watches for the radio going away under a continuous scan (see below);
    // null for a bounded scan, whose adapter check at the top is enough.
    StreamSubscription<BluetoothAdapterState>? adapterSub;
    // Set the moment any teardown path begins (every one funnels through
    // cancelSub). Distinct from `cancelled`, which only marks a consumer-side
    // cancel: a stopScan() or a superseding scan tears down without one. The
    // refresh callback checks this, because cancelling its Timer cannot reach
    // a callback that has already fired and is mid-await — without the check,
    // that callback restarts the native scan nobody is listening to and then
    // reschedules itself, forever.
    var tornDown = false;
    // Set when the consumer lets go. Setup is a chain of awaits — permissions,
    // adapter state, tearing down a previous scan — and a cancel arriving
    // during it finds nothing to cancel: `sub` does not exist yet, so onCancel
    // has no scan to stop, and without this flag the setup would carry on and
    // start a native scan nobody is listening to. Which, for a continuous scan,
    // means one that runs until the app dies: there is no window to expire, and
    // the screen's own state says it is not scanning, so nothing will ever stop
    // it. Checked after every await from here on.
    var cancelled = false;

    Future<void> closeIfOpen() async {
      if (!controller.isClosed) await controller.close();
    }

    Future<void> cancelSub() async {
      tornDown = true;
      refresh?.cancel();
      refresh = null;
      try {
        await adapterSub?.cancel();
      } catch (_) {
        // Ignore, for the same reason as the scan subscription below.
      }
      adapterSub = null;
      try {
        await sub?.cancel();
      } catch (_) {
        // Ignore — a throw from cancel() must not prevent the shared-field
        // bookkeeping (and any follow-up stopScan()) from running.
      }
      // Only clear the shared field if it still points at our subscription;
      // a newer scan() may have replaced it.
      if (identical(_scanSubscription, sub)) {
        _scanSubscription = null;
        _endActiveScan = null;
      }
      sub = null;
    }

    // Ends this scan from outside — what [stopScan] calls. A bounded scan
    // discovers the stop for itself, by waiting on `isScanning`; a continuous
    // one has nothing to wait on, so without this its stream would stay open
    // (and its refresh timer armed) after the caller asked it to stop.
    Future<void> endScan() async {
      await cancelSub();
      await closeIfOpen();
    }

    /// Abandon a setup the consumer no longer wants, stopping the native scan
    /// if we got as far as starting one. Returns true when it applied, so the
    /// setup can `return` on it.
    Future<bool> abandonIfCancelled({bool nativeScanStarted = false}) async {
      if (!cancelled) return false;
      Log.ble.debug('scan cancelled during setup; unwinding');
      if (nativeScanStarted) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {
          // Best-effort: the scan may already have failed to start.
        }
      }
      await endScan();
      return true;
    }

    () async {
      try {
        final granted = await requestPermissions();
        if (await abandonIfCancelled()) return;
        if (!granted) {
          // Surface a distinct error rather than silently closing the stream,
          // so the UI can render permission-specific guidance + recovery
          // instead of a generic empty state.
          Log.ble.warning('scan refused: Bluetooth permission not granted');
          controller.addError(const BlePermissionDeniedException());
          await closeIfOpen();
          return;
        }

        // Distinguishes "radio is off" from "permission was refused" — on iOS
        // the latter is the only place a denial shows up, since the prompt is
        // raised natively by CoreBluetooth rather than by requestPermissions().
        // Waited for, not read: while that prompt is up the state is still
        // `unknown`, and judging it would report a radio that is merely
        // undecided as switched off (see _settledAdapterState). The state is
        // held in a local purely so it can be named in the log.
        final adapterState = await _settledAdapterState();
        if (await abandonIfCancelled()) return;
        final adapterError = adapterStateError(adapterState);
        if (adapterError != null) {
          Log.ble.warning(
            'scan refused: adapter state is ${adapterState.name}',
          );
          controller.addError(adapterError);
          await closeIfOpen();
          return;
        }

        // Re-entrancy: if a previous scan is still active, tear it down
        // cleanly before starting a new one so we don't leak its subscription
        // or leave a stale native scan running.
        final previous = _scanSubscription;
        if (previous != null) {
          Log.ble.debug('tearing down the previous scan before restarting');
          final endPrevious = _endActiveScan;
          _scanSubscription = null;
          _endActiveScan = null;
          await previous.cancel();
          await FlutterBluePlus.stopScan();
          // Close the superseded scan's stream as well: a continuous one has
          // no window to run out, so its consumer would otherwise sit on a
          // stream that can never produce anything again.
          if (endPrevious != null) await endPrevious();
        }
        if (await abandonIfCancelled()) return;

        // scanResults re-emits its latest event to every new listener, so our
        // subscription's first event is the PREVIOUS scan's last one (fbp only
        // clears it inside startScan). Capture that exact instance so it can
        // be dropped instead of resurfacing a stale device.
        final replayed = FlutterBluePlus.lastScanResults;
        final coalescer = ScanResultCoalescer();
        sub = FlutterBluePlus.scanResults.listen(
          (results) {
            if (identical(results, replayed)) return;
            // One advertisement per event (startNative asks for oneByOne), so
            // the cost of a sighting is one coalescer lookup — not a walk of
            // everything found so far, which is what fbp's default accumulated
            // list made it: O(devices) per advertisement, and in a dense room
            // that was most of the scan's UI-isolate time. The loop stays for
            // the shape of the API; it runs once.
            for (final result in results) {
              final advertisement = result.advertisementData;
              // The name on air, not the platform's cached one. CoreBluetooth
              // hands over `peripheral.name` as platformName, and that is a
              // system-wide cache: once ANY app on the phone has connected it
              // holds the GAP Device Name characteristic, and it keeps holding
              // it after the device is renamed. The advertised local name is
              // what a spec's local_name_prefix describes and what the user
              // sees on the device's own app. Fall back when the advertisement
              // carries none — plenty of peripherals only name themselves in
              // GATT.
              final advName = advertisement.advName;
              final device = coalescer.next(
                id: result.device.remoteId.str,
                name: advName.isNotEmpty ? advName : result.device.platformName,
                rssi: result.rssi,
                isConnectable: advertisement.connectable,
                // str128 rather than str: fbp's `str` abbreviates a
                // SIG-base UUID to its 16-bit form, which would never match a
                // spec's full-length service_uuids.
                serviceUuids: [
                  for (final uuid in advertisement.serviceUuids)
                    uuid.str128.toLowerCase(),
                ],
                // manufacturerData is keyed by company ID. Keep both the keys
                // (the cheap identity signal every consumer uses) and the full
                // payloads (a few specs read a real value out of them — e.g. a
                // pixel panel advertising its true resolution).
                companyIds: advertisement.manufacturerData.keys.toList(),
                manufacturerData: advertisement.manufacturerData,
                // When the advertisement was heard, not when it was processed
                // — see ScanResultCoalescer.
                seenAt: result.timeStamp,
              );
              if (device != null) controller.add(device);
            }
          },
          onError: (Object error) {
            Log.ble.error('scan stream error', error: error);
            controller.addError(error);
          },
        );
        _scanSubscription = sub;
        _endActiveScan = endScan;

        // continuousUpdates, on every scan: without it Android drops
        // same-payload advertisements and Apple platforms coalesce duplicates,
        // so a device would be reported once and then never again — leaving no
        // way to tell "still here, still broadcasting" from "switched off ten
        // minutes ago". That distinction is the whole point of `lastSeen`, and
        // it is what a scan that never ends needs in order to stay truthful.
        // The divisor keeps the resulting firehose affordable, and oneByOne
        // keeps each advertisement a single event rather than a fresh copy of
        // every result so far (see the listener above).
        Future<void> startNative() => FlutterBluePlus.startScan(
          timeout: timeout,
          continuousUpdates: true,
          continuousDivisor: continuousDivisorFor(intensity, isApple: isApple),
          oneByOne: true,
          androidScanMode: androidScanModeFor(intensity),
        );

        await startNative();
        if (await abandonIfCancelled(nativeScanStarted: true)) return;
        Log.ble.info(
          'scan started (${intensity.name}, '
          '${timeout == null ? 'continuous' : '${timeout.inSeconds}s'})',
        );

        if (timeout == null) {
          // A continuous scan has no end of its own: it runs until the consumer
          // cancels, until stopScan() is called, or until the radio goes away.
          // The first two tear this down from outside; the third is what the
          // adapter watch below is for. A bounded scan can get away without it
          // — its window ends in a few seconds regardless — but a scan that is
          // meant to run all session has to notice when Bluetooth is switched
          // off underneath it, or the screen sits there claiming to be
          // searching while the radio is dark.
          adapterSub = FlutterBluePlus.adapterState.listen((state) {
            final error = adapterStateError(state);
            if (error == null) return;
            Log.ble.warning(
              'continuous scan ended: adapter state is '
              '${state.name}',
            );
            controller.addError(error);
            unawaited(endScan());
          });
          // Keeps the platform scan real — see [continuousScanRefresh].
          //
          // Self-scheduling rather than periodic, because a failed refresh is
          // not a tick to shrug off and wait out. flutter_blue_plus stops the
          // running scan BEFORE starting the new one, and unwinds its own state
          // if the platform call then fails — so a refresh that throws leaves
          // no scan running at all, silently, while the screen still says it is
          // searching. Retrying in [continuousScanRetry] instead of a quarter
          // of an hour is the difference between a blip and a dead tab. (If the
          // cause was the radio going away, the adapter watch above has already
          // ended the scan and this timer is cancelled with it.)
          void scheduleRefresh(Duration after) {
            if (tornDown) return;
            refresh = Timer(after, () async {
              if (tornDown) return;
              Log.ble.debug('refreshing the continuous scan');
              try {
                await startNative();
                if (tornDown) {
                  // The scan ended while this restart was in flight, so the
                  // restart just revived a radio nobody is listening to. Put
                  // it back down — unless a newer scan has installed itself,
                  // in which case the radio is its business now.
                  if (_scanSubscription == null) {
                    try {
                      await FlutterBluePlus.stopScan();
                    } catch (_) {
                      // Best-effort: teardown-time cleanup must not throw.
                    }
                  }
                  return;
                }
                scheduleRefresh(continuousScanRefreshInterval);
              } catch (e) {
                if (tornDown) return;
                Log.ble.warning(
                  'continuous scan refresh failed; nothing is scanning '
                  'until the retry in '
                  '${continuousScanRetryInterval.inSeconds}s',
                  error: e,
                );
                scheduleRefresh(continuousScanRetryInterval);
              }
            });
          }

          scheduleRefresh(continuousScanRefreshInterval);
          return;
        }

        // startScan resolves once scanning has STARTED (its `timeout` only
        // arms a stop timer), so wait for the actual stop before tearing the
        // stream down — otherwise results arrive on an unwatched scan and the
        // UI sees an instant empty "done". isScanning re-emits its latest
        // value on listen, so `.first` cannot miss a stop that already
        // happened; the outer timeout keeps a missed stop event from hanging
        // the stream forever.
        try {
          await FlutterBluePlus.isScanning
              .where((scanning) => !scanning)
              .first
              .timeout(timeout + const Duration(seconds: 5));
        } on TimeoutException {
          // Degrade to ending the scan normally rather than erroring the UI.
          Log.ble.warning(
            'no scan-stopped event within '
            '${(timeout + const Duration(seconds: 5)).inSeconds}s; '
            'ending the scan anyway',
          );
        }

        Log.ble.info('scan finished: ${coalescer.deviceCount} device(s)');
        await cancelSub();
        await closeIfOpen();
      } catch (e) {
        Log.ble.error('scan failed', error: e);
        controller.addError(e);
        await cancelSub();
        await closeIfOpen();
      }
    }();

    // If the consumer cancels the stream subscription, cancel our listener and
    // (only if we still own the scan) stop the native scan so nothing is left
    // running. The decision is captured BEFORE cancelSub() mutates the shared
    // field: we stop only when our subscription is still the active one, so a
    // late cancel of an older scan can't stop a newer scan's native session.
    // This is equivalent to checking `_scanSubscription == null` after
    // cancelSub() (which nulls the field iff it still pointed at OUR sub).
    controller.onCancel = () async {
      cancelled = true;
      final stopNative = shouldStopNativeScanOnCancel(
        active: _scanSubscription,
        own: sub,
      );
      await cancelSub();
      if (stopNative) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {
          // Ignore — best-effort teardown on cancel.
        }
      }
    };

    return controller.stream;
  }

  @override
  Stream<bool> adapterReady() => FlutterBluePlus.adapterState
      // The same "only `on` is scannable" judgement adapterStateError makes;
      // reduced to a bool because the one consumer (the scan screen's
      // auto-recovery) needs "may I scan now", not which way it can't.
      .map((state) => state == BluetoothAdapterState.on)
      // fbp re-emits the latest state to every new listener, so the current
      // answer arrives first; distinct() keeps intermediate states
      // (turningOn -> on) from reading as two transitions.
      .distinct();

  @override
  Stream<bool> adapterUnauthorized() => FlutterBluePlus.adapterState
      // The other half of adapterStateError's judgement, for the one consumer
      // that needs to tell a refusal from a dark radio after the fact: a Deny
      // on the system prompt arrives here as a transition, not as the answer
      // to any scan. Same replay-then-distinct shape as adapterReady.
      .map((state) => state == BluetoothAdapterState.unauthorized)
      .distinct();

  @override
  Future<void> stopScan() async {
    Log.ble.info('scan stopped by request');
    // Claim the scan that is running NOW, before the platform call is awaited.
    // A scan() starting inside that await would otherwise install its own
    // teardown, and this stop — issued for the scan before it — would run it,
    // closing a brand new stream on behalf of an already-dead one. Same
    // ownership rule shouldStopNativeScanOnCancel applies on the cancel path.
    final end = _endActiveScan;
    final sub = _scanSubscription;
    _endActiveScan = null;
    await FlutterBluePlus.stopScan();
    if (end != null) {
      // Closes the claimed scan's stream too, so a continuous scan's consumer
      // learns it has ended instead of waiting on a stream nothing will ever
      // feed again.
      await end();
      return;
    }
    await sub?.cancel();
    if (identical(_scanSubscription, sub)) _scanSubscription = null;
  }

  /// Tears down whichever scan owns [_scanSubscription], stream and all.
  /// Registered by [scan] and invoked by [stopScan]; null when no scan is
  /// running.
  Future<void> Function()? _endActiveScan;

  @override
  Future<void> connect(String deviceId) {
    // Serialized per device, because the share-expiry decision below reads
    // the link state BEFORE its own platform call: two overlapping connects
    // to a disconnected device would otherwise both snapshot "link was
    // down", and whichever resumed second would expire the notify shares
    // the first had already installed on the (single, shared) link. Chained,
    // the second call observes the link the first one established and
    // correctly leaves its shares alone. fbp serializes the underlying
    // platform calls anyway, so this adds ordering, not latency.
    final previous = _connectChain[deviceId] ?? Future<void>.value();
    final attempt = previous.then((_) => _connectNow(deviceId));
    // The stored tail swallows the failure so one dead attempt cannot poison
    // the callers queued behind it; each caller still gets the real error
    // through its own `attempt`.
    final tail = attempt.catchError((Object _) {});
    _connectChain[deviceId] = tail;
    tail.whenComplete(() {
      if (identical(_connectChain[deviceId], tail)) {
        _connectChain.remove(deviceId);
      }
    });
    return attempt;
  }

  /// On Apple platforms, connecting to a saved device can fail before it
  /// reaches the radio, because the identifier is not a MAC address.
  ///
  /// Android's `getRemoteDevice(mac)` accepts any well-formed address, so
  /// reconnecting to something the app saved months ago always at least tries.
  /// CoreBluetooth has no such thing: the id is a system-minted per-app UUID,
  /// and `connect` resolves it with `retrievePeripheralsWithIdentifiers:`,
  /// which answers "Peripheral not found" whenever the system no longer holds
  /// a CBPeripheral for it. That happens routinely — after a Bluetooth reset
  /// or reboot for an unbonded device, or when a peripheral's random address
  /// rotated and the OS minted a new UUID.
  ///
  /// The saved-devices screen goes straight to connect() with no scan, so the
  /// user saw the raw plugin error surfaced as "move closer", which is advice
  /// that cannot work: no amount of proximity re-teaches CoreBluetooth an
  /// identifier. A short targeted scan does, because a single advertisement
  /// sighting is exactly what re-registers the peripheral with the system.
  ///
  /// Android and Linux keep the direct path — they have no such precondition,
  /// and a scan there would add seconds to every reconnect for nothing.
  Future<void> _connectResolvingAppleIdentifier(
    BluetoothDevice device,
    String deviceId,
  ) async {
    const timeout = Duration(seconds: 15);
    try {
      await device.connect(timeout: timeout);
      return;
    } catch (error) {
      if (!_isAppleUnknownPeripheral(error)) rethrow;
      Log.ble.info(
        '$deviceId is not known to CoreBluetooth; scanning for it before '
        'giving up',
      );
    }

    // One short scan filtered to this device. A sighting is enough; the
    // system registers the peripheral and the identifier resolves again.
    //
    // R-187: unless a scan is ALREADY running, in which case starting one
    // here would stop it — there is a single radio and one scan at a time.
    // The scan screen's continuous scan is the common case (a saved device
    // opened from the list while the Nearby tab is still listening), and it
    // hears every advertisement anyway, so it re-registers the peripheral
    // just as well. Waiting out the window is both correct and cheaper than
    // taking the radio away from a scan whose results a screen is showing.
    final borrowedScan = FlutterBluePlus.isScanningNow;
    if (borrowedScan) {
      Log.ble.debug(
        'a scan is already running; waiting for it to hear $deviceId rather '
        'than restarting the radio',
      );
      await Future<void>.delayed(appleRediscoveryWindow);
    } else {
      try {
        await FlutterBluePlus.startScan(
          withRemoteIds: [deviceId],
          timeout: appleRediscoveryWindow,
        );
        await FlutterBluePlus.isScanning.where((on) => !on).first;
      } catch (error) {
        Log.ble.debug('rediscovery scan for $deviceId failed: $error');
      } finally {
        await FlutterBluePlus.stopScan().catchError((Object _) {});
      }
    }

    try {
      await device.connect(timeout: timeout);
    } catch (error) {
      if (!_isAppleUnknownPeripheral(error)) rethrow;
      // Still unheard. Say the one true thing rather than "move closer":
      // the device has not advertised since the system forgot it.
      throw const BleDeviceUnheardException();
    }
  }

  /// CoreBluetooth could not resolve the identifier at all.
  ///
  /// Matched on the message because flutter_blue_plus_darwin raises this as a
  /// plain `FlutterError` with code `connect` (FlutterBluePlusPlugin.m), not
  /// as a typed error with a distinguishable code.
  bool _isAppleUnknownPeripheral(Object error) {
    if (!isApple) return false;
    return error.toString().toLowerCase().contains('peripheral not found');
  }

  Future<void> _connectNow(String deviceId) async {
    // Two lines, because the gap between them is the diagnosis: a connect can
    // sit here for the full 15s timeout. Failures surface to the UI, which
    // logs them via friendlyErrorText — logging them here too would duplicate.
    Log.ble.info('connecting to $deviceId');
    // The same gate scan() keeps, for the same reason: with the radio off the
    // platform refuses the connect with a plugin error ("bluetooth must be
    // turned on. (CBManagerStatePoweredOff)"), which the UI cannot tell from
    // a device out of range — so a Reconnect pressed after Bluetooth was
    // toggled off in Control Centre told the user to move closer. Judged
    // once the state has settled, so a saved device opened cold on iOS waits
    // for the permission prompt rather than failing underneath it.
    final adapterState = await _settledAdapterState();
    final adapterError = adapterStateError(adapterState);
    if (adapterError != null) {
      Log.ble.warning(
        'connect to $deviceId refused: adapter state is ${adapterState.name}',
      );
      throw adapterError;
    }
    final device = BluetoothDevice.fromId(deviceId);
    // Whether this call actually turns the link over. flutter_blue_plus
    // treats connect() on an already-connected device as a no-op, so a
    // second caller (a group run touching a device a screen already holds)
    // must NOT expire live notify shares — CCCD state survives because the
    // link never dropped.
    final wasConnected = device.isConnected;
    await _connectResolvingAppleIdentifier(device, deviceId);
    Log.ble.info('connected to $deviceId');
    // Track overlapping owners: the device screen and a group run can both
    // hold the same physical link, and whichever disconnects first must not
    // tear it down under the other (see disconnect()).
    _connectionClaims[deviceId] = (_connectionClaims[deviceId] ?? 0) + 1;
    _watchServicesReset(deviceId, device);
    _watchLinkDrop(deviceId, device);
    // A fresh link starts from fresh CCCD state; shares from the previous
    // one must not be inherited (see _expireNotifyShares).
    if (!wasConnected) _expireNotifyShares(deviceId);
    // The MTU decides the usable write payload (ATT MTU - 3). This is not a
    // nicety: SmartDawn's BIN (TUTU) channel does NOT reassemble fragments, so
    // each image chunk (up to ~200 B) must fit in a single write — which needs
    // a large MTU.
    //
    // R-017: nothing is requested HERE. `BluetoothDevice.connect` already
    // takes `mtu: 512` by default and asks for it itself, on Android and
    // only on Android (bluetooth_device.dart guards on Platform.isAndroid).
    // This file used to ask a second time straight afterwards, which on
    // Android is a redundant round trip on a link the user is waiting on,
    // and whose old comment described a platform error — `androidOnly` —
    // that the guarded call never raises. Apple platforms negotiate the
    // maximum on their own and report it a little after connect; [mtu]
    // waits for that.
    Log.ble.debug('mtu for $deviceId: ${device.mtuNow}');
    // flutter_blue_plus_linux never updates mtuNow from the value BlueZ
    // actually negotiates (enabling notifications already exchanged a larger
    // MTU over D-Bus), so on Linux a report still stuck at the 23-byte
    // default RIGHT AFTER CONNECTING means UNKNOWN, not tiny — flag the
    // device so mtu() answers with the 512 this connect just requested
    // (verified live against the JY25CUT curtain). Keyed on the post-connect
    // observation rather than on the platform alone: a Linux backend that
    // does report real values (the emulated test adapter today, a fixed
    // flutter_blue_plus_linux tomorrow) is never flagged, and on Android a
    // 23 is a real answer (requestMtu ran and was refused) that callers must
    // size real writes for.
    if (Platform.isLinux && device.mtuNow <= 23) {
      _mtuUnknown.add(deviceId);
    } else {
      _mtuUnknown.remove(deviceId);
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    // Last claim out tears the link down; earlier releases just let go. A
    // release with no claim at all (cleanup after a failed connect) falls
    // through to the platform disconnect, which is the desired best-effort
    // for a half-open link.
    final claims = _connectionClaims[deviceId] ?? 0;
    if (claims > 1) {
      _connectionClaims[deviceId] = claims - 1;
      Log.ble.debug(
        'disconnect($deviceId) released a claim; ${claims - 1} remain',
      );
      return;
    }
    _connectionClaims.remove(deviceId);
    Log.ble.info('disconnecting from $deviceId');
    _servicesCache.remove(deviceId);
    // Invalidate any discovery still in flight: a discoverServices whose
    // caller timed out keeps running (Future.timeout abandons, it does not
    // cancel), and letting it repopulate the cache after this clear would
    // hand the NEXT connection a stale GATT snapshot.
    _connectionGeneration[deviceId] = _generationOf(deviceId) + 1;
    _mtuUnknown.remove(deviceId);
    _expireNotifyShares(deviceId);
    unawaited(_servicesResetSubs.remove(deviceId)?.cancel());
    unawaited(_linkDropSubs.remove(deviceId)?.cancel());
    final device = BluetoothDevice.fromId(deviceId);
    try {
      await device.disconnect();
    } catch (e) {
      // disconnect() throws if the device is already disconnected; that's the
      // desired end-state, so treat it as a successful no-op.
      Log.ble.debug(
        'disconnect($deviceId) threw; already disconnected',
        error: e,
      );
    }
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) {
    final device = BluetoothDevice.fromId(deviceId);
    return device.connectionState.map(mapConnectionState);
  }

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    final services = await _loadServices(deviceId);
    // `str128`, never `toString()`. Guid.toString() is Guid.str, which
    // abbreviates a Bluetooth-base UUID to its 16-bit short form — the example
    // bulb's control service comes back as `fff0`. Specs always write UUIDs
    // out in full, so every short-form UUID handed to the matcher is one that
    // cannot match the spec describing it, and the device falls back to raw
    // GATT controls for no visible reason. The scan path already normalizes
    // this way; this puts the connected path in the same vocabulary.
    return services
        .map(
          (s) => BleDiscoveredService(
            uuid: s.uuid.str128,
            characteristics: s.characteristics
                .map(
                  (c) => BleDiscoveredCharacteristic(
                    uuid: c.uuid.str128,
                    canRead: c.properties.read,
                    canWrite:
                        c.properties.write || c.properties.writeWithoutResponse,
                    canWriteWithResponse: c.properties.write,
                    canWriteWithoutResponse: c.properties.writeWithoutResponse,
                    canNotify: c.properties.notify || c.properties.indicate,
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  /// Load GATT services for a device, caching the result so follow-up
  /// read/write/subscribe calls don't trigger a fresh discovery round-trip.
  /// The cache is invalidated in [disconnect].
  ///
  /// An empty result is retried on the [nextEmptyDiscoveryRetryDelay]
  /// schedule: right after connect the platform may not have resolved the
  /// GATT database yet (BlueZ's ServicesResolved race on Linux), and
  /// accepting that first empty answer is what produced "no services found"
  /// on devices that definitely have them.
  Future<List<BluetoothService>> _loadServices(String deviceId) async {
    final cached = _servicesCache[deviceId];
    if (cached != null) return cached;
    // Snapshot the link generation before the platform call: discovery can
    // outlive a caller's timeout AND the disconnect that follows it, and its
    // result must then be discarded, not cached into the next connection.
    final generation = _generationOf(deviceId);
    final device = BluetoothDevice.fromId(deviceId);

    // subscribeToServicesChanged: false, twice over. (1) The default (true)
    // makes fbp subscribe to the GATT Service Changed characteristic (0x2A05)
    // as part of discovery, so a peripheral that never acks that CCCD write
    // turns the whole discovery into a "setNotifyValue timed out" failure
    // after 15s. (2) On Linux that subscribe can never be confirmed at all
    // (see [isSpuriousLinuxNotifyTimeout]), making the timeout certain
    // whenever the device exposes 0x2A05. We re-discover on every connection
    // (the cache clears in [disconnect]), so nothing here relies on
    // service-changed notifications.
    final stopwatch = Stopwatch()..start();
    var attempt = 0;
    var services = await device.discoverServices(
      subscribeToServicesChanged: false,
    );
    while (services.isEmpty) {
      final delay = nextEmptyDiscoveryRetryDelay(attempt);
      if (delay == null) break;
      attempt += 1;
      Log.ble.debug(
        'discovery on $deviceId returned no services after '
        '${stopwatch.elapsedMilliseconds}ms; retry $attempt in '
        '${delay.inMilliseconds}ms (services may still be resolving)',
      );
      await Future<void>.delayed(delay);
      services = await device.discoverServices(
        subscribeToServicesChanged: false,
      );
    }

    // Only on a cache miss, so this is once per connection, not per read.
    // The elapsed time is diagnostic: a discovery that "finished" within a
    // few ms of connecting almost certainly raced service resolution rather
    // than actually talking to the device.
    if (services.isEmpty) {
      Log.ble.warning(
        'discovered 0 service(s) on $deviceId in '
        '${stopwatch.elapsedMilliseconds}ms (${attempt + 1} attempt(s)); '
        'spec matching and typed controls need discovered services',
      );
    } else {
      Log.ble.info(
        'discovered ${services.length} service(s) on $deviceId '
        'in ${stopwatch.elapsedMilliseconds}ms'
        '${attempt > 0 ? ' after ${attempt + 1} attempts' : ''}',
      );
      for (final service in services) {
        Log.ble.debug(
          '  service ${service.uuid}: '
          '${service.characteristics.length} characteristic(s) '
          '[${service.characteristics.map((c) => c.uuid).join(', ')}]',
        );
      }
    }
    // Cached in BOTH cases — but an empty result only reaches this line
    // after the full retry ladder exhausted, so it is a settled verdict for
    // this connection, not the not-yet-resolved race (the ladder absorbed
    // that). Without caching it, every later read/write/subscribe against a
    // genuinely service-less device would silently re-run the ~6s ladder
    // before failing. The cache still clears on disconnect, so a reconnect
    // gets a fresh discovery — which is also why the generation check
    // matters: a discovery that outlived a caller's timeout and the
    // disconnect after it must not resurrect a cleared cache.
    if (_generationOf(deviceId) == generation) {
      _servicesCache[deviceId] = services;
    }
    return services;
  }

  /// Monotonic per-device link generation, bumped by [disconnect]. Lets an
  /// abandoned async result (Future.timeout does not cancel the platform
  /// call) prove it belongs to the link that started it before writing any
  /// per-connection state.
  final Map<String, int> _connectionGeneration = {};

  /// Overlapping owners of one physical link, per device. fbp connections
  /// are per-device, not per-caller, so two callers (device screen + group
  /// run) connecting to the same peripheral share a link — and a late
  /// disconnect from one used to kill it under the other.
  final Map<String, int> _connectionClaims = {};

  /// The tail of each device's in-flight connect queue — error-swallowed, so
  /// the next caller chains onto "the previous attempt finished" rather than
  /// onto its failure. Entries are removed once no caller is queued; see
  /// [connect] for why connects serialize at all.
  final Map<String, Future<void>> _connectChain = {};

  int _generationOf(String deviceId) => _connectionGeneration[deviceId] ?? 0;

  /// Find a specific BLE characteristic by service and characteristic UUID.
  Future<BluetoothCharacteristic> _findCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    final services = await _loadServices(deviceId);
    final s = normalizeUuid(serviceUuid);
    final c = normalizeUuid(charUuid);
    // Same 128-bit vocabulary as discoverServices: callers hand back a UUID
    // that came from there, so both sides of this comparison have to be
    // written the same way.
    for (final service in services) {
      if (normalizeUuid(service.uuid.str128) == s) {
        for (final char in service.characteristics) {
          if (normalizeUuid(char.uuid.str128) == c) {
            return char;
          }
        }
      }
    }
    throw StateError('Characteristic $charUuid not found');
  }

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
    return _pairingAware(deviceId, () => char.read());
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
    await _pairingAware(
      deviceId,
      () => char.write(
        value,
        withoutResponse: useWriteWithoutResponse(
          canWriteWithResponse: char.properties.write,
          canWriteWithoutResponse: char.properties.writeWithoutResponse,
        ),
      ),
    );
  }

  /// Run [operation], turning a pairing refusal into something the user can act
  /// on.
  ///
  /// Two things happen on a refusal. The error becomes a
  /// [BlePairingRequiredException], so the UI says "pair this device" instead of
  /// the generic "the device did not accept that command" — that part works on
  /// every platform. And on Android a bond is requested, which is what makes
  /// the system pairing dialog appear; iOS and BlueZ raise their own prompt off
  /// the failed operation, so asking again there would be redundant at best.
  ///
  /// The bond request is deliberately NOT awaited. `createBond` resolves only
  /// once the user answers the dialog (up to 90s), and holding the read open
  /// that long would leave the screen spinning behind the prompt. Reporting the
  /// refusal immediately puts the guidance on screen while the dialog is up,
  /// and the user's retry finds a bonded link.
  Future<T> _pairingAware<T>(String deviceId, Future<T> Function() operation) {
    // Catches Object, not FlutterBluePlusException: on Linux a refused
    // subscription arrives as a raw D-Bus exception (see
    // [isPairingRequiredError]), and narrowing the catch would let exactly that
    // case through untranslated.
    return operation().onError<Object>((error, stack) {
      if (isCharacteristicSilentError(error)) {
        // Not a refusal and not a dropped link: the characteristic simply
        // never replied. Typed here so the plugin's own string does not reach
        // the screen — see [BleCharacteristicSilentException] for the real
        // device this was found on.
        Log.ble.warning('$deviceId did not answer an operation ($error)');
        throw const BleCharacteristicSilentException();
      }
      if (!isPairingRequiredError(error)) throw error;
      Log.ble.warning(
        '$deviceId refused an operation: the link is not '
        'paired ($error)',
      );
      if (Platform.isAndroid) {
        unawaited(
          BluetoothDevice.fromId(deviceId).createBond().catchError((Object e) {
            // Best-effort: already bonding, user dismissed, or the platform
            // declined. The exception below is what the user acts on.
            Log.ble.debug('bond request for $deviceId failed', error: e);
          }),
        );
      }
      // Apple platforms put the pairing prompt on screen themselves; Android
      // and BlueZ send the user to system settings. Same refusal, different
      // next step, so the message has to know which one it is on.
      throw BlePairingRequiredException.forPlatform(isApple: isApple);
    });
  }

  /// Recent raw notifications, oldest first, capped so a connect-time push
  /// survives without unbounded growth.
  ///
  /// R-020: keyed exactly like the notify share that fills it
  /// ([_notifyShareKey]) — by device, service AND characteristic, each UUID
  /// normalised. It used to key on the characteristic alone, in whatever
  /// spelling the caller passed: a device exposing the same characteristic
  /// UUID under two services (a strip with one per channel, and the vendor
  /// profiles that reuse a UUID across services) mixed both streams into one
  /// ring, so a reader asking one service got the other's frames; and a
  /// caller spelling a 16-bit UUID in full form read an empty ring beside a
  /// full one.
  final Map<String, List<List<int>>> _recentNotifications = {};
  static const int _recentNotificationsCap = 16;

  void _recordRecent(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) {
    final ring = _recentNotifications.putIfAbsent(
      _notifyShareKey(deviceId, serviceUuid, charUuid),
      () => <List<int>>[],
    );
    ring.add(List<int>.of(value));
    if (ring.length > _recentNotificationsCap) ring.removeAt(0);
  }

  @override
  List<List<int>> recentNotifications(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) =>
      _recentNotifications[_notifyShareKey(deviceId, serviceUuid, charUuid)] ??
      const [];

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    // Set when the consumer cancels while setup is still awaiting: onCancel
    // finds sub null then and can tear nothing down, so setup itself must
    // notice on its next step and stop — otherwise a listener nobody reads
    // stays attached for the rest of the connection. scan() guards the same
    // shape with its own cancelled flag.
    var cancelled = false;

    // Notify enable/disable is REFERENCE COUNTED per characteristic, shared
    // across every subscription to it (issue #29). Multiple widgets
    // legitimately subscribe to one characteristic — on an Airthings, six
    // sensor tiles plus the raw service card all decode the one combined
    // packet — and the panel's ListView disposes children scrolled out of
    // cache. An unconditional CCCD-disable on each cancel silently froze
    // every subscriber still on screen. The share below enables once for the
    // first subscriber and disables only when the last interest is released.
    final key = _notifyShareKey(deviceId, serviceUuid, charUuid);
    // Claimed in onListen, not here: a stream that is built but never
    // listened to must hold no interest (a pinned count would block the
    // CCCD disable for every real subscriber after it) and start no radio
    // work.
    _NotifyShare? share;
    var releasedInterest = false;
    // Exactly once per subscription: onCancel and setup-failure both funnel
    // through here, whichever happens (or happens first).
    Future<void> releaseInterest() async {
      final claimed = share;
      if (releasedInterest || claimed == null) return;
      releasedInterest = true;
      claimed.interest--;
      if (claimed.interest > 0) return;
      if (identical(_notifyShares[key], claimed)) _notifyShares.remove(key);
      // The share is finished either way below (dead shares return early), so
      // drop its recorder here rather than in each exit. A successor share
      // attaches its own with its own enable.
      await claimed.detachRecorder();
      // A share expired by connect/disconnect must never write into the NEXT
      // connection's CCCD state — that link's subscriptions own it now.
      if (claimed.dead) return;
      final enabled = claimed.enable;
      claimed.enable = null;
      if (enabled == null) return;
      // Disable only after the shared enable resolves: a disable overtaking
      // its own in-flight enable would leave the peripheral pushing.
      // Guarded: the device may already be disconnected, in which case
      // setNotifyValue throws — a no-op teardown is acceptable here.
      try {
        final char = await enabled;
        // While this release was parked on the in-flight enable, a successor
        // subscription may have claimed the characteristic under a fresh
        // share. Its enable is queued behind ours on fbp's mutex, so a
        // disable sent now would land LAST and silence the successor while
        // it believes itself subscribed — the very freeze the refcount
        // exists to prevent. The characteristic is theirs now; leave it on.
        if (_notifyShares.containsKey(key)) return;
        await _setNotifyValue(char, enable: false);
      } catch (_) {
        // Best-effort: ignore failures during teardown.
      }
    }

    controller.onListen = () {
      final claimed = _notifyShares.putIfAbsent(key, () => _NotifyShare());
      share = claimed;
      claimed.interest++;
      () async {
        try {
          // One CCCD enable per characteristic no matter how many cards want
          // it; later subscribers await the same future (and share its
          // error).
          claimed.enable ??= () async {
            final char = await _findCharacteristic(
              deviceId,
              serviceUuid,
              charUuid,
            );
            // Everyone may have left while the lookup ran (an empty-services
            // retry ladder alone can take ~6s). Enabling now would write a
            // CCCD — and, on a pairing-required peripheral, pop the system
            // pairing dialog — for nobody, then need undoing.
            if (claimed.dead || claimed.interest <= 0) {
              throw StateError('notify subscription abandoned before enable');
            }
            // Logged BEFORE the enable so a hang inside setNotifyValue (a
            // CCCD write the peripheral never acks) is visible as an
            // unanswered line instead of the log only ever showing successes.
            Log.ble.debug('enabling notifications for $charUuid on $deviceId');
            // Subscribing writes the CCCD, which a pairing-required
            // peripheral refuses like any other attribute access — so the
            // same translation applies, and a spec-declared sensor reports
            // "pair this device" instead of a raw GATT code.
            await _pairingAware(
              deviceId,
              () => _setNotifyValue(char, enable: true),
            );
            // Once per shared enable. The notifications themselves are
            // deliberately NOT logged — that is the tight loop this logging
            // must stay out of.
            Log.ble.debug('notifications enabled for $charUuid on $deviceId');
            // Fill the recent-notification ring from HERE — once per share,
            // not once per subscriber. Every subscriber listens to the same
            // broadcast onValueReceived, so recording in each of them would
            // enter one physical notification N times and evict the buffer N
            // times faster: with six sensor tiles on a characteristic, the
            // 16-deep ring would hold under three real pushes. Torn down
            // with the share in releaseInterest/_expireNotifyShares.
            claimed.recorder ??= char.onValueReceived.listen(
              (value) => _recordRecent(deviceId, serviceUuid, charUuid, value),
            );
            return char;
          }();
          final char = await claimed.enable!;
          if (cancelled) return; // onCancel already released this interest.
          // Use onValueReceived rather than lastValueStream: the latter
          // replays the last cached value on listen, which would surface a
          // stale reading as if it were a fresh notification. onValueReceived
          // only emits genuinely fresh reads/notifications.
          sub = char.onValueReceived.listen(
            (value) => controller.add(value),
            onError: (Object error) => controller.addError(error),
            onDone: () async {
              if (!controller.isClosed) await controller.close();
            },
          );
        } catch (e) {
          controller.addError(e);
          if (!controller.isClosed) await controller.close();
          // A failed setup holds no interest; the last release drops the
          // share so the next subscriber retries the enable instead of
          // inheriting this failure forever.
          await releaseInterest();
        }
      }();
    };

    controller.onCancel = () async {
      cancelled = true;
      try {
        await sub?.cancel();
      } catch (_) {
        // Ignore — a throw from cancel() must not prevent the interest
        // release (and its last-subscriber CCCD disable) below from running.
      }
      sub = null;
      await releaseInterest();
    };

    return controller.stream;
  }

  /// Shared notify state per characteristic — see [subscribeCharacteristic].
  final Map<String, _NotifyShare> _notifyShares = {};

  /// One per connected device: the platform's "services changed" events.
  final Map<String, StreamSubscription<void>> _servicesResetSubs = {};

  /// One per connected device: the platform's connection state, watched so a
  /// link that drops without anyone calling disconnect still releases its
  /// claims ([_watchLinkDrop]).
  final Map<String, StreamSubscription<BluetoothConnectionState>>
  _linkDropSubs = {};

  /// Drop the cached GATT table when the peripheral republishes it.
  ///
  /// `subscribeToServicesChanged: false` in [_loadServices] keeps fbp from
  /// writing the Service Changed CCCD itself, but on Apple platforms the
  /// event arrives anyway: CoreBluetooth subscribes on the app's behalf and
  /// delivers `peripheral:didModifyServices:`, which the darwin plugin
  /// forwards as `OnServicesReset` and fbp uses to clear ITS cache. Ours
  /// was cleared only in [disconnect], so a peripheral that changes its
  /// table mid-connection — after pairing completes, or on a DFU switch —
  /// left [_findCharacteristic] walking a stale list: characteristics that
  /// only exist after the change were "not found" until the user
  /// disconnected by hand. Treated like a link turnover: the generation
  /// moves so an in-flight discovery cannot repopulate the cache with the
  /// old table, and notify shares expire because their handles are gone.
  /// Forget everything tied to a link that is no longer up.
  ///
  /// R-013: claims are a count of app-side owners, but the LINK can go away
  /// without any of them letting go — the device is unplugged, walks out of
  /// range, or resets. The count then survived into the next connect, so the
  /// first `disconnect()` after reconnecting only decremented an inherited
  /// claim and never reached the platform: the radio stayed connected to a
  /// device the app believed it had released, and the user's "disconnect"
  /// did nothing until they pressed it as many times as the link had been
  /// lost. Watched rather than inferred, because only the platform knows.
  void _watchLinkDrop(String deviceId, BluetoothDevice device) {
    if (_linkDropSubs.containsKey(deviceId)) return;
    _linkDropSubs[deviceId] = device.connectionState.listen((state) {
      if (state != BluetoothConnectionState.disconnected) return;
      if (!_connectionClaims.containsKey(deviceId)) return;
      Log.ble.info(
        '$deviceId dropped the link; releasing '
        '${_connectionClaims[deviceId]} claim(s)',
      );
      _connectionClaims.remove(deviceId);
      _servicesCache.remove(deviceId);
      _connectionGeneration[deviceId] = _generationOf(deviceId) + 1;
      _mtuUnknown.remove(deviceId);
      _expireNotifyShares(deviceId);
    }, onError: (Object e) => Log.ble.debug('link watch $deviceId: $e'));
  }

  void _watchServicesReset(String deviceId, BluetoothDevice device) {
    if (_servicesResetSubs.containsKey(deviceId)) return;
    _servicesResetSubs[deviceId] = device.onServicesReset.listen(
      (_) {
        Log.ble.info(
          '$deviceId changed its services; rediscovering on next use',
        );
        _servicesCache.remove(deviceId);
        _connectionGeneration[deviceId] = _generationOf(deviceId) + 1;
        _expireNotifyShares(deviceId);
      },
      onError: (Object e) {
        Log.ble.debug('services-reset stream for $deviceId failed: $e');
      },
    );
  }

  String _notifyShareKey(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) => '$deviceId|${normalizeUuid(serviceUuid)}|${normalizeUuid(charUuid)}';

  /// Detach every notify share for [deviceId], marking them dead, and drop
  /// what those shares buffered.
  ///
  /// Called when the device's link turns over (connect and disconnect both):
  /// CCCD state does not survive a connection, so surviving shares would let
  /// a subscriber from the previous link skip the enable on the new one — or
  /// a late cancel from the old link disable notifications under the new
  /// link's subscribers.
  ///
  /// The recent-notification rings are cleared HERE, with the shares that
  /// filled them, because they have the same lifetime: [recentNotifications]
  /// promises what was seen on THIS connection. Clearing only in disconnect()
  /// missed the case that matters most — a dropped link, where nothing calls
  /// disconnect() and the reconnect would hand the next link the previous
  /// one's pushes.
  void _expireNotifyShares(String deviceId) {
    final prefix = '$deviceId|';
    _recentNotifications.removeWhere((key, _) => key.startsWith(prefix));
    _notifyShares.removeWhere((key, share) {
      if (!key.startsWith(prefix)) return false;
      share.dead = true;
      // The stream this recorder is on belongs to the old link. Detaching is
      // fire-and-forget: the callers of this are sync, and a cancel that
      // hangs on a vanished device must not stall connect/disconnect.
      unawaited(share.detachRecorder());
      return true;
    });
  }

  /// Devices whose connect left mtuNow at the 23-byte default on a platform
  /// whose backend is known not to report the negotiated value (Linux/BlueZ)
  /// — see the flagging logic in [connect]. For these, [mtu] answers with
  /// the 512 the connect requested rather than the meaningless default.
  final Set<String> _mtuUnknown = {};

  /// How long [mtu] waits on Apple platforms for the negotiated value.
  ///
  /// iOS reports the MTU a few ticks after connect resolves — the darwin
  /// plugin polls `maximumWriteValueLengthForType` on a 25 ms timer — so a
  /// caller sizing its writes straight after connect (the Rabbit Air client
  /// does) read the 23-byte default and split every frame into 18-byte
  /// chunks for the life of the link. Two seconds is far above the poll and
  /// well below anything a user notices; a link that never reports keeps
  /// the default, which is slow but correct.
  @visibleForTesting
  static Duration appleMtuSettle = const Duration(seconds: 2);

  @override
  Future<int> mtu(String deviceId) async {
    final device = BluetoothDevice.fromId(deviceId);
    var reported = device.mtuNow;
    if (reported <= 23 && isApple) {
      reported = await device.mtu
          .firstWhere((m) => m > 23)
          .timeout(appleMtuSettle, onTimeout: () => device.mtuNow);
    }
    // The one platform quirk in what "reported" means lives here, next to
    // the requestMtu call that owns the platform knowledge, so every caller
    // sizing writes gets the same answer — see connect() for why a flagged
    // device's stuck default reads as "the 512 we requested".
    if (reported <= 23 && _mtuUnknown.contains(deviceId)) return 512;
    return reported;
  }

  /// Read the connection's RSSI, rejecting values that are a backend's
  /// stand-in for "no reading" rather than a signal strength.
  ///
  /// The check is not padding. flutter_blue_plus_linux answers this from
  /// BlueZ's cached *advertisement* RSSI property and reports success with
  /// `rssi: 0` when that property is absent — which it is for a connected
  /// peripheral, since it stopped advertising — and the Android/Darwin
  /// plugins forward a controller-reported 127 (the SIG "RSSI unavailable"
  /// sentinel) with a success status. Passing either through would render as
  /// a confident "≈ 0.0 m / Right here" forever, because a *successful* read
  /// resets the caller's failure counter and the signal-lost path is never
  /// reached. Throwing routes them into that path instead.
  ///
  /// The wait is also bounded well below fbp's 15s default: a once-a-second
  /// poll that blocks for fifteen seconds has stopped being a live readout,
  /// and each read holds fbp's process-wide BLE mutex while it waits.
  @override
  Future<int> readRssi(String deviceId) async {
    final rssi = await BluetoothDevice.fromId(
      deviceId,
    ).readRssi(timeout: rssiReadTimeoutSeconds);
    if (!isPlausibleRssi(rssi)) {
      throw StateError('implausible RSSI $rssi dBm for $deviceId');
    }
    return rssi;
  }

  /// Enable/disable notifications, tolerating the Linux backend's spurious
  /// confirmation timeout (see [isSpuriousLinuxNotifyTimeout]: the
  /// subscription is live by the time it fires).
  ///
  /// On Linux the wait is also shortened: the confirmation event cannot
  /// arrive from the current backend, so the default 15s would be pure dead
  /// time before every (working) subscription. 3s still leaves room for a
  /// future fixed backend to confirm for real.
  Future<void> _setNotifyValue(
    BluetoothCharacteristic char, {
    required bool enable,
  }) async {
    final isLinux = Platform.isLinux;
    try {
      await char.setNotifyValue(enable, timeout: isLinux ? 3 : 15);
    } catch (e) {
      if (!isSpuriousLinuxNotifyTimeout(e, isLinux: isLinux)) rethrow;
      Log.ble.warning(
        'treating setNotifyValue(${char.uuid}, $enable) confirmation '
        'timeout as success: the Linux backend cannot confirm CCCD writes '
        'but has already applied the change',
      );
    }
  }
}

/// Shared notify-enable state for one characteristic on one device — the
/// reference count behind [RealBleService.subscribeCharacteristic]. One
/// exists per (device, service, characteristic) while any subscription is
/// alive; the CCCD is written once on the way up and once on the way down.
class _NotifyShare {
  /// Live subscriptions that want notifications on. The disable is sent only
  /// when this drains to zero.
  int interest = 0;

  /// The one enable in flight (or completed) for every current subscriber.
  /// Cleared by the last release, so a later subscriber retries a failed
  /// enable instead of inheriting its error forever.
  Future<BluetoothCharacteristic>? enable;

  /// Set when the link this share belongs to turned over. A dead share never
  /// writes the CCCD again: the next connection's subscriptions own it.
  bool dead = false;

  /// The one listener feeding this characteristic's recent-notification ring,
  /// attached with the shared enable — see [RealBleService.recentNotifications].
  ///
  /// Cancelled by [detachRecorder], which every path that drops this share
  /// funnels through; the lint only knows how to see a cancel in the function
  /// that opened the subscription.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? recorder;

  /// Stop recording for this share. Idempotent, and tolerant of a cancel that
  /// throws: a recorder left attached would keep filling the ring for a link
  /// nobody is subscribed to any more.
  Future<void> detachRecorder() async {
    final attached = recorder;
    recorder = null;
    if (attached == null) return;
    try {
      await attached.cancel();
    } catch (_) {
      // Best-effort: the device may already be gone.
    }
  }
}
