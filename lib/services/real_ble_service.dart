// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/constants.dart';
import '../core/error_text.dart';
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
/// is new to this scan or its rssi/name/connectable changed (so rssi updates
/// still flow to the DeviceManager), preserving the first-seen `discoveredAt`
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
  }) {
    final prev = _emitted[id];
    if (prev != null &&
        prev.rssi == rssi &&
        prev.name == name &&
        prev.isConnectable == isConnectable) {
      return null;
    }
    final device = IoTDevice(
      id: id,
      name: name,
      rssi: rssi,
      isConnectable: isConnectable,
      discoveredAt: prev?.discoveredAt ?? DateTime.now(),
    );
    _emitted[id] = device;
    return device;
  }
}

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
              final device = coalescer.next(
                id: result.device.remoteId.str,
                name: result.device.platformName,
                rssi: result.rssi,
                isConnectable: result.advertisementData.connectable,
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
    return services
        .map((s) => BleDiscoveredService(
              uuid: s.uuid.toString(),
              characteristics: s.characteristics
                  .map((c) => BleDiscoveredCharacteristic(
                        uuid: c.uuid.toString(),
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
  Future<List<BluetoothService>> _loadServices(String deviceId) async {
    final cached = _servicesCache[deviceId];
    if (cached != null) return cached;
    final device = BluetoothDevice.fromId(deviceId);
    final services = await device.discoverServices();
    // Only on a cache miss, so this is once per connection, not per read.
    Log.ble.info('discovered ${services.length} service(s) on $deviceId');
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
    for (final service in services) {
      if (normalizeUuid(service.uuid.toString()) == s) {
        for (final char in service.characteristics) {
          if (normalizeUuid(char.uuid.toString()) == c) {
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
    return char.read();
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
    await char.write(
      value,
      withoutResponse: useWriteWithoutResponse(
        canWriteWithResponse: char.properties.write,
        canWriteWithoutResponse: char.properties.writeWithoutResponse,
      ),
    );
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
        await char.setNotifyValue(true);
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
          await char.setNotifyValue(false);
        } catch (_) {
          // Best-effort: ignore failures during teardown.
        }
      }
    };

    return controller.stream;
  }
}
