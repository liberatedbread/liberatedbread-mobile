// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Yummly and AC Infinity readers against a fake BLE service and the real
// Rust codec: the spec's literal frames, a device that answers garbage or
// nothing, and exactly which bytes are ever written.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/acinfinity_ble_client.dart';
import 'package:liberated_bread_mobile/services/read_only_ble_session.dart';
import 'package:liberated_bread_mobile/services/yummly_ble_client.dart';

import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _yummlyService = '6e40abcd-b5a3-f393-e0a9-e50e4159414d';
const _acInfinityService = '70d51000-2c7f-4e75-ae8a-d758951ce4e0';

List<int> _bytes(String text) => [
  for (final byte in text.split(' ')) int.parse(byte, radix: 16),
];

const _status =
    '1e ff 02 09 07 30 80 01 08 ca 15 7c 00 7a 00 00 00 01 00 00 00 00 27 10 da 02 00 00 00 00 2e e0 00 01 00 00 00 00 ff ff 00 01 00 00 00 00 ff ff 00 01 00 00 00 00';

class _Device extends FakeBleService {
  final StreamController<List<int>> notifications;

  /// Answers a write, by pushing notifications.
  final void Function(List<int> written, _Device device)? onWrite;

  factory _Device(
    String service, {
    void Function(List<int>, _Device)? onWrite,
  }) {
    // ignore: close_sinks — lives as long as the fake device.
    final notifications = StreamController<List<int>>.broadcast();
    return _Device._(notifications, service, onWrite);
  }

  _Device._(this.notifications, String service, this.onWrite)
    : super(
        notifyStream: notifications.stream,
        servicesToReturn: [
          BleDiscoveredService(uuid: service, characteristics: const []),
        ],
      );

  void push(List<int> bytes) => notifications.add(bytes);

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
    onWrite?.call(value, this);
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 60));

Future<T> _next<T>(Stream<T> stream, bool Function(T) test) =>
    stream.firstWhere(test).timeout(const Duration(seconds: 5));

void main() {
  setUpAll(() async {
    if (!await initHostRustLib()) {
      markTestSkipped('host Rust library not available');
    }
  });

  group('Yummly T1', () {
    YummlyBleClient client(
      _Device device, {
      Duration answerWait = const Duration(seconds: 5),
      Duration staleAfter = const Duration(seconds: 5),
    }) => YummlyBleClient(
      ble: device,
      deviceId: 'dock',
      pingWait: const Duration(milliseconds: 40),
      requestGap: const Duration(milliseconds: 5),
      answerWait: answerWait,
      staleAfter: staleAfter,
    );

    test('reads the temperatures the spec frames carry', () async {
      final device = _Device(_yummlyService);
      final yummly = client(device);
      final stream = yummly.watch();
      final core = _next(stream, (r) => r.coreF != null);
      await _settle();
      device.push(_bytes('07 07 01 53 00 5e 00 00 04 01 4b 01 20'));
      expect((await core).coreF, 132.4);

      final body = _next(stream, (r) => r.bodyF != null);
      device.push(_bytes('07 07 01 53 00 5e 00 00 03 02 89 18'));
      expect((await body).bodyF, 275);
      await yummly.close();
      expect(device.disconnectedIds, contains('dock'));
    });

    test('a reading at its clamp carries the flag', () async {
      final device = _Device(_yummlyService);
      final yummly = client(device);
      final core = _next(yummly.watch(), (r) => r.coreF != null);
      await _settle();
      device.push(_bytes('07 07 01 53 00 5e 00 00 04 01 09 01 30'));
      final reading = await core;
      expect(reading.coreF, 212);
      expect(reading.coreAtLimit, isTrue);
      await yummly.close();
    });

    test('writes only the challenge reply and the named reads', () async {
      final device = _Device(
        _yummlyService,
        onWrite: (written, device) {
          if (written[1] == 0x21) {
            device.push(_bytes('07 20 01 53 00 5e 00 00'));
          }
        },
      );
      final yummly = client(device);
      unawaited(yummly.watch().drain<void>().catchError((Object _) {}));
      device.push(_bytes('01 ab'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await yummly.close();

      expect(device.writes.map((w) => w.value).toList(), [
        _bytes('02 aa 02'),
        _bytes('01 09'),
        _bytes('01 16'),
        _bytes('01 21'),
        _bytes('07 07 01 53 00 5e 00 00 01 23'),
        _bytes('07 07 01 53 00 5e 00 00 01 0c'),
      ]);
      for (final write in device.writes) {
        expect(write.charUuid, '6e40aa02-b5a3-f393-e0a9-e50e4159414d');
        // 0xac is the bootloader request.
        expect(write.value.last, isNot(0xac));
      }
    });

    test('answers the challenge even when no ping arrives', () async {
      final device = _Device(_yummlyService);
      final yummly = client(device);
      unawaited(yummly.watch().drain<void>().catchError((Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(device.writes.first.value, _bytes('02 aa 02'));
      await yummly.close();
    });

    test('a dock that says nothing is reported, and let go', () async {
      final device = _Device(_yummlyService);
      final yummly = client(
        device,
        answerWait: const Duration(milliseconds: 80),
      );
      await expectLater(
        yummly.watch(),
        emitsError(
          isA<ReadOnlyBleException>().having(
            (e) => e.message,
            'message',
            contains('did not answer'),
          ),
        ),
      );
      await _settle();
      expect(device.disconnectedIds, contains('dock'));
    });

    test('a dock that only sends garbage is reported as such', () async {
      final device = _Device(_yummlyService);
      // Long enough for the first decode's trip across the FFI boundary, which
      // can take longer than a frame's on a cold library.
      final yummly = client(
        device,
        answerWait: const Duration(milliseconds: 600),
      );
      final stream = yummly.watch();
      final failure = expectLater(
        stream,
        emitsError(
          isA<ReadOnlyBleException>().having(
            (e) => e.message,
            'message',
            contains('not with frames'),
          ),
        ),
      );
      await _settle();
      device.push(_bytes('ff ff ff'));
      device.push(_bytes('00'));
      await failure;
    });

    test('garbage between good frames does not end the session', () async {
      final device = _Device(_yummlyService);
      final yummly = client(device);
      final core = _next(yummly.watch(), (r) => r.coreF != null);
      await _settle();
      device.push(_bytes('ff ff ff'));
      device.push(_bytes('07 07 01 53 00 5e 00 00 04 01 4b 01 20'));
      expect((await core).coreF, 132.4);
      await yummly.close();
    });

    test('a stream that stops marks the reading stale', () async {
      final device = _Device(_yummlyService);
      final yummly = client(
        device,
        staleAfter: const Duration(milliseconds: 40),
      );
      final stale = _next(yummly.watch(), (r) => r.stale);
      await _settle();
      device.push(_bytes('07 07 01 53 00 5e 00 00 04 01 4b 01 20'));
      expect((await stale).coreF, 132.4);
      await yummly.close();
    });

    test('a dock without the T1 service is not spoken to', () async {
      final device = _Device('f84cbbbb-b8bb-494e-86c5-01fd7341f217');
      final yummly = client(device);
      await expectLater(
        yummly.watch(),
        emitsError(
          isA<ReadOnlyBleException>().having(
            (e) => e.message,
            'message',
            contains('T3 and P3'),
          ),
        ),
      );
      expect(device.writes, isEmpty);
    });
  });

  group('AC Infinity', () {
    AcInfinityBleClient client(
      _Device device, {
      Duration answerWait = const Duration(seconds: 5),
    }) => AcInfinityBleClient(
      ble: device,
      deviceId: 'controller',
      answerWait: answerWait,
      replyWait: const Duration(milliseconds: 40),
    );

    test('reads climate and ports from the spec example', () async {
      final device = _Device(_acInfinityService);
      final controller = client(device);
      final first = _next(controller.watch(), (_) => true);
      await _settle();
      device.push(_bytes(_status));
      final status = (await first).status;
      expect(status.temperatureCentiC, 2250);
      expect(status.humidityCentiPercent, 5500);
      expect(status.vpdCentiKpa, 122);
      expect(status.ports[0].outputOn, isTrue);
      expect(status.ports[0].level, 6);
      expect(status.ports[0].mode, 'on');
      expect(status.ports[2].occupied, isFalse);
      await controller.close();
    });

    test('a status frame split across notifications assembles', () async {
      final device = _Device(_acInfinityService);
      final controller = client(device);
      final first = _next(controller.watch(), (_) => true);
      await _settle();
      final frame = _bytes(_status);
      device.push(frame.sublist(0, 20));
      device.push(frame.sublist(20));
      expect((await first).status.selectedPort, 1);
      await controller.close();
    });

    test('every byte it writes is a read of an occupied port', () async {
      final device = _Device(_acInfinityService);
      final controller = client(device);
      unawaited(controller.watch().drain<void>().catchError((Object _) {}));
      await _settle();
      device.push(_bytes(_status));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await controller.close();

      // FakeBleService splits nothing itself; the session sends MTU-sized
      // packets. Rejoined, each frame is get_model_data for port 1 then 2.
      final bytes = [for (final write in device.writes) ...write.value];
      expect(
        bytes,
        hasLength(44),
        reason: 'two 22-byte reads and nothing else',
      );
      for (var start = 0; start < bytes.length; start += 22) {
        final frame = bytes.sublist(start, start + 22);
        expect(frame[0], 0xa5);
        expect(frame[9], 0x01, reason: 'opcode 0x01, a read');
        expect(frame.sublist(10, 18), [
          0x10,
          0x11,
          0x12,
          0x13,
          0x14,
          0x15,
          0x16,
          0x17,
        ]);
        expect(frame[18], 0xff);
      }
      expect(bytes[19], 1);
      expect(bytes[22 + 19], 2);
      for (final write in device.writes) {
        expect(write.charUuid, '70d51001-2c7f-4e75-ae8a-d758951ce4e0');
      }
    });

    test('a controller that says nothing is reported, and let go', () async {
      final device = _Device(_acInfinityService);
      final controller = client(
        device,
        answerWait: const Duration(milliseconds: 60),
      );
      await expectLater(
        controller.watch(),
        emitsError(
          isA<ReadOnlyBleException>().having(
            (e) => e.message,
            'message',
            contains('did not send'),
          ),
        ),
      );
      expect(device.writes, isEmpty);
      await _settle();
      expect(device.disconnectedIds, contains('controller'));
    });

    test('a layout it cannot decode is refused, never misread', () async {
      final device = _Device(_acInfinityService);
      final controller = client(
        device,
        answerWait: const Duration(milliseconds: 600),
      );
      final stream = controller.watch();
      final failure = expectLater(
        stream,
        emitsError(
          isA<ReadOnlyBleException>().having(
            (e) => e.message,
            'message',
            contains('does not decode'),
          ),
        ),
      );
      await _settle();
      // The power strip's 139-byte frame.
      device.push([0x1e, 0xff, 0x02, 0x09, 0x0c, 133, ...List.filled(133, 0)]);
      await failure;
      expect(device.writes, isEmpty);
    });

    test('noise is ignored, and is not a reading', () async {
      final device = _Device(_acInfinityService);
      final controller = client(
        device,
        answerWait: const Duration(milliseconds: 80),
      );
      final stream = controller.watch();
      final failure = expectLater(
        stream,
        emitsError(isA<ReadOnlyBleException>()),
      );
      await _settle();
      device.push([0xde, 0xad, 0xbe, 0xef]);
      await failure;
    });

    test('a read nobody answers costs only the stored levels', () async {
      final device = _Device(_acInfinityService);
      final controller = client(device);
      final stream = controller.watch();
      final first = _next(stream, (_) => true);
      await _settle();
      device.push(_bytes(_status));
      await first;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final later = _next(stream, (_) => true);
      device.push(_bytes(_status));
      final reading = await later;
      expect(reading.stored, isEmpty);
      expect(reading.status.temperatureCentiC, 2250);
      await controller.close();
    });

    test('a stream that stops marks the reading stale', () async {
      final device = _Device(_acInfinityService);
      final controller = AcInfinityBleClient(
        ble: device,
        deviceId: 'controller',
        replyWait: const Duration(milliseconds: 10),
        staleAfter: const Duration(milliseconds: 40),
      );
      final stale = _next(controller.watch(), (r) => r.stale);
      await _settle();
      device.push(_bytes(_status));
      expect((await stale).status.temperatureCentiC, 2250);
      await controller.close();
    });

    test('a device without the service is not written to', () async {
      final device = _Device('180f');
      final controller = client(device);
      await expectLater(
        controller.watch(),
        emitsError(isA<ReadOnlyBleException>()),
      );
      expect(device.writes, isEmpty);
    });
  });
}
