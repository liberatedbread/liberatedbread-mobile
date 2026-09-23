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

class _FakePlugin {
  List<Map<String, Object?>> devices = [];
  bool grant = true;
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
    id: '1003',
    name: '/dev/bus/usb/001/003',
    vendorId: 0x1A86,
    productId: 0x7523,
  );

  test('is available: Android reaches cables through USB host', () {
    expect(service.availability.supported, isTrue);
  });

  test('lists each plugged-in device as a port', () async {
    plugin.devices = [
      {
        'deviceName': '/dev/bus/usb/001/003',
        'vid': 0x1A86,
        'pid': 0x7523,
        'productName': 'USB Serial',
        'manufacturerName': 'QinHeng',
        'deviceId': 1003,
        'serialNumber': null,
        'interfaceCount': 1,
      },
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
    expect(ports.single.id, '1003');
    expect(ports.single.displayName, 'USB Serial');
    expect(ports.single.manufacturer, 'QinHeng');
    expect(ports.single.bridge?.name, 'WCH CH340');
  });

  test('opens at the rate asked, 8N1, with DTR and RTS raised', () async {
    final link = await service.open(cable, baudRate: 9600);
    final methods = [for (final c in plugin.portCalls) c.method];
    expect(methods, containsAllInOrder(['open', 'setPortParameters']));
    final params = plugin.portCalls
        .firstWhere((c) => c.method == 'setPortParameters')
        .arguments as Map;
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
      throwsA(isA<SerialPortException>()
          .having((e) => e.message, 'message', contains('allow it'))),
    );
  });

  test('a cable that will not open says what to do', () async {
    plugin.openSucceeds = false;
    await expectLater(
      service.open(cable, baudRate: 9600),
      throwsA(isA<SerialPortException>()
          .having((e) => e.message, 'message', contains('plug it back in'))),
    );
  });

  test('a port that is not a USB device id is refused before anything',
      () async {
    await expectLater(
      service.open(const SerialPortInfo(id: '/dev/ttyUSB0', name: 'x'),
          baudRate: 9600),
      throwsA(isA<SerialPortException>()),
    );
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
