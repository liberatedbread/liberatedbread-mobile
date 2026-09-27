// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// DirectAttPlatform on its own, as flutter_blue_plus's platform, driven
// through flutter_blue_plus's PUBLIC API against scripted ATT peripherals.
//
// This is the contract test: whatever an app can do with a BluetoothDevice
// and its characteristics on a phone — connect, see mtuNow, discover, read,
// write both ways, subscribe and watch isNotifying, get the errors it
// classifies — works the same when the bytes go over a raw ATT bearer. The
// router suite (direct_att_router_test.dart) then only has to prove the
// routing; this proves the backend.

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart'
    show FlutterBluePlusPlatform, bmUserCanceledErrorCode;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_platform.dart';

import '../../fakes/fake_att_channel.dart';

const _id = 'C0:FF:EE:00:00:01';

// A generic peripheral, nothing like the laser meter: a vendor service with
// 128-bit UUIDs, two characteristics sharing a UUID, an indicate-only one, a
// long value and a user-description descriptor.
const _vendor = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const _rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const _tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
const _twin = '6e400004-b5a3-f393-e0a9-e50e24dcca9e';
const _alarm = '6e400005-b5a3-f393-e0a9-e50e24dcca9e';

FakeAttPeripheral _generic({int serverRxMtu = 185}) =>
    FakeAttPeripheral(serverRxMtu: serverRxMtu)
      ..service(0x0001, 0x0005, 0x1800)
      ..characteristic(0x0002, 0x0003, 0x02, 0x2a00, 'Generic'.codeUnits)
      ..characteristic(0x0004, 0x0005, 0x02, 0x2a01, const [0, 0])
      ..service(0x0010, 0x0012, 0x180f)
      ..characteristic(0x0011, 0x0012, 0x02, 0x2a19, const [87])
      ..service(0x0020, 0x0032, 0, uuid128: _vendor)
      ..characteristic(0x0021, 0x0022, 0x0c, 0, const [], uuid128: _rx)
      ..characteristic(0x0023, 0x0024, 0x12, 0, const [], uuid128: _tx)
      ..descriptor(0x0025, 0x2902)
      ..descriptor(0x0026, 0x2901, value: 'telemetry'.codeUnits)
      ..characteristic(0x0027, 0x0028, 0x02, 0, const [1], uuid128: _twin)
      ..characteristic(0x0029, 0x002a, 0x02, 0, const [2], uuid128: _twin)
      ..characteristic(0x002b, 0x002c, 0x20, 0, const [], uuid128: _alarm)
      ..descriptor(0x002d, 0x2902)
      ..characteristic(
        0x002e,
        0x002f,
        0x0a,
        0x2a24,
        List.generate(300, (i) => i & 0xff),
      );

/// While set, every address-type lookup (the first step of an open) waits.
Completer<void>? _addressGate;

void main() {
  late FakeAttChannelFactory channels;
  late DirectAttPlatform platform;
  late BluetoothDevice device;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    channels = FakeAttChannelFactory();
    platform = DirectAttPlatform(
      channels,
      // Held shut by a test that needs a connect to stall mid-open.
      isRandomAddress: (_) async {
        await _addressGate?.future;
        return false;
      },
      connectTimeout: const Duration(seconds: 2),
      requestTimeout: const Duration(milliseconds: 300),
      securityTimeout: const Duration(seconds: 1),
      busyRetryDelay: const Duration(milliseconds: 20),
    );
    FlutterBluePlusPlatform.instance = platform;
  });

  setUp(() async {
    await platform.debugReset();
    channels.peripherals.clear();
    channels.attempts.clear();
    channels.channels.clear();
    device = BluetoothDevice.fromId(_id);
  });

  Future<FakeAttPeripheral> connected({FakeAttPeripheral? peer}) async {
    final p = channels.peripherals[_id] = peer ?? _generic();
    await device.connect(timeout: const Duration(seconds: 5));
    return p;
  }

  BluetoothService serviceOf(List<BluetoothService> all, String uuid) =>
      all.firstWhere((s) => s.uuid == Guid(uuid));

  BluetoothCharacteristic charOf(
    BluetoothService s,
    String uuid, [
    int instance = 0,
  ]) =>
      s.characteristics.where((c) => c.uuid == Guid(uuid)).elementAt(instance);

  group('connection', () {
    test(
      'connects, with the negotiated MTU in place when connect returns',
      () async {
        await connected(peer: _generic(serverRxMtu: 185));
        expect(device.isConnected, isTrue);
        expect(device.mtuNow, 185);
      },
    );

    test('a second connect is "no change", not a second link', () async {
      await connected();
      await device.connect(timeout: const Duration(seconds: 5));
      expect(channels.attempts, hasLength(1));
    });

    test('a peripheral that never answers the exchange keeps 23', () async {
      final peer = _generic()..refusesMtuExchange = true;
      await connected(peer: peer);
      expect(device.mtuNow, 23);
    });

    test('nobody there: connect fails with the errno, disconnected', () async {
      await expectLater(
        device.connect(timeout: const Duration(seconds: 5)),
        throwsA(
          isA<FlutterBluePlusException>()
              .having((e) => e.function, 'function', 'connect')
              .having((e) => e.platform, 'platform', isNot(ErrorPlatform.fbp)),
        ),
      );
      expect(device.isConnected, isFalse);
    });

    test(
      'flutter_blue_plus timing out a connect cancels the attempt',
      () async {
        channels.peripherals[_id] = _generic();
        channels.connectLatency = const Duration(seconds: 3);
        await expectLater(
          device.connect(timeout: const Duration(seconds: 1)),
          throwsA(
            isA<FlutterBluePlusException>().having(
              (e) => e.code,
              'code',
              FbpErrorCode.timeout.index,
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(channels.channels, isEmpty, reason: 'the socket was never used');
        expect(platform.hasLink(_id), isFalse);
        channels.connectLatency = Duration.zero;
      },
    );

    test('a connect while a timed-out attempt is still unwinding gets its own '
        'link, not the old one\'s "canceled"', () async {
      channels.peripherals[_id] = _generic();
      final gate = _addressGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
        _addressGate = null;
      });
      // flutter_blue_plus gives up on the first attempt, stuck before its
      // socket, and cancels it ...
      await expectLater(
        device.connect(timeout: const Duration(seconds: 1)),
        throwsA(isA<FlutterBluePlusException>()),
      );
      // ... which is still unwinding when the app tries again.
      Timer(const Duration(milliseconds: 100), gate.complete);
      _addressGate = null;

      await device.connect(timeout: const Duration(seconds: 5));

      expect(device.isConnected, isTrue);
    });

    test(
      'a peer that never answers the MTU exchange: the error says so',
      () async {
        channels.peripherals[_id] = _generic()
          ..silentOpcodes.add(AttOpcode.exchangeMtuRequest);
        await expectLater(
          device.connect(timeout: const Duration(seconds: 5)),
          throwsA(
            isA<FlutterBluePlusException>().having(
              (e) => e.description,
              'description',
              contains('MTU exchange'),
            ),
          ),
        );
      },
    );

    test('a local disconnect is reported as the user cancelling', () async {
      await connected();
      await device.disconnect();
      expect(device.isConnected, isFalse);
      expect(device.disconnectReason?.code, bmUserCanceledErrorCode);
      expect(channels.channels.single.isOpen, isFalse);
    });

    test('the peer hanging up is a disconnect with its errno', () async {
      final peer = await connected();
      final states = <BluetoothConnectionState>[];
      final sub = device.connectionState.listen(states.add);
      peer.dropLink();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(states.last, BluetoothConnectionState.disconnected);
      // flutter_blue_plus drops the link's MTU with it.
      expect(device.mtuNow, 23);
      await sub.cancel();
    });

    test('the remoteId is echoed in the caller\'s spelling', () async {
      channels.peripherals[_id] = _generic();
      final lower = BluetoothDevice.fromId(_id.toLowerCase());
      await lower.connect(timeout: const Duration(seconds: 5));
      expect(lower.isConnected, isTrue);
      expect(channels.attempts.single.address, _id);
      await lower.disconnect();
    });
  });

  group('discovery', () {
    test('publishes the table as BlueZ and CoreBluetooth would', () async {
      await connected();
      final services = await device.discoverServices(
        subscribeToServicesChanged: false,
      );

      // Generic Access stays with the stack, as on every other platform.
      expect(services.map((s) => s.uuid), isNot(contains(Guid('1800'))));
      expect(
        services.map((s) => s.uuid),
        containsAll([Guid('180f'), Guid(_vendor)]),
      );
      final vendor = serviceOf(services, _vendor);
      expect(vendor.isPrimary, isTrue);
      // Same-UUID characteristics are told apart by instanceId.
      final twins = vendor.characteristics.where((c) => c.uuid == Guid(_twin));
      expect(twins.map((c) => c.instanceId), [0, 1]);
      // Properties straight from the declaration byte.
      final rx = charOf(vendor, _rx);
      expect(rx.properties.write, isTrue);
      expect(rx.properties.writeWithoutResponse, isTrue);
      expect(rx.properties.read, isFalse);
      // Descriptors, CCCD included, under the characteristic.
      final tx = charOf(vendor, _tx);
      expect(
        tx.descriptors.map((d) => d.uuid),
        containsAll([Guid('2902'), Guid('2901')]),
      );
    });

    test(
      'Service Changed is asked for without ever pairing, even when its CCCD '
      'is protected',
      () async {
        // Some peers of this kind support no encryption; a pairing attempt
        // on one drops the link. The subscription is best effort.
        final peer = _generic()
          ..gattService(0x0040)
          ..acceptsPairing = false;
        peer.attributes[0x0043]!.requiredSecurity = 2;
        await connected(peer: peer);

        final services = await device.discoverServices(
          subscribeToServicesChanged: false,
        );

        expect(services, isNotEmpty);
        expect(peer.elevations, isEmpty);
        expect(device.isConnected, isTrue);
        expect(peer.cccd(0x0043), 0);
      },
    );

    test('walks each link once', () async {
      final peer = await connected();
      await device.discoverServices(subscribeToServicesChanged: false);
      final after = peer.requests.length;
      await device.discoverServices(subscribeToServicesChanged: false);
      expect(peer.requests.length, after);
    });

    test('Service Changed resets the table flutter_blue_plus holds', () async {
      final peer = _generic()..gattService(0x0040);
      await connected(peer: peer);
      await device.discoverServices(subscribeToServicesChanged: false);
      // The walk asked for Service Changed itself, as bluetoothd does.
      expect(peer.cccd(0x0043), 0x0002);
      final reset = device.onServicesReset.first;

      peer.indicateServiceChanged(0x0001, 0xffff);

      await reset.timeout(const Duration(seconds: 1));
      expect(device.servicesList, isEmpty);
      final again = await device.discoverServices(
        subscribeToServicesChanged: false,
      );
      expect(again.map((s) => s.uuid), contains(Guid(_vendor)));
    });
  });

  group('subscriptions', () {
    test(
      'same-UUID twins keep their own CCCDs and their own isNotifying',
      () async {
        final peer = FakeAttPeripheral(serverRxMtu: 185)
          ..service(0x0001, 0x0009, 0x180f)
          ..characteristic(0x0002, 0x0003, 0x12, 0x2a19, const [10])
          ..descriptor(0x0004, 0x2902)
          ..characteristic(0x0005, 0x0006, 0x12, 0x2a19, const [20])
          ..descriptor(0x0007, 0x2902);
        await connected(peer: peer);
        final battery = (await device.discoverServices(
          subscribeToServicesChanged: false,
        )).single;
        final second = charOf(battery, '2a19', 1);

        await second.setNotifyValue(true);

        expect(peer.cccd(0x0007), 0x0001);
        expect(peer.cccd(0x0004), 0, reason: "the first twin's CCCD untouched");
        expect(second.isNotifying, isTrue);
        expect(charOf(battery, '2a19', 0).isNotifying, isFalse);
        final cccd = second.descriptors.firstWhere(
          (d) => d.uuid == Guid('2902'),
        );
        expect(await cccd.read(), [0x01, 0x00]);
      },
    );

    test(
      'a notifier with no CCCD subscribes at once, and its values flow',
      () async {
        final peer = FakeAttPeripheral(serverRxMtu: 185)
          ..service(0x0001, 0x0003, 0xfff0)
          ..characteristic(0x0002, 0x0003, 0x10, 0xfff1, const []);
        await connected(peer: peer);
        final bare = charOf(
          (await device.discoverServices(
            subscribeToServicesChanged: false,
          )).single,
          'fff1',
        );
        final values = <List<int>>[];
        final sub = bare.onValueReceived.listen(values.add);
        final stopwatch = Stopwatch()..start();

        await bare.setNotifyValue(true);

        expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
        peer.notify(0x0003, [7]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(values, [
          [7],
        ]);
        await sub.cancel();
      },
    );
  });

  group('characteristics', () {
    late FakeAttPeripheral peer;
    late BluetoothService vendor;
    late BluetoothService battery;

    setUp(() async {
      peer = await connected();
      final services = await device.discoverServices(
        subscribeToServicesChanged: false,
      );
      vendor = serviceOf(services, _vendor);
      battery = serviceOf(services, '180f');
    });

    test('read', () async {
      expect(await charOf(battery, '2a19').read(), [87]);
    });

    test('read of a value longer than one PDU is reassembled', () async {
      final info = services(device).expand((s) => s.characteristics);
      final long = info.firstWhere((c) => c.uuid == Guid('2a24'));
      expect(await long.read(), List.generate(300, (i) => i & 0xff));
    });

    test('twins answer as themselves', () async {
      expect(await charOf(vendor, _twin, 0).read(), [1]);
      expect(await charOf(vendor, _twin, 1).read(), [2]);
    });

    test('write with response', () async {
      await charOf(vendor, _rx).write([1, 2, 3]);
      final write = peer.writes.last;
      expect(write.handle, 0x0022);
      expect(write.value, [1, 2, 3]);
      expect(write.withResponse, isTrue);
    });

    test('write without response still completes for the caller', () async {
      await charOf(vendor, _rx).write([4], withoutResponse: true);
      expect(peer.writes.last.withResponse, isFalse);
    });

    test('a write longer than one PDU is queued, as BlueZ does', () async {
      final info = services(device).expand((s) => s.characteristics);
      final long = info.firstWhere((c) => c.uuid == Guid('2a24'));
      final value = List.generate(400, (i) => (i * 7) & 0xff);
      await long.write(value);
      expect(peer.attributes[0x002f]!.value, value);
      expect(
        peer.requests.where((r) => r[0] == AttOpcode.prepareWriteRequest),
        isNotEmpty,
      );
    });

    test('a write command that cannot fit is refused, not truncated', () async {
      final big = List.filled(device.mtuNow, 0x55);
      await expectLater(
        charOf(vendor, _rx).write(big, withoutResponse: true),
        throwsA(
          isA<FlutterBluePlusException>().having(
            (e) => e.platform,
            'platform',
            isNot(ErrorPlatform.fbp),
          ),
        ),
      );
    });

    test('an ATT refusal carries the ATT code', () async {
      // The battery level is read-only.
      await expectLater(
        charOf(battery, '2a19').write([1]),
        throwsA(
          isA<FlutterBluePlusException>()
              .having((e) => e.code, 'code', AttError.writeNotPermitted)
              .having((e) => e.platform, 'platform', isNot(ErrorPlatform.fbp)),
        ),
      );
    });

    test(
      'notifications: CCCD, isNotifying and values, as on a phone',
      () async {
        final tx = charOf(vendor, _tx);
        final values = <List<int>>[];
        final sub = tx.onValueReceived.listen(values.add);

        await tx.setNotifyValue(true);
        expect(peer.cccd(0x0025), 0x0001);
        expect(tx.isNotifying, isTrue);
        peer.notify(0x0024, [9, 8, 7]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(values, [
          [9, 8, 7],
        ]);

        await tx.setNotifyValue(false);
        expect(peer.cccd(0x0025), 0);
        expect(tx.isNotifying, isFalse);
        await sub.cancel();
      },
    );

    test('an indicate-only characteristic subscribes by indication', () async {
      final alarm = charOf(vendor, _alarm);
      final values = <List<int>>[];
      final sub = alarm.onValueReceived.listen(values.add);
      await alarm.setNotifyValue(true);
      expect(peer.cccd(0x002d), 0x0002);
      peer.notify(0x002c, [1], indicate: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(values, [
        [1],
      ]);
      expect(peer.confirmations, 1);
      await sub.cancel();
    });

    test('descriptors read and write', () async {
      final tx = charOf(vendor, _tx);
      final description = tx.descriptors.firstWhere(
        (d) => d.uuid == Guid('2901'),
      );
      expect(await description.read(), 'telemetry'.codeUnits);
    });

    test('a read nobody answers is flutter_blue_plus\'s timeout, then the '
        'link closes', () async {
      peer.silentOpcodes.add(AttOpcode.readRequest);
      await expectLater(
        charOf(battery, '2a19').read(),
        throwsA(
          isA<FlutterBluePlusException>()
              .having((e) => e.platform, 'platform', ErrorPlatform.fbp)
              .having((e) => e.code, 'code', FbpErrorCode.timeout.index),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(device.isConnected, isFalse);
    });

    test('a link lost under an operation is flutter_blue_plus\'s '
        '"disconnected"', () async {
      peer.silentOpcodes.add(AttOpcode.readRequest);
      Timer(const Duration(milliseconds: 50), peer.dropLink);
      await expectLater(
        charOf(battery, '2a19').read(),
        throwsA(
          isA<FlutterBluePlusException>().having(
            (e) => e.code,
            'code',
            FbpErrorCode.deviceIsDisconnected.index,
          ),
        ),
      );
    });

    test('a peer-initiated MTU exchange moves mtuNow', () async {
      final before = device.mtuNow;
      await peer.sendRequestToClient([AttOpcode.exchangeMtuRequest, 50, 0]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(device.mtuNow, 50);
      expect(before, isNot(50));
    });

    test('RSSI is an honest failure', () async {
      await expectLater(
        device.readRssi(),
        throwsA(isA<FlutterBluePlusException>()),
      );
    });
  });
}

List<BluetoothService> services(BluetoothDevice device) => device.servicesList;
