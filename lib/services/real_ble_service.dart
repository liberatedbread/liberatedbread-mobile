// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart' show listEquals;
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
/// Extracted as a pure top-level function so the re-entrancy guard can be
/// unit-tested without a real Bluetooth adapter.
bool shouldStopNativeScanOnCancel({
  required Object? active,
  required Object? own,
}) =>
    active == null || identical(active, own);

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
}) =>
    !canWriteWithResponse && canWriteWithoutResponse;

/// Per-scan coalescing of flutter_blue_plus scan batches.
///
/// fbp's `scanResults` stream carries the FULL accumulated result list on
/// every event, so forwarding each batch verbatim would re-emit every known
/// device on every advertisement — constantly refreshing `discoveredAt` and
/// flooding the consumer. [next] returns an [IoTDevice] only when the device
/// is new to this scan or something about it changed (so rssi updates still
/// flow to the DeviceManager), preserving the first-seen `discoveredAt`
/// for known ids; it returns null for an unchanged entry.
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
  }) {
    final prev = _emitted[id];
    // Reject before constructing: this runs for every device in every
    // advertisement batch, and the common case is "nothing changed". The field
    // list mirrors IoTDevice.hasSameIdentity plus the two mutable fields.
    if (prev != null &&
        prev.rssi == rssi &&
        prev.isConnectable == isConnectable &&
        prev.name == name &&
        listEquals(prev.serviceUuids, serviceUuids) &&
        listEquals(prev.companyIds, companyIds)) {
      return null;
    }
    final device = IoTDevice(
      id: id,
      name: name,
      rssi: rssi,
      isConnectable: isConnectable,
      discoveredAt: prev?.discoveredAt ?? DateTime.now(),
      serviceUuids: serviceUuids,
      companyIds: companyIds,
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

/// Real BLE implementation using flutter_blue_plus.
class RealBleService implements BleService {
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  final Map<String, List<BluetoothService>> _servicesCache = {};

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
    // which adapterStateError maps back to BlePermissionDeniedException.
    return true;
  }

  @override
  Stream<IoTDevice> scan({
    Duration timeout =
        const Duration(seconds: AppConstants.defaultScanDuration),
  }) {
    final controller = StreamController<IoTDevice>();

    // Subscription local to this scan invocation. Kept local (rather than
    // relying solely on the shared _scanSubscription field) so a concurrent
    // scan() call can't orphan or cancel the wrong subscription.
    StreamSubscription<List<ScanResult>>? sub;

    Future<void> closeIfOpen() async {
      if (!controller.isClosed) await controller.close();
    }

    Future<void> cancelSub() async {
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
      }
      sub = null;
    }

    () async {
      try {
        final granted = await requestPermissions();
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
        // The state is held in a local purely so it can be named in the log.
        final adapterState = await FlutterBluePlus.adapterState.first;
        final adapterError = adapterStateError(adapterState);
        if (adapterError != null) {
          Log.ble
              .warning('scan refused: adapter state is ${adapterState.name}');
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
          _scanSubscription = null;
          await previous.cancel();
          await FlutterBluePlus.stopScan();
        }

        // scanResults re-emits its latest list to every new listener, so our
        // subscription's first event is the PREVIOUS scan's accumulated
        // results (fbp only clears them inside startScan). Capture that exact
        // instance so it can be dropped instead of resurfacing stale devices.
        final replayed = FlutterBluePlus.lastScanResults;
        final coalescer = ScanResultCoalescer();
        sub = FlutterBluePlus.scanResults.listen(
          (results) {
            if (identical(results, replayed)) return;
            for (final result in results) {
              final advertisement = result.advertisementData;
              final device = coalescer.next(
                id: result.device.remoteId.str,
                name: result.device.platformName,
                rssi: result.rssi,
                isConnectable: advertisement.connectable,
                // str128 rather than str: fbp's `str` abbreviates a
                // SIG-base UUID to its 16-bit form, which would never match a
                // spec's full-length service_uuids.
                serviceUuids: [
                  for (final uuid in advertisement.serviceUuids)
                    uuid.str128.toLowerCase(),
                ],
                // manufacturerData is keyed by company ID. A device may carry
                // several records; the payloads are not read here, only who
                // they claim to be from.
                companyIds: advertisement.manufacturerData.keys.toList(),
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

        await FlutterBluePlus.startScan(timeout: timeout);
        Log.ble.info('scan started (timeout ${timeout.inSeconds}s)');

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
          Log.ble.warning('no scan-stopped event within '
              '${(timeout + const Duration(seconds: 5)).inSeconds}s; '
              'ending the scan anyway');
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
      final stopNative =
          shouldStopNativeScanOnCancel(active: _scanSubscription, own: sub);
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
  Future<void> stopScan() async {
    Log.ble.info('scan stopped by request');
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  @override
  Future<void> connect(String deviceId) async {
    // Two lines, because the gap between them is the diagnosis: a connect can
    // sit here for the full 15s timeout. Failures surface to the UI, which
    // logs them via friendlyErrorText — logging them here too would duplicate.
    Log.ble.info('connecting to $deviceId');
    final device = BluetoothDevice.fromId(deviceId);
    await device.connect(timeout: const Duration(seconds: 15));
    Log.ble.info('connected to $deviceId');
    // The MTU decides the usable write payload (ATT MTU - 3), which
    // fragmented protocols (e.g. SmartDawn's DDP framing) depend on. fbp
    // requests 512 on Android during connect; other platforms negotiate on
    // their own and may just report the 23-byte default here.
    Log.ble.debug('mtu for $deviceId: ${device.mtuNow}');
  }

  @override
  Future<void> disconnect(String deviceId) async {
    Log.ble.info('disconnecting from $deviceId');
    _servicesCache.remove(deviceId);
    final device = BluetoothDevice.fromId(deviceId);
    try {
      await device.disconnect();
    } catch (e) {
      // disconnect() throws if the device is already disconnected; that's the
      // desired end-state, so treat it as a successful no-op.
      Log.ble
          .debug('disconnect($deviceId) threw; already disconnected', error: e);
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
        .map((s) => BleDiscoveredService(
              uuid: s.uuid.str128,
              characteristics: s.characteristics
                  .map((c) => BleDiscoveredCharacteristic(
                        uuid: c.uuid.str128,
                        canRead: c.properties.read,
                        canWrite: c.properties.write ||
                            c.properties.writeWithoutResponse,
                        canWriteWithResponse: c.properties.write,
                        canWriteWithoutResponse:
                            c.properties.writeWithoutResponse,
                        canNotify: c.properties.notify || c.properties.indicate,
                      ))
                  .toList(),
            ))
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
    var services =
        await device.discoverServices(subscribeToServicesChanged: false);
    while (services.isEmpty) {
      final delay = nextEmptyDiscoveryRetryDelay(attempt);
      if (delay == null) break;
      attempt += 1;
      Log.ble.debug('discovery on $deviceId returned no services after '
          '${stopwatch.elapsedMilliseconds}ms; retry $attempt in '
          '${delay.inMilliseconds}ms (services may still be resolving)');
      await Future<void>.delayed(delay);
      services =
          await device.discoverServices(subscribeToServicesChanged: false);
    }

    // Only on a cache miss, so this is once per connection, not per read.
    // The elapsed time is diagnostic: a discovery that "finished" within a
    // few ms of connecting almost certainly raced service resolution rather
    // than actually talking to the device.
    if (services.isEmpty) {
      Log.ble.warning('discovered 0 service(s) on $deviceId in '
          '${stopwatch.elapsedMilliseconds}ms (${attempt + 1} attempt(s)); '
          'spec matching and typed controls need discovered services');
    } else {
      Log.ble.info('discovered ${services.length} service(s) on $deviceId '
          'in ${stopwatch.elapsedMilliseconds}ms'
          '${attempt > 0 ? ' after ${attempt + 1} attempts' : ''}');
      for (final service in services) {
        Log.ble.debug('  service ${service.uuid}: '
            '${service.characteristics.length} characteristic(s) '
            '[${service.characteristics.map((c) => c.uuid).join(', ')}]');
      }
    }
    // Cached in BOTH cases — but an empty result only reaches this line
    // after the full retry ladder exhausted, so it is a settled verdict for
    // this connection, not the not-yet-resolved race (the ladder absorbed
    // that). Without caching it, every later read/write/subscribe against a
    // genuinely service-less device would silently re-run the ~6s ladder
    // before failing. The cache still clears on disconnect, so a reconnect
    // gets a fresh discovery.
    _servicesCache[deviceId] = services;
    return services;
  }

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
      if (!isPairingRequiredError(error)) throw error;
      Log.ble.warning('$deviceId refused an operation: the link is not '
          'paired ($error)');
      if (Platform.isAndroid) {
        unawaited(
          BluetoothDevice.fromId(deviceId).createBond().catchError((Object e) {
            // Best-effort: already bonding, user dismissed, or the platform
            // declined. The exception below is what the user acts on.
            Log.ble.debug('bond request for $deviceId failed', error: e);
          }),
        );
      }
      throw const BlePairingRequiredException();
    });
  }

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    // The characteristic we enabled notifications on, captured so onCancel can
    // disable them again. Null until setNotifyValue(true) succeeds.
    BluetoothCharacteristic? notifyingChar;

    () async {
      try {
        final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
        // Logged BEFORE the enable so a hang inside setNotifyValue (a CCCD
        // write the peripheral never acks) is visible as an unanswered line
        // instead of the log only ever showing successes.
        Log.ble.debug('enabling notifications for $charUuid on $deviceId');
        // Subscribing writes the CCCD, which a pairing-required peripheral
        // refuses like any other attribute access — so the same translation
        // applies, and a spec-declared sensor reports "pair this device"
        // instead of a raw GATT code.
        await _pairingAware(
            deviceId, () => _setNotifyValue(char, enable: true));
        // Once per subscription. The notifications themselves are deliberately
        // NOT logged — that is the tight loop this logging must stay out of.
        Log.ble.debug('notifications enabled for $charUuid on $deviceId');
        notifyingChar = char;
        // Use onValueReceived rather than lastValueStream: the latter replays
        // the last cached value on listen, which would surface a stale reading
        // as if it were a fresh notification. onValueReceived only emits
        // genuinely fresh reads/notifications.
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
      }
    }();

    controller.onCancel = () async {
      try {
        await sub?.cancel();
      } catch (_) {
        // Ignore — a throw from cancel() must not prevent the
        // setNotifyValue(false) teardown below from running.
      }
      sub = null;
      // Disable notifications on the peripheral so it stops pushing updates.
      // Guarded: the device may already be disconnected, in which case
      // setNotifyValue throws — a no-op teardown is acceptable here.
      final char = notifyingChar;
      notifyingChar = null;
      if (char != null) {
        try {
          await _setNotifyValue(char, enable: false);
        } catch (_) {
          // Best-effort: ignore failures during teardown.
        }
      }
    };

    return controller.stream;
  }

  @override
  Future<int> mtu(String deviceId) async =>
      BluetoothDevice.fromId(deviceId).mtuNow;

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
    final rssi = await BluetoothDevice.fromId(deviceId)
        .readRssi(timeout: rssiReadTimeoutSeconds);
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
          'but has already applied the change');
    }
  }
}
