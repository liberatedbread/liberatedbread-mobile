// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The radio protocol across the FFI boundary.
//
// The codec's own properties are proved in Rust, where they belong. What this
// suite is for is the boundary itself: that the generated bindings carry the
// same bytes back that went in, and that Dart sees the same model table Rust
// has -- which is the thing that goes wrong silently after a codegen run.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart';

import '../helpers/host_rust_lib.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;

  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  ToneDto noTone() => const ToneDto(
        mode: 'none',
        ctcssTenthHz: 0,
        dcsCode: 0,
        dcsInverted: false,
      );

  RadioChannelDto channel(String name) => RadioChannelDto(
        slot: 1,
        name: name,
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        rxOnly: false,
        txTone: const ToneDto(
          mode: 'ctcss',
          ctcssTenthHz: 1000,
          dcsCode: 0,
          dcsInverted: false,
        ),
        rxTone: noTone(),
        narrow: false,
        lowPower: false,
        skip: false,
      );

  test('the model table crosses the boundary intact', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    final models = await radioModels();
    expect(models, isNotEmpty);
    final mini = models.firstWhere((m) => m.id == 'uv-5r-mini');
    expect(mini.identMagic, hasLength(16));
    expect(mini.channelCount, 999);
    expect(mini.nameLen, 12);
    expect(mini.imageLen, 0x8240);
  });

  test('every Rust model has a Dart profile, and they agree', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    // Two tables describing one radio is exactly the arrangement that drifts.
    // A capacity that disagrees would cap a plan short or overrun the
    // codeplug, and neither shows up until a write.
    for (final model in await radioModels()) {
      final profile = radioProfileById(model.id);
      expect(profile, isNotNull, reason: 'no Dart profile for ${model.id}');
      expect(profile!.channelCapacity, model.channelCount, reason: model.id);
      expect(profile.nameLength, model.nameLen, reason: model.id);
    }
  });

  test('the read plan covers the whole image exactly once', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    final plan = await radioReadPlan(modelId: 'uv-5r-mini');
    expect(plan, isNotEmpty);

    var total = 0;
    for (final block in plan) {
      expect(block.imageOffset, total,
          reason: 'blocks must tile the image with no gap or overlap');
      total += block.len;
    }
    expect(total, 0x8240);
  });

  test('a write plan can use a different block size', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    final serial = await radioWritePlan(modelId: 'uv-5r-mini', blockSize: 0x40);
    final ble = await radioWritePlan(
        modelId: 'uv-5r-mini', blockSize: await radioBleWriteBlockSize());

    expect(await radioBleWriteBlockSize(), 0x80);
    expect(ble.length, lessThan(serial.length));
    // Both still describe the same image.
    expect(
      ble.fold<int>(0, (sum, b) => sum + b.len),
      serial.fold<int>(0, (sum, b) => sum + b.len),
    );
  });

  test('an unknown model is an error, not an empty plan', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    expect(() => radioReadPlan(modelId: 'nokia-3310'), throwsA(anything));
  });

  test('a read reply round-trips through the parser', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    // Build a reply the way a radio would: the echoed header, then the
    // payload with the substitution applied. There is no encode entry point,
    // so the substitution is exercised by writing a block and reading the
    // scrambled bytes back out of the frame.
    final payload = List<int>.generate(0x40, (i) => (i * 7 + 3) & 0xFF);
    final writeFrame = await radioWriteCommand(addr: 0x1234, data: payload);
    final scrambled = writeFrame.sublist(4);

    final reply = <int>[0x52, 0x12, 0x34, 0x40, ...scrambled];
    final parsed =
        await radioParseReadReply(reply: reply, addr: 0x1234, len: 0x40);
    expect(parsed, payload);
  });

  test('a reply for the wrong address is refused', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    final reply = <int>[0x52, 0x12, 0x34, 0x40, ...List.filled(0x40, 0)];
    expect(
      () => radioParseReadReply(reply: reply, addr: 0x9000, len: 0x40),
      throwsA(anything),
    );
  });

  test('the expected reply length includes the header', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    expect(await radioExpectedReplyLen(len: 0x40), 0x44);
  });

  test('acks are recognised', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    expect(await radioAckByte(), 0x06);
    expect(await radioIsAck(reply: [0x06]), isTrue);
    expect(await radioIsAck(reply: [0x15]), isFalse);
    expect(await radioIsAck(reply: []), isFalse);
  });

  test('the handshake is three steps with known reply lengths', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    final steps = await radioHandshakeSteps();
    expect(steps, hasLength(3));
    expect(steps[0].expectedReplyLen, 16);
    expect(steps[1].expectedReplyLen, 15);
    expect(steps[2].expectedReplyLen, 1);
    expect(steps[2].request.length, 25);
  });

  test('channels round-trip through an image', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    final blank = List<int>.filled(0x8240, 0xFF);
    final written = await radioEncodeChannels(
      image: blank,
      channels: [channel('W1AW'), channel('SECOND')],
      modelId: 'uv-5r-mini',
    );
    expect(written, hasLength(blank.length));

    final decoded =
        await radioDecodeChannels(image: written, modelId: 'uv-5r-mini');
    expect(decoded, hasLength(2));
    expect(decoded[0].name, 'W1AW');
    expect(decoded[0].slot, 1);
    expect(decoded[0].rxFreqHz, 146940000);
    expect(decoded[0].txTone.mode, 'ctcss');
    expect(decoded[0].txTone.ctcssTenthHz, 1000);
    expect(decoded[1].slot, 2);
  });

  test('an image of the wrong size is caught before it is written back',
      () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    expect(await radioImageIsComplete(imageLen: 0x8240, modelId: 'uv-5r-mini'),
        isTrue);
    // A read cut short must never be written back: the radio would be left
    // holding half a codeplug.
    expect(await radioImageIsComplete(imageLen: 0x1000, modelId: 'uv-5r-mini'),
        isFalse);
  });

  test('a short image is refused rather than read past', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    expect(
      () => radioDecodeChannels(image: [1, 2, 3], modelId: 'uv-5r-mini'),
      throwsA(anything),
    );
  });
}
