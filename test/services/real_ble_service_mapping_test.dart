// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

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

  group('adapterStateError (F1: iOS permission denial vs radio off)', () {
    test('on -> no error, scanning may proceed', () {
      expect(adapterStateError(BluetoothAdapterState.on), isNull);
    });

    test('unauthorized -> permission denied, NOT "Bluetooth is off"', () {
      // The regression this pins: on iOS the system Bluetooth prompt is raised
      // natively by CoreBluetooth on first scan, so a refusal never comes back
      // through requestPermissions() — it arrives here, as `unauthorized`.
      // Reporting that as BleUnavailableException would tell the user to turn
      // on a radio that is already on, with no path to the real fix.
      final error = adapterStateError(BluetoothAdapterState.unauthorized);
      expect(error, isA<BlePermissionDeniedException>());
      expect(error, isNot(isA<BleUnavailableException>()));
      expect(error!.message.toLowerCase(), contains('permission'));
    });

    test('off -> radio unavailable', () {
      final error = adapterStateError(BluetoothAdapterState.off);
      expect(error, isA<BleUnavailableException>());
      expect(error!.message.toLowerCase(), contains('turned off'));
    });

    test('every other non-on state keeps the radio-unavailable treatment', () {
      // Behaviour-preserving: before the unauthorized case was split out, ANY
      // state other than `on` produced BleUnavailableException. Only
      // `unauthorized` changed.
      for (final state in const [
        BluetoothAdapterState.unknown,
        BluetoothAdapterState.unavailable,
        BluetoothAdapterState.turningOn,
        BluetoothAdapterState.turningOff,
        BluetoothAdapterState.off,
      ]) {
        expect(
          adapterStateError(state),
          isA<BleUnavailableException>(),
          reason: '$state should map to BleUnavailableException',
        );
      }
    });

    test('every adapter state is mapped; only `on` is scannable', () {
      // Guards a future flutter_blue_plus adding an enum member: the switch is
      // exhaustive, so a new state would fail to compile rather than silently
      // fall through to "scanning is fine".
      for (final state in BluetoothAdapterState.values) {
        expect(
          adapterStateError(state) == null,
          state == BluetoothAdapterState.on,
          reason: '$state nullability should match "is it `on`"',
        );
      }
    });
  });

  group('nextEmptyDiscoveryRetryDelay (BlueZ ServicesResolved race)', () {
    test('first retry is quick, so the common fast-resolve case barely waits',
        () {
      final delay = nextEmptyDiscoveryRetryDelay(0);
      expect(delay, isNotNull);
      expect(delay!, lessThanOrEqualTo(const Duration(milliseconds: 500)));
    });

    test('delays never shrink across the schedule', () {
      var attempt = 0;
      var previous = Duration.zero;
      while (true) {
        final delay = nextEmptyDiscoveryRetryDelay(attempt);
        if (delay == null) break;
        expect(delay, greaterThanOrEqualTo(previous),
            reason: 'attempt $attempt must not back off less than the last');
        previous = delay;
        attempt++;
      }
      expect(attempt, greaterThan(0), reason: 'there must be retries at all');
    });

    test('the schedule ends: a genuinely empty device is accepted as final',
        () {
      // Walk past the schedule and require null from then on — the discovery
      // loop treats null as "stop retrying", so a schedule that never ends
      // would pin the Discovering screen open forever.
      var attempt = 0;
      while (nextEmptyDiscoveryRetryDelay(attempt) != null) {
        attempt++;
        expect(attempt, lessThan(100), reason: 'schedule must terminate');
      }
      expect(nextEmptyDiscoveryRetryDelay(attempt + 1), isNull);
    });

    test(
        'total wait is a few seconds: enough for BlueZ, short enough for a '
        'human watching the Discovering screen', () {
      var total = Duration.zero;
      for (var attempt = 0;; attempt++) {
        final delay = nextEmptyDiscoveryRetryDelay(attempt);
        if (delay == null) break;
        total += delay;
      }
      // ServicesResolved normally lands well under 2s after connect; the
      // budget covers slow peripherals with margin.
      expect(total, greaterThanOrEqualTo(const Duration(seconds: 2)));
      expect(total, lessThanOrEqualTo(const Duration(seconds: 10)));
    });
  });

  group('isSpuriousLinuxNotifyTimeout (Linux CCCD confirmation quirk)', () {
    FlutterBluePlusException fbpError(String function, FbpErrorCode code) =>
        FlutterBluePlusException(
          ErrorPlatform.fbp,
          function,
          code.index,
          'Timed out after 3s',
        );

    test('setNotifyValue timeout on Linux is tolerated', () {
      expect(
        isSpuriousLinuxNotifyTimeout(
          fbpError('setNotifyValue', FbpErrorCode.timeout),
          isLinux: true,
        ),
        isTrue,
      );
    });

    test('the identical timeout on other platforms still fails the subscribe',
        () {
      // On Android/iOS the CCCD confirmation event is real, so a timeout
      // means the peripheral truly never acked — that must surface.
      expect(
        isSpuriousLinuxNotifyTimeout(
          fbpError('setNotifyValue', FbpErrorCode.timeout),
          isLinux: false,
        ),
        isFalse,
      );
    });

    test('a timeout from a different fbp call is not swallowed', () {
      expect(
        isSpuriousLinuxNotifyTimeout(
          fbpError('discoverServices', FbpErrorCode.timeout),
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('a non-timeout setNotifyValue failure is not swallowed', () {
      expect(
        isSpuriousLinuxNotifyTimeout(
          fbpError('setNotifyValue', FbpErrorCode.deviceIsDisconnected),
          isLinux: true,
        ),
        isFalse,
      );
    });

    test('non-fbp errors are never swallowed', () {
      expect(
        isSpuriousLinuxNotifyTimeout(
          TimeoutException('setNotifyValue', const Duration(seconds: 3)),
          isLinux: true,
        ),
        isFalse,
      );
      expect(
        isSpuriousLinuxNotifyTimeout(StateError('boom'), isLinux: true),
        isFalse,
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

    test('deviceCount counts distinct devices, not advertisements', () {
      // Feeds the "scan finished: N device(s)" log line, so it must count
      // devices rather than the fbp batches they arrived in.
      final coalescer = ScanResultCoalescer();
      expect(coalescer.deviceCount, 0);

      coalescer.next(id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true);
      coalescer.next(id: 'AA', name: 'Bulb', rssi: -50, isConnectable: true);
      coalescer.next(id: 'AA', name: 'Bulb', rssi: -42, isConnectable: true);
      expect(coalescer.deviceCount, 1);

      coalescer.next(id: 'BB', name: 'Plug', rssi: -60, isConnectable: true);
      expect(coalescer.deviceCount, 2);
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
