// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Linux stack end to end: the SHIPPING RealBleService over the real
// flutter_blue_plus, bound to the real DirectAttRouter in front of an
// emulated BlueZ and scripted ATT peripherals (test/fakes/routed_ble.dart).
//
// The device most of this is about is written with both of its views: what
// bluetoothd reports (an EmulatedPeripheral whose discovery blocks, resolves
// empty, and whose link then drops — the silent-probe stall, scaled from
// 32 s to a few hundred milliseconds) and what its ATT server answers (a
// FakeAttPeripheral). Everything above flutter_blue_plus is the code an
// iPhone runs; these tests are the proof that it does not need to know
// which transport it got.

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show BluetoothDevice, FbpErrorCode, FlutterBluePlusException, Guid;
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show BmScanAdvertisement, DeviceIdentifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_channel.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_registry.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_router.dart'
    show BleSighting, DirectAttRouteHint;
import 'package:liberated_bread_mobile/services/real_ble_service.dart';

import '../../fakes/emulated_ble.dart';
import '../../fakes/fake_att_channel.dart';
import '../../fakes/routed_ble.dart';

const _meterId = '18:7A:93:12:DE:94';
const _bulbId = 'AA:BB:CC:DD:EE:01';
final _f150 = uuid16ToString(0xf150);
final _f151 = uuid16ToString(0xf151);
final _f154 = uuid16ToString(0xf154);
final _battery = uuid16ToString(0x180f);
final _batteryLevel = uuid16ToString(0x2a19);

/// Longer than the rig's stall threshold (200 ms): the scaled 30 s.
const _stall = Duration(milliseconds: 300);

void main() {
  late RoutedBle rig;
  late RealBleService service;

  setUpAll(() {
    rig = RoutedBle.install();
  });

  setUp(() async {
    await rig.reset();
    service = RealBleService();
  });

  /// The meter as bluetoothd sees it: connectable; every discovery blocks
  /// for [stall] then resolves with nothing, and — as the kernel does once
  /// bluetoothd has shut its bearer — the ACL goes a moment later
  /// ([releasesLink]; the real gap is about two seconds).
  EmulatedPeripheral bluezMeter({
    Duration stall = _stall,
    bool releasesLink = true,
  }) =>
      rig.ble.add(
          EmulatedPeripheral.bulb(id: _meterId, name: 'Laser Distance Meter'),
        )
        ..emptyDiscoveries = 1 << 20
        ..discoveryBlocksFor = stall
        ..dropLinkAfterDiscovery = releasesLink
            ? const Duration(milliseconds: 50)
            : null;

  /// The meter as its own ATT server answers.
  FakeAttPeripheral attMeter() => rig.channels.peripherals[_meterId] =
      FakeAttPeripheral.ldm330(serverRxMtu: 247);

  /// Every connection state [id] reports, from now until [cancel] is called.
  (List<BleConnectionState>, Future<void> Function()) watch(String id) {
    final seen = <BleConnectionState>[];
    final sub = service.connectionState(id).listen(seen.add);
    return (seen, sub.cancel);
  }

  Future<void> settle([int ms = 20]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('the silent-probe stall', () {
    test(
      'hands the device over mid-discovery, and the caller just gets services',
      () async {
        bluezMeter();
        final meter = attMeter();
        await service.connect(_meterId);
        final (states, stop) = watch(_meterId);

        final services = await service.discoverServices(_meterId);

        expect(services.map((s) => s.uuid), contains(_f150));
        // What BlueZ keeps to itself, the direct table hides too.
        expect(
          services.map((s) => s.uuid),
          isNot(contains(uuid16ToString(0x1800))),
        );
        expect(rig.registry.contains(_meterId), isTrue);
        expect(rig.store.values[DirectAttRegistry.key], contains(_meterId));
        expect(rig.channels.attempts.single.address, _meterId);
        // BlueZ let the stalled link go by itself, so it was never asked
        // to ...
        expect(rig.ble.platformCalls, isNot(contains('disconnect:$_meterId')));
        // ... and nothing above the platform saw the link change hands,
        // though BlueZ's did go down under it.
        await settle();
        expect(states, isNot(contains(BleConnectionState.disconnected)));
        expect(meter.violations, isEmpty);
        await stop();
      },
    );

    test('never starts over on the stalled connection: when BlueZ keeps it, '
        'BlueZ is asked to let it go first', () async {
      // bluetoothd already exchanged MTU on that connection and left a
      // request unanswered on it; the direct link must be a fresh one.
      bluezMeter(releasesLink: false);
      attMeter();
      await service.connect(_meterId);
      final (states, stop) = watch(_meterId);

      final services = await service.discoverServices(_meterId);

      expect(services.map((s) => s.uuid), contains(_f150));
      expect(
        rig.ble.platformCalls,
        contains('disconnect:$_meterId'),
        reason: 'BlueZ was asked to let go',
      );
      expect(rig.channels.attempts, hasLength(1));
      await settle();
      expect(states, isNot(contains(BleConnectionState.disconnected)));
      await stop();
    });

    test(
      'a first direct connect that fails (the radio still changing state) is '
      'retried',
      () async {
        bluezMeter();
        attMeter();
        rig.channels.failNextConnects(_meterId, const [
          AttChannelException('connect', 'refused', errno: 111),
        ]);
        await service.connect(_meterId);

        final services = await service.discoverServices(_meterId);

        expect(services.map((s) => s.uuid), contains(_f150));
        expect(rig.channels.attempts, hasLength(2));
        expect(rig.registry.contains(_meterId), isTrue);
      },
    );

    test('everything after the hand-over runs over the direct link', () async {
      bluezMeter();
      final meter = attMeter();
      await service.connect(_meterId);
      await service.discoverServices(_meterId);
      final bluezCalls = rig.ble.platformCalls.length;

      // The meter's init frame, as the vendor app sends it.
      await service.writeCharacteristic(_meterId, _f150, _f151, const [
        0x03,
        0x0d,
        0x0a,
        0x03,
        0x0d,
        0x0a,
      ]);
      expect(meter.writes.single.handle, FakeAttPeripheral.ldm330CommandHandle);

      final frames = <List<int>>[];
      final sub = service
          .subscribeCharacteristic(_meterId, _f150, _f154)
          .listen(frames.add);
      await settle();
      expect(meter.cccd(FakeAttPeripheral.ldm330DataCccd), 0x0001);
      meter.notify(
        FakeAttPeripheral.ldm330DataHandle,
        'A02.509b\x00\x00'.codeUnits,
      );
      await settle();
      expect(frames, ['A02.509b\x00\x00'.codeUnits]);
      expect(service.recentNotifications(_meterId, _f150, _f154), hasLength(1));
      expect(await service.mtu(_meterId), 247);
      await sub.cancel();
      await settle();
      expect(meter.cccd(FakeAttPeripheral.ldm330DataCccd), 0);

      await service.disconnect(_meterId);
      expect(rig.channels.channels.single.isOpen, isFalse);
      expect(
        rig.ble.platformCalls.length,
        bluezCalls,
        reason:
            'nothing about the meter went to BlueZ after the hand-over — '
            'least of all a disconnect, which would drop the whole ACL',
      );
    });

    test("after the hand-over, BlueZ's view of the device is ignored — "
        'services reset included', () async {
      bluezMeter();
      attMeter();
      await service.connect(_meterId);
      await service.discoverServices(_meterId);
      final fbp = BluetoothDevice.fromId(_meterId);
      expect(fbp.servicesList, isNotEmpty);

      // bluetoothd publishes UUID changes for the device (it sees the
      // ACL, and advertisements); flutter_blue_plus_linux turns every one
      // into a services reset, which would empty the app's table.
      rig.ble.pushServicesReset(_meterId);
      await settle();

      expect(fbp.servicesList, isNotEmpty);
    });

    test(
      'a stall that ends with the link dropped (no resolve at all) hands over '
      'too',
      () async {
        final bluez = rig.ble.add(
          EmulatedPeripheral.bulb(id: _meterId, name: 'Laser Distance Meter'),
        )..discoveryNeverResolves = true;
        attMeter();
        await service.connect(_meterId);
        final (states, stop) = watch(_meterId);
        // bluetoothd gives up and the ACL goes before ServicesResolved ever
        // flips: flutter_blue_plus_linux's poll would spin forever.
        Timer(_stall, () => bluez.dropLink(reasonCode: null, reason: null));

        final services = await service.discoverServices(_meterId);

        expect(services.map((s) => s.uuid), contains(_f150));
        expect(rig.registry.contains(_meterId), isTrue);
        await settle();
        expect(states, isNot(contains(BleConnectionState.disconnected)));
        await stop();
      },
    );

    test(
      'bluetoothd reporting the direct link comes and goes is ignored',
      () async {
        final bluez = bluezMeter();
        attMeter();
        await service.connect(_meterId);
        await service.discoverServices(_meterId);
        final (states, stop) = watch(_meterId);
        await settle();

        // bluetoothd sees the ACL the direct socket holds, and says so.
        bluez.reportLinkDown();
        bluez.reportLinkUp();
        bluez.reportLinkDown();
        await settle();

        expect(states, isNot(contains(BleConnectionState.disconnected)));
        expect(
          await service.readCharacteristic(_meterId, _battery, _batteryLevel),
          [100],
        );
        await stop();
      },
    );

    test(
      'a device whose direct walk finds nothing stays on BlueZ, unremembered, '
      'and the app hears only what BlueZ said',
      () async {
        final bluez = bluezMeter();
        // It answers ATT, but with nothing an app could use.
        rig.channels.peripherals[_meterId] = FakeAttPeripheral()
          ..service(0x0001, 0x0003, 0x1800)
          ..characteristic(0x0002, 0x0003, 0x02, 0x2a00, 'x'.codeUnits);
        await service.connect(_meterId);
        final (states, stop) = watch(_meterId);
        // bluetoothd narrates the tentative direct ACL too, the moment it
        // exists — noise the app must not hear.
        rig.channels.onChannelOpened = (_) => bluez.reportLinkUp();

        await expectLater(
          service.discoverServices(_meterId),
          throwsA(anything),
          reason: "BlueZ's link went with the stall",
        );

        expect(rig.registry.contains(_meterId), isFalse);
        expect(rig.store.values[DirectAttRegistry.key], isNull);
        expect(
          rig.channels.channels.single.isOpen,
          isFalse,
          reason: 'the tentative direct link was let go',
        );
        await settle(100);
        expect(states.last, BleConnectionState.disconnected);
        expect(
          states.skipWhile((s) => s == BleConnectionState.connected),
          everyElement(BleConnectionState.disconnected),
          reason: 'no phantom reconnect from the abandoned direct ACL',
        );
        await stop();
        // And the router's own view is BlueZ's, not the abandoned ACL's: a
        // reconnect goes to BlueZ rather than being answered "no change".
        await service.connect(_meterId);
        expect(
          rig.ble.platformCalls.where((c) => c == 'connect:$_meterId'),
          hasLength(2),
        );
      },
    );

    test(
      'an attempt whose link came up and then went quiet is not retried',
      () async {
        bluezMeter();
        // Connects, then never answers the MTU exchange.
        attMeter().silentOpcodes.add(AttOpcode.exchangeMtuRequest);
        await service.connect(_meterId);

        await expectLater(
          service.discoverServices(_meterId),
          throwsA(anything),
        );

        expect(
          rig.channels.attempts,
          hasLength(1),
          reason: 'a retry would cost another request timeout for nothing',
        );
        expect(rig.registry.contains(_meterId), isFalse);
      },
    );

    test(
      'a stalled device nobody answers for on ATT: the app hears BlueZ drop it',
      () async {
        final bluez = rig.ble.add(
          EmulatedPeripheral.bulb(id: _meterId, name: 'Laser Distance Meter'),
        )..discoveryNeverResolves = true;
        await service.connect(_meterId);
        final (states, stop) = watch(_meterId);
        final drop = Timer(
          _stall,
          () => bluez.dropLink(reasonCode: null, reason: null),
        );
        addTearDown(drop.cancel);
        final stopwatch = Stopwatch()..start();

        await expectLater(
          service.discoverServices(_meterId),
          // Typed as a drop by RealBleService.discoverServices, so the
          // device screen shows "disconnected", not "could not connect".
          throwsA(isA<BleLinkDroppedException>()),
        );

        // Three tries at a peer that is not there, then promptly out —
        // not flutter_blue_plus's 15 s timeout.
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
        expect(rig.registry.contains(_meterId), isFalse);
        expect(rig.channels.attempts, hasLength(3));
        // BlueZ's drop, held while the router tried, reaches the app once
        // the attempt is over.
        await settle();
        expect(states.last, BleConnectionState.disconnected);
        await stop();
      },
    );

    test('a slow discovery that FINDS services is not a stall', () async {
      rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId)).discoveryBlocksFor =
          _stall;
      await service.connect(_bulbId);

      final services = await service.discoverServices(_bulbId);

      expect(services, isNotEmpty);
      expect(rig.registry.contains(_bulbId), isFalse);
      expect(rig.channels.attempts, isEmpty);
      await service.disconnect(_bulbId);
    });

    test(
      'a quick empty answer is BlueZ racing its own resolution, not a stall',
      () async {
        rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId)).emptyDiscoveries = 1;
        await service.connect(_bulbId);

        // RealBleService's retry ladder absorbs the race, exactly as before.
        final services = await service.discoverServices(_bulbId);

        expect(services, isNotEmpty);
        expect(rig.channels.attempts, isEmpty);
        await service.disconnect(_bulbId);
      },
    );
  });

  group('a remembered device', () {
    setUp(() async {
      await rig.registry.add(_meterId);
    });

    test('skips BlueZ from the first connect', () async {
      rig.ble.add(EmulatedPeripheral.bulb(id: _meterId));
      attMeter();

      await service.connect(_meterId);
      final services = await service.discoverServices(_meterId);

      expect(rig.ble.platformCalls, isNot(contains('connect:$_meterId')));
      expect(
        rig.ble.platformCalls,
        isNot(contains('discoverServices:$_meterId')),
      );
      expect(services.map((s) => s.uuid), contains(_f150));
      expect(
        await service.connectionState(_meterId).first,
        BleConnectionState.connected,
      );
      await service.disconnect(_meterId);
      expect(
        await service.connectionState(_meterId).first,
        BleConnectionState.disconnected,
      );
    });

    test('in any spelling of its address', () async {
      attMeter();
      await service.connect(_meterId.toLowerCase());
      expect(rig.channels.attempts.single.address, _meterId);
      final services = await service.discoverServices(_meterId.toLowerCase());
      expect(services.map((s) => s.uuid), contains(_f150));
      await service.disconnect(_meterId.toLowerCase());
    });

    test(
      'a direct link that drops releases its claims like any other',
      () async {
        final meter = attMeter();
        await service.connect(_meterId);
        final (states, stop) = watch(_meterId);
        await settle();

        meter.dropLink();
        await settle();

        expect(states.last, BleConnectionState.disconnected);
        // No claim is inherited: the next connect opens a fresh link.
        await service.connect(_meterId);
        expect(rig.channels.attempts, hasLength(2));
        await service.disconnect(_meterId);
        await stop();
      },
    );

    test('a link BlueZ is holding (EBUSY) is asked for, then taken', () async {
      final bluez = rig.ble.add(EmulatedPeripheral.bulb(id: _meterId));
      attMeter();
      // bluetoothd connected it on its own and holds the ATT channel.
      bluez.reportLinkUp();
      rig.channels.failNextConnects(_meterId, const [
        AttChannelException('connect', 'busy', errno: 16),
        AttChannelException('connect', 'busy', errno: 16),
        AttChannelException('connect', 'busy', errno: 16),
      ]);

      await service.connect(_meterId);

      expect(rig.ble.platformCalls, contains('disconnect:$_meterId'));
      expect(rig.channels.attempts, hasLength(4));
      expect(
        await service.readCharacteristic(_meterId, _battery, _batteryLevel),
        [100],
      );
      await service.disconnect(_meterId);
    });

    test('a link BlueZ is holding is asked for in BlueZ\'s spelling, whatever '
        'the caller used', () async {
      final bluez = rig.ble.add(EmulatedPeripheral.bulb(id: _meterId));
      attMeter();
      bluez.reportLinkUp();
      rig.channels.failNextConnects(_meterId, const [
        AttChannelException('connect', 'busy', errno: 16),
        AttChannelException('connect', 'busy', errno: 16),
      ]);

      await service.connect(_meterId.toLowerCase());

      // flutter_blue_plus_linux finds a device by a case-sensitive match.
      expect(rig.ble.platformCalls, contains('disconnect:$_meterId'));
      await service.disconnect(_meterId.toLowerCase());
    });

    test(
      'a connect that fails is an error, and leaves it disconnected',
      () async {
        // Nobody at that address on ATT.
        await expectLater(service.connect(_meterId), throwsA(anything));
        expect(
          await service.connectionState(_meterId).first,
          BleConnectionState.disconnected,
        );
      },
    );

    test('RSSI is honestly unavailable, not a stale number', () async {
      attMeter();
      await service.connect(_meterId);
      await expectLater(service.readRssi(_meterId), throwsA(anything));
      await service.disconnect(_meterId);
    });

    test(
      'a characteristic that never answers is "silent", then the link goes',
      () async {
        final meter = attMeter()..silentOpcodes.add(AttOpcode.readRequest);
        await service.connect(_meterId);
        await service.discoverServices(_meterId);
        final (states, stop) = watch(_meterId);

        await expectLater(
          service.readCharacteristic(_meterId, _battery, _batteryLevel),
          throwsA(isA<BleCharacteristicSilentException>()),
        );
        await settle();
        expect(states.last, BleConnectionState.disconnected);
        expect(meter.isConnected, isFalse);
        await stop();
      },
    );

    test(
      'a link lost under a subscription write is a dropped link, at once',
      () async {
        final meter = attMeter()..silentOpcodes.add(AttOpcode.writeRequest);
        await service.connect(_meterId);
        await service.discoverServices(_meterId);
        final drop = Timer(const Duration(milliseconds: 50), meter.dropLink);
        addTearDown(drop.cancel);
        final stopwatch = Stopwatch()..start();

        await expectLater(
          service.subscribeCharacteristic(_meterId, _f150, _f154),
          emitsError(isA<BleLinkDroppedException>()),
        );
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      },
    );

    test(
      'a link lost under a descriptor read is a dropped link, at once',
      () async {
        final meter = attMeter()..silentOpcodes.add(AttOpcode.readRequest);
        await service.connect(_meterId);
        await service.discoverServices(_meterId);
        final data = BluetoothDevice.fromId(_meterId).servicesList
            .firstWhere((s) => s.uuid == Guid(_f150))
            .characteristics
            .firstWhere((c) => c.uuid == Guid(_f154));
        final cccd = data.descriptors.firstWhere((d) => d.uuid == Guid('2902'));
        final drop = Timer(const Duration(milliseconds: 50), meter.dropLink);
        addTearDown(drop.cancel);
        final stopwatch = Stopwatch()..start();

        await expectLater(
          cccd.read(),
          throwsA(
            isA<FlutterBluePlusException>().having(
              (e) => e.code,
              'code',
              FbpErrorCode.deviceIsDisconnected.index,
            ),
          ),
        );
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      },
    );

    test('an attribute that wants encryption gets it, as on a phone', () async {
      final meter = attMeter();
      meter.attributes[0x0036]!.requiredSecurity = 2;
      await service.connect(_meterId);

      expect(
        await service.readCharacteristic(_meterId, _battery, _batteryLevel),
        [100],
      );
      expect(meter.elevations, [2]);
      await service.disconnect(_meterId);
    });

    for (final after in const [0, 5, 20]) {
      test('a pairing the PEER refuses — the kernel drops the link — is still '
          '"pair first" (drop ${after}ms in)', () async {
        final meter = attMeter()..pairingDelay = const Duration(seconds: 2);
        meter.attributes[0x0036]!.requiredSecurity = 2;
        await service.connect(_meterId);
        await service.discoverServices(_meterId);
        // Once the elevation is under way, the peer answers Pairing
        // Failed and the kernel tears the link down (EACCES).
        final watcher = Timer.periodic(const Duration(milliseconds: 1), (t) {
          if (meter.elevations.isEmpty) return;
          t.cancel();
          Timer(
            Duration(milliseconds: after),
            () => meter.dropLink(errno: AttErrno.eacces),
          );
        });
        addTearDown(watcher.cancel);

        await expectLater(
          service.readCharacteristic(_meterId, _battery, _batteryLevel),
          throwsA(isA<BlePairingRequiredException>()),
        );
      });
    }

    test('... and a refused pairing is the pairing error', () async {
      final meter = attMeter()..acceptsPairing = false;
      meter.attributes[0x0036]!.requiredSecurity = 2;
      await service.connect(_meterId);

      await expectLater(
        service.readCharacteristic(_meterId, _battery, _batteryLevel),
        throwsA(isA<BlePairingRequiredException>()),
      );
      await service.disconnect(_meterId);
    });

    test('Service Changed makes the app rediscover', () async {
      final meter = attMeter()..gattService(0x0040);
      await service.connect(_meterId);
      await service.discoverServices(_meterId);
      // Asked for, as bluetoothd and CoreBluetooth ask: a compliant peer
      // only indicates a rebuilt database to a client that enabled it.
      expect(meter.cccd(0x0043), 0x0002);
      final walks = meter.requests
          .where((r) => r[0] == AttOpcode.readByGroupTypeRequest)
          .length;

      meter.indicateServiceChanged(0x0001, 0xffff);
      await settle();
      await service.discoverServices(_meterId);

      expect(
        meter.requests
            .where((r) => r[0] == AttOpcode.readByGroupTypeRequest)
            .length,
        greaterThan(walks),
      );
      expect(meter.confirmations, 1);
      await service.disconnect(_meterId);
    });
  });

  group("the spec catalogue's word", () {
    test('a device a spec marks BlueZ-incompatible goes direct from its first '
        'connect: no BlueZ, no stall, nothing remembered', () async {
      rig.ble.add(EmulatedPeripheral.bulb(id: _meterId)).discoveryBlocksFor =
          _stall;
      attMeter();
      final asked = <String>[];
      rig.router.routeHint = (id, seen) async {
        asked.add(id);
        return id == _meterId;
      };
      final stopwatch = Stopwatch()..start();

      await service.connect(_meterId);
      final services = await service.discoverServices(_meterId);

      expect(services.map((s) => s.uuid), contains(_f150));
      expect(stopwatch.elapsed, lessThan(_stall), reason: 'no stall');
      expect(asked, [_meterId]);
      expect(rig.ble.platformCalls, isNot(contains('connect:$_meterId')));
      expect(rig.registry.isDeclared(_meterId), isTrue);
      expect(
        rig.store.values,
        isEmpty,
        reason: "a spec's claim is re-derived each run, never stored",
      );
      await service.disconnect(_meterId);
    });

    test('the hint is told what the device last advertised', () async {
      rig.ble.add(
        EmulatedPeripheral.bulb(id: _meterId, name: 'Laser Distance Meter'),
      );
      attMeter();
      BleSighting? told;
      rig.router.routeHint = (id, seen) async {
        told = seen;
        return true;
      };
      await service.scan(timeout: const Duration(milliseconds: 300)).toList();

      await service.connect(_meterId);

      expect(told?.name, 'Laser Distance Meter');
      expect(told?.serviceUuids, isNotEmpty);
      await service.disconnect(_meterId);
    });

    for (final (label, hint) in <(String, DirectAttRouteHint)>[
      ('says no', (_, _) async => false),
      ('throws', (_, _) async => throw StateError('catalogue broke')),
      (
        'does not answer in time',
        (_, _) => Future.delayed(const Duration(seconds: 2), () => true),
      ),
    ]) {
      test('a hint that $label leaves the device on BlueZ', () async {
        rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        rig.router.routeHint = hint;

        await service.connect(_bulbId);

        expect(rig.ble.platformCalls, contains('connect:$_bulbId'));
        expect(rig.registry.contains(_bulbId), isFalse);
        await service.disconnect(_bulbId);
      });
    }

    test('a device already routed direct is not asked about', () async {
      await rig.registry.add(_meterId);
      attMeter();
      var asked = false;
      rig.router.routeHint = (_, _) async => asked = true;

      await service.connect(_meterId);

      expect(asked, isFalse);
      await service.disconnect(_meterId);
    });
  });

  group('Linux held to phone semantics, for every device', () {
    test(
      'connect on an already-connected link is a no-op, not a teardown',
      () async {
        // flutter_blue_plus_linux answers "changed" here; unguarded,
        // flutter_blue_plus then waits out its timeout and DISCONNECTS.
        rig.ble.connectReturnsTrueWhenConnected = true;
        rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId));
        await service.connect(_bulbId);
        final stopwatch = Stopwatch()..start();

        await service.connect(_bulbId); // a second owner joins the link

        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(
          rig.ble.platformCalls.where((c) => c == 'connect:$_bulbId'),
          hasLength(1),
        );
        await service.disconnect(_bulbId); // first owner leaves ...
        expect(
          await service.connectionState(_bulbId).first,
          BleConnectionState.connected,
          reason: '... and the second still has its link',
        );
        await service.disconnect(_bulbId);
        rig.ble.connectReturnsTrueWhenConnected = false;
      },
    );

    test('disconnecting a link that already dropped does not hang', () async {
      rig.ble.disconnectReturnsTrueWhenDisconnected = true;
      final bulb = rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId));
      await service.connect(_bulbId);
      bulb.dropLink();
      await settle();
      final stopwatch = Stopwatch()..start();

      await service.disconnect(_bulbId);

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      rig.ble.disconnectReturnsTrueWhenDisconnected = false;
    });

    test(
      'a link lost mid-discovery frees flutter_blue_plus instead of wedging it',
      () async {
        final bulb = rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId))
          ..discoveryNeverResolves = true;
        await service.connect(_bulbId);
        final drop = Timer(
          const Duration(milliseconds: 50),
          () => bulb.dropLink(reasonCode: null, reason: null),
        );
        addTearDown(drop.cancel);
        final stopwatch = Stopwatch()..start();

        await expectLater(
          service.discoverServices(_bulbId),
          // Typed as a drop by RealBleService.discoverServices, so the
          // device screen shows "disconnected", not "could not connect".
          throwsA(isA<BleLinkDroppedException>()),
        );
        // At once, as a disconnect — not after 15 s holding
        // flutter_blue_plus's lock.
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
        // Quick, so not a stall: nothing was handed over ...
        expect(rig.channels.attempts, isEmpty);
        // ... and the rest of Bluetooth still works.
        rig.ble.add(EmulatedPeripheral.bulb(id: 'AA:BB:CC:DD:EE:02'));
        await service.connect('AA:BB:CC:DD:EE:02');
        expect(await service.discoverServices('AA:BB:CC:DD:EE:02'), isNotEmpty);
        await service.disconnect('AA:BB:CC:DD:EE:02');
      },
    );

    test('a discovery BlueZ never finishes is given up on', () async {
      rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId)).discoveryNeverResolves =
          true;
      await service.connect(_bulbId);
      final stopwatch = Stopwatch()..start();

      await expectLater(service.discoverServices(_bulbId), throwsA(anything));

      // The rig's scaled limit is 1.5 s; the direct attempts found no one.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(rig.registry.contains(_bulbId), isFalse);
      expect(rig.channels.attempts, hasLength(3));
      await service.disconnect(_bulbId);
    });

    test('... and a device that answers ATT is taken over after it', () async {
      rig.ble
              .add(EmulatedPeripheral.bulb(id: _meterId))
              .discoveryNeverResolves =
          true;
      attMeter();
      await service.connect(_meterId);

      final services = await service.discoverServices(_meterId);

      expect(services.map((s) => s.uuid), contains(_f150));
      expect(rig.registry.contains(_meterId), isTrue);
      expect(rig.channels.attempts, hasLength(1));
    });

    test('a BlueZ result that lands after the router stopped waiting is not '
        "flutter_blue_plus's table", () async {
      // Blocks past the scaled 1.5 s limit, then answers with services.
      // Its own id: flutter_blue_plus keeps a device's table across
      // disconnects, so a bulb an earlier test discovered already has one.
      const lateId = 'AA:BB:CC:DD:EE:07';
      rig.ble.add(EmulatedPeripheral.bulb(id: lateId)).discoveryBlocksFor =
          const Duration(milliseconds: 2000);
      await service.connect(lateId);
      await expectLater(service.discoverServices(lateId), throwsA(anything));

      await settle(800);

      expect(BluetoothDevice.fromId(lateId).servicesList, isEmpty);
    });

    test('a device BlueZ already knows shows up in a scan — the backend never '
        'reports it', () async {
      // Nothing advertises through the emulated backend; bluetoothd only
      // updates the kept device's properties, which the router re-reports.
      final seen = <String>[];
      final scan = service
          .scan(timeout: const Duration(milliseconds: 400))
          .listen((d) => seen.add(d.id));
      await settle(50);
      rig.sightings.add(_sighting(_meterId, rssi: -58));
      await settle(100);
      await scan.cancel();

      expect(seen, contains(_meterId));
    });

    test('... but only while a scan runs', () async {
      rig.sightings.add(_sighting(_meterId));
      final seen = await service
          .scan(timeout: const Duration(milliseconds: 200))
          .map((d) => d.id)
          .toList();
      rig.sightings.add(_sighting(_meterId));
      await settle();

      expect(seen, isNot(contains(_meterId)));
    });

    test('scanning is BlueZ\'s, through the router', () async {
      rig.ble.add(EmulatedPeripheral.bulb(id: _bulbId, name: 'ACME_Bulb'));
      final seen = await service
          .scan(timeout: const Duration(milliseconds: 300))
          .toList();
      expect(seen.map((d) => d.id), contains(_bulbId));
    });
  });
}

/// What BluezView reports for a kept device bluetoothd just heard.
BmScanAdvertisement _sighting(String id, {int rssi = -60}) =>
    BmScanAdvertisement(
      remoteId: DeviceIdentifier(id),
      platformName: 'Laser Distance Meter',
      advName: null,
      connectable: true,
      txPowerLevel: null,
      appearance: null,
      manufacturerData: const {},
      serviceData: const {},
      serviceUuids: [Guid('f150')],
      rssi: rssi,
    );
