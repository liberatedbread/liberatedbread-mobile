// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';

void main() {
  group('mapConnectionState', () {
    test('connected maps through', () {
      expect(
        mapConnectionState(BluetoothConnectionState.connected),
        BleConnectionState.connected,
      );
    });

    test('disconnected maps through', () {
      expect(
        mapConnectionState(BluetoothConnectionState.disconnected),
        BleConnectionState.disconnected,
      );
    });

    test('connecting maps to connecting (not collapsed to disconnected)', () {
      expect(
        // ignore: deprecated_member_use
        mapConnectionState(BluetoothConnectionState.connecting),
        BleConnectionState.connecting,
      );
    });

    test('disconnecting maps to disconnecting (not collapsed to disconnected)',
        () {
      expect(
        // ignore: deprecated_member_use
        mapConnectionState(BluetoothConnectionState.disconnecting),
        BleConnectionState.disconnecting,
      );
    });
  });

  group('useWriteWithoutResponse (write-mode selection)', () {
    test('with-response only -> use response (false)', () {
      expect(
        useWriteWithoutResponse(
            canWriteWithResponse: true, canWriteWithoutResponse: false),
        isFalse,
      );
    });

    test('without-response only -> use without-response (true)', () {
      // The regression: control chars that are write-without-response ONLY must
      // not be sent a with-response write.
      expect(
        useWriteWithoutResponse(
            canWriteWithResponse: false, canWriteWithoutResponse: true),
        isTrue,
      );
    });

    test('both modes -> prefer with-response (false)', () {
      expect(
        useWriteWithoutResponse(
            canWriteWithResponse: true, canWriteWithoutResponse: true),
        isFalse,
      );
    });

    test('neither mode -> default to with-response (false)', () {
      expect(
        useWriteWithoutResponse(
            canWriteWithResponse: false, canWriteWithoutResponse: false),
        isFalse,
      );
    });
  });

  group('ScanResultCoalescer (fbp full-list batch dedupe)', () {
    test('first sighting of a device is emitted', () {
      final coalescer = ScanResultCoalescer();
      final device = coalescer.next(
          id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true);
      expect(device, isNotNull);
      expect(device!.id, 'AA');
      expect(device.rssi, -50);
    });

    test('an unchanged re-delivery (fbp accumulated list) is suppressed', () {
      final coalescer = ScanResultCoalescer();
      coalescer.next(id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true);
      expect(
        coalescer.next(id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true),
        isNull,
      );
    });

    test('an rssi change re-emits with the first-seen discoveredAt', () {
      final coalescer = ScanResultCoalescer();
      final first = coalescer.next(
          id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true)!;
      final updated = coalescer.next(
          id: 'AA', name: 'Bulb', rssi: -42, isConnectable: true);
      expect(updated, isNotNull);
      expect(updated!.rssi, -42);
      // The device did not become "newly discovered" by advertising again.
      expect(updated.discoveredAt, first.discoveredAt);
    });

    test('a name change re-emits (late scan-response name)', () {
      final coalescer = ScanResultCoalescer();
      coalescer.next(id: 'AA', name: '', rssi: -50, isConnectable: true);
      final updated = coalescer.next(
          id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true);
      expect(updated, isNotNull);
      expect(updated!.name, 'Bulb');
    });

    test('devices are tracked independently by id', () {
      final coalescer = ScanResultCoalescer();
      coalescer.next(id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true);
      expect(
        coalescer.next(id: 'BB', name: 'Bulb', rssi: -50, isConnectable: true),
        isNotNull,
      );
    });
  });

  group('shouldStopNativeScanOnCancel (N1 re-entrancy guard)', () {
    // Distinct objects stand in for scan subscriptions; identity is what the
    // guard compares.
    final ownSub = Object();
    final newerSub = Object();

    test('stops when our sub is still the active one', () {
      expect(
        shouldStopNativeScanOnCancel(active: ownSub, own: ownSub),
        isTrue,
      );
    });

    test('stops when the active field was already cleared (normal completion)',
        () {
      expect(
        shouldStopNativeScanOnCancel(active: null, own: ownSub),
        isTrue,
      );
    });

    test('does NOT stop when a newer scan has replaced us', () {
      // Late cancel of scan A must not stop scan B's native session.
      expect(
        shouldStopNativeScanOnCancel(active: newerSub, own: ownSub),
        isFalse,
      );
    });
  });
}
