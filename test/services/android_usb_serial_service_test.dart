// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Android backend against the usb_serial plugin's channels.
//
// The plugin's Java side is Android's; what is ours is the adapting — which
// device becomes which port, what an open configures, what a refusal says,
// and how the input stream becomes exact-length reads. All of that runs
// against mocked channels here, with no device anywhere.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/android_usb_serial_service.dart';
import 'package:liberated_bread_mobile/services/serial_port_service.dart';

const _plugin = MethodChannel('usb_serial');
const _portChannelName = 'usb_serial/port0';
const _port = MethodChannel(_portChannelName);
const _portStream = EventChannel('$_portChannelName/stream');

/// A CH340 cable as the plugin lists it, under Android's number for it.
Map<String, Object?> _ch340({int deviceId = 1003, int bus = 3}) => {
  'deviceName': '/dev/bus/usb/001/00$bus',
  'vid': 0x1A86,
  'pid': 0x7523,
  'productName': 'USB Serial',
  'manufacturerName': 'QinHeng',
  'deviceId': deviceId,
  'serialNumber': null,
  'interfaceCount': 1,
};

class _FakePlugin {
  List<Map<String, Object?>> devices = [_ch340()];
  bool grant = true;

  /// The Android device numbers opened, in order.
  final List<Object?> created = [];
  bool openSucceeds = true;
  final List<MethodCall> portCalls = [];
  final List<Uint8List> written = [];
  MockStreamHandlerEventSink? input;

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_plugin, (call) async {
      switch (call.method) {
        case 'listDevices':
          return devices;
        case 'create':
          created.add((call.arguments as Map)['deviceId']);
          return grant ? _portChannelName : null;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_port, (call) async {
      portCalls.add(call);
      switch (call.method) {
        case 'open':
          return openSucceeds;
        case 'close':
          return true;
        case 'write':
          written.add((call.arguments as Map)['data'] as Uint8List);
      }
      return null;
    });
    messenger.setMockStreamHandler(
      _portStream,
      MockStreamHandler.inline(
        onListen: (arguments, events) => input = events,
        onCancel: (arguments) => input = null,
      ),
    );
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_plugin, null);
    messenger.setMockMethodCallHandler(_port, null);
    messenger.setMockStreamHandler(_portStream, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlugin plugin;
  final service = AndroidUsbSerialService();

  setUp(() {
    plugin = _FakePlugin()..install();
  });
  tearDown(() => plugin.uninstall());

  const cable = SerialPortInfo(
    id: 'usb:1a86:7523',
    name: '/dev/bus/usb/001/003',
    vendorId: 0x1A86,
    productId: 0x7523,
  );

  test('is available: Android reaches cables through USB host', () {
    expect(service.availability.supported, isTrue);
  });

  test('lists each plugged-in device as a port', () async {
    plugin.devices = [
      _ch340(),
      // A device the platform gave no id cannot be opened, so is not listed.
      {
        'deviceName': '/dev/bus/usb/001/004',
        'vid': 1,
        'pid': 2,
        'deviceId': null,
      },
    ];

    final ports = await service.listPorts();
    expect(ports, hasLength(1));
    expect(ports.single.id, 'usb:1a86:7523');
    expect(ports.single.name, '/dev/bus/usb/001/003');
    expect(ports.single.displayName, 'USB Serial');
    expect(ports.single.manufacturer, 'QinHeng');
    expect(ports.single.bridge?.name, 'WCH CH340');
  });

  test('a cable keeps its id when it is plugged in again', () async {
    // Android numbers a device afresh on every plug-in. A radio saved
    // through this cable must still be found the next time.
    final before = await service.listPorts();
    plugin.devices = [_ch340(deviceId: 1007, bus: 7)];
    final after = await service.listPorts();
    expect(after.single.id, before.single.id);

    final link = await service.open(before.single, baudRate: 9600);
    expect(plugin.created, [
      1007,
    ], reason: 'opened by the number Android gives it now');
    await link.close();
  });

  test(
    'two identical cables are told apart by where they are plugged in',
    () async {
      plugin.devices = [
        _ch340(deviceId: 1003, bus: 3),
        _ch340(deviceId: 1004, bus: 4),
      ];
      final ports = await service.listPorts();
      expect(ports.map((p) => p.id).toSet(), hasLength(2));

      final link = await service.open(ports.last, baudRate: 9600);
      expect(plugin.created, [1004]);
      await link.close();
    },
  );

  test('opens at the rate asked, 8N1, with DTR and RTS raised', () async {
    final link = await service.open(cable, baudRate: 9600);
    final methods = [for (final c in plugin.portCalls) c.method];
    expect(methods, containsAllInOrder(['open', 'setPortParameters']));
    final params =
        plugin.portCalls
                .firstWhere((c) => c.method == 'setPortParameters')
                .arguments
            as Map;
    expect(params['baudRate'], 9600);
    expect(params['dataBits'], 8);
    expect(params['stopBits'], 1);
    expect(params['parity'], 0);
    expect(methods, containsAll(['setDTR', 'setRTS']));
    await link.close();
  });

  test('a refused permission says what to do', () async {
    plugin.grant = false;
    await expectLater(
      service.open(cable, baudRate: 9600),
      throwsA(
        isA<SerialPortException>().having(
          (e) => e.message,
          'message',
          contains('allow it'),
        ),
      ),
    );
  });

  test('a cable that will not open says what to do', () async {
    plugin.openSucceeds = false;
    await expectLater(
      service.open(cable, baudRate: 9600),
      throwsA(
        isA<SerialPortException>().having(
          (e) => e.message,
          'message',
          contains('plug it back in'),
        ),
      ),
    );
  });

  test('a cable no longer plugged in is refused before anything', () async {
    plugin.devices = [];
    await expectLater(
      service.open(cable, baudRate: 9600),
      throwsA(
        isA<SerialPortException>().having(
          (e) => e.message,
          'message',
          contains('not plugged in'),
        ),
      ),
    );
    expect(plugin.created, isEmpty);
    expect(plugin.portCalls, isEmpty);
  });

  test('writes go out, and reads come back in exact lengths', () async {
    final link = await service.open(cable, baudRate: 9600);
    await link.write([0x53, 0x00, 0x40, 0x40]);
    expect(plugin.written.single, [0x53, 0x00, 0x40, 0x40]);

    // The input arrives in pieces, as a USB transfer hands it over.
    final read = link.read(4, timeout: const Duration(seconds: 2));
    plugin.input!.success(Uint8List.fromList([1, 2]));
    plugin.input!.success(Uint8List.fromList([3, 4, 5]));
    expect(await read, [1, 2, 3, 4]);

    await link.discardInput();
    await expectLater(
      link.read(1, timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
      reason: 'the leftover fifth byte was discarded',
    );
    await link.close();
    expect(plugin.portCalls.last.method, 'close');
  });
}
