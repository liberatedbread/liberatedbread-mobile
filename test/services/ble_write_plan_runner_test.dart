// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// runImageWritePlan: the write-only path every image upload has always
// taken, and the reply-gated path a request/response printer (NIIMBOT) needs.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ble_write_plan_runner.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ble_service.dart';

const _char = 'print-char';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

/// A printer that answers each write whose third byte is a command it knows,
/// on the notify stream — split across two notifications, as a small MTU
/// would deliver it.
class _ScriptedPrinter extends FakeBleService {
  final Map<int, List<List<int>>> replies;
  _ScriptedPrinter(this.replies) : super(notifyStream: _notify.stream);

  static late StreamController<List<int>> _notify;
  final written = <List<int>>[];

  static _ScriptedPrinter create(Map<int, List<List<int>>> replies) {
    _notify = StreamController<List<int>>.broadcast();
    return _ScriptedPrinter(replies);
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    written.add(value);
    if (value.length < 3) return;
    final queue = replies[value[2]];
    if (queue == null || queue.isEmpty) return;
    final reply = queue.length == 1 ? queue.first : queue.removeAt(0);
    if (reply.isEmpty) return;
    scheduleMicrotask(() {
      _notify.add(reply.sublist(0, 2));
      _notify.add(reply.sublist(2));
    });
  }
}

ReplyWaitDto _wait(int after, int reply, {int timeoutMs = 500}) => ReplyWaitDto(
  afterWrite: after,
  characteristicUuid: _char,
  expectPrefix: _b([0x55, 0x55, reply]),
  errorPrefixes: [
    _b([0x55, 0x55, 0xDB]),
  ],
  timeoutMs: timeoutMs,
);

ImageWriteDto _w(int cmd) =>
    ImageWriteDto(characteristicUuid: _char, bytes: _b([0x55, 0x55, cmd, 1]));

void main() {
  test(
    'a write-only plan writes back to back and subscribes to nothing',
    () async {
      final ble = FakeBleService();
      await runImageWritePlan(
        ble,
        'dev',
        ImageWritePlanDto(
          serviceUuid: 'srv',
          writes: [_w(0x01), _w(0x02)],
          nextFrameIndex: 0,
          replyWaits: const [],
        ),
      );
      expect(ble.writes, hasLength(2));
      expect(ble.subscriptions, isEmpty);
    },
  );

  test('each wait holds the next write until its reply arrives', () async {
    final ble = _ScriptedPrinter.create({
      0x21: [
        [0x55, 0x55, 0x31, 0x01, 0x01, 0x31, 0xAA, 0xAA],
      ],
      0xE3: [
        [0x55, 0x55, 0xE4, 0x01, 0x01, 0xE4, 0xAA, 0xAA],
      ],
      // Status: page 0 twice, then page 1 — done.
      0xA3: [
        [0x55, 0x55, 0xB3, 0x04, 0x00, 0x00, 0x10, 0x00, 0x00, 0xAA, 0xAA],
        [0x55, 0x55, 0xB3, 0x04, 0x00, 0x00, 0x60, 0x00, 0x00, 0xAA, 0xAA],
        [0x55, 0x55, 0xB3, 0x04, 0x00, 0x01, 0x64, 0x64, 0x00, 0xAA, 0xAA],
      ],
      0xF3: [
        [0x55, 0x55, 0xF4, 0x01, 0x01, 0xF4, 0xAA, 0xAA],
      ],
    });
    await runImageWritePlan(
      subscribeSettle: Duration.zero,
      ble,
      'dev',
      ImageWritePlanDto(
        serviceUuid: 'srv',
        writes: [_w(0x21), _w(0x85), _w(0xE3), _w(0xF3)],
        nextFrameIndex: 0,
        replyWaits: [_wait(0, 0x31), _wait(2, 0xE4), _wait(3, 0xF4)],
        completionPoll: CompletionPollDto(
          beforeWrite: 3,
          request: _w(0xA3),
          characteristicUuid: _char,
          replyPrefix: _b([0x55, 0x55, 0xB3]),
          doneOffset: 4,
          doneBytes: _b([0x00, 0x01]),
          intervalMs: 1,
          timeoutMs: 2000,
        ),
      ),
    );
    final commands = ble.written.map((w) => w[2]).toList();
    // PrintEnd only after the third status, the one reporting the page.
    expect(commands, [0x21, 0x85, 0xE3, 0xA3, 0xA3, 0xA3, 0xF3]);
    expect(ble.subscriptions, [_char]);
  });

  test(
    'a reply that never comes is a timeout, and nothing more is sent',
    () async {
      final ble = _ScriptedPrinter.create({});
      await expectLater(
        runImageWritePlan(
          ble,
          'dev',
          ImageWritePlanDto(
            serviceUuid: 'srv',
            writes: [_w(0xC1), _w(0x21)],
            nextFrameIndex: 0,
            replyWaits: [_wait(0, 0xC2, timeoutMs: 50)],
          ),
        ),
        throwsA(isA<TimeoutException>()),
      );
      // The first packet is asked for once more (its reply may have raced
      // the notification enable), and then nothing further is sent.
      expect(ble.written.map((w) => w[2]), [0xC1, 0xC1]);
    },
  );

  test('an error reply is the device refusing', () async {
    final ble = _ScriptedPrinter.create({
      0x21: [
        [0x55, 0x55, 0xDB, 0x01, 0x06, 0xDC, 0xAA, 0xAA],
      ],
    });
    await expectLater(
      runImageWritePlan(
        subscribeSettle: Duration.zero,
        ble,
        'dev',
        ImageWritePlanDto(
          serviceUuid: 'srv',
          writes: [_w(0x21), _w(0x23)],
          nextFrameIndex: 0,
          replyWaits: [_wait(0, 0x31)],
        ),
      ),
      throwsA(isA<DeviceRefusedException>()),
    );
    expect(ble.written, hasLength(1));
  });

  test('an error pattern later in the stream is not a refusal', () async {
    // The expected reply arrives, and its own data happens to contain the
    // bytes of an error prefix further on.
    final ble = _ScriptedPrinter.create({
      0x21: [
        [0x55, 0x55, 0x31, 0x03, 0x55, 0x55, 0xDB, 0x00, 0xAA, 0xAA],
      ],
    });
    await runImageWritePlan(
      subscribeSettle: Duration.zero,
      ble,
      'dev',
      ImageWritePlanDto(
        serviceUuid: 'srv',
        writes: [_w(0x21), _w(0x23)],
        nextFrameIndex: 0,
        replyWaits: [_wait(0, 0x31)],
      ),
    );
    expect(ble.written, hasLength(2));
  });

  test('a status reply split mid-field is read whole', () async {
    // The poll's page counter sits at bytes 4-5; the scripted printer splits
    // every reply after byte 2, so the verdict field arrives in the second
    // notification and must not be judged from the first.
    final ble = _ScriptedPrinter.create({
      0xA3: [
        [0x55, 0x55, 0xB3, 0x04, 0x00, 0x01, 0x64, 0x64, 0x00, 0xAA, 0xAA],
      ],
    });
    await runImageWritePlan(
      subscribeSettle: Duration.zero,
      ble,
      'dev',
      ImageWritePlanDto(
        serviceUuid: 'srv',
        writes: [_w(0xF3)],
        nextFrameIndex: 0,
        replyWaits: const [],
        completionPoll: CompletionPollDto(
          beforeWrite: 0,
          request: _w(0xA3),
          characteristicUuid: _char,
          replyPrefix: _b([0x55, 0x55, 0xB3]),
          doneOffset: 4,
          doneBytes: _b([0x00, 0x01]),
          intervalMs: 1,
          timeoutMs: 1000,
        ),
      ),
    );
    expect(ble.written.map((w) => w[2]), [0xA3, 0xF3]);
  });

  test(
    'a first reply lost to a late subscription is asked for again',
    () async {
      // The printer ignores the first connect (notifications were not on yet)
      // and answers the resend.
      final ble = _ScriptedPrinter.create({
        0xC1: [
          [],
          [0x55, 0x55, 0xC2, 0x01, 0x01, 0xC2, 0xAA, 0xAA],
        ],
      });
      await runImageWritePlan(
        subscribeSettle: Duration.zero,
        ble,
        'dev',
        ImageWritePlanDto(
          serviceUuid: 'srv',
          writes: [_w(0xC1), _w(0x21)],
          nextFrameIndex: 0,
          replyWaits: [_wait(0, 0xC2, timeoutMs: 100)],
        ),
      );
      expect(ble.written.map((w) => w[2]), [0xC1, 0xC1, 0x21]);
    },
  );
}
