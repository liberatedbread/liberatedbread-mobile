// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The radio protocol across the FFI boundary.
//
// The codec's own properties are proved in Rust, where they belong. What this
// suite is for is the boundary itself: that the generated bindings carry the
// same bytes back that went in, and that Dart sees the same model table Rust
// has -- which is the thing that goes wrong silently after a codegen run.
import 'dart:typed_data';

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

  test('every Rust model has a Dart profile, and they agree', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    // Two tables describing one radio is exactly the arrangement that drifts.
    // A capacity that disagrees would cap a plan short or overrun the
    // codeplug, and neither shows up until a write. Both families are in
    // the one table.
    final models = await radioModels();
    expect([for (final m in models) m.id], containsAll(['uv-5r-mini', 'uv5r']));
    expect(models.firstWhere((m) => m.id == 'uv-5r-mini').imageLen, 0x8240);
    for (final model in models) {
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
      expect(
        block.imageOffset,
        total,
        reason: 'blocks must tile the image with no gap or overlap',
      );
      total += block.len;
    }
    expect(total, 0x8240);
  });

  test('the Bluetooth write plan takes bigger blocks than a read', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');

    final read = await radioReadPlan(modelId: 'uv-5r-mini');
    final write = await radioWritePlan(modelId: 'uv-5r-mini');

    expect(write.first.len, 0x80);
    expect(write.length, lessThan(read.length));
    // Both still describe the same image.
    expect(
      write.fold<int>(0, (sum, b) => sum + b.len),
      read.fold<int>(0, (sum, b) => sum + b.len),
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
    final parsed = await radioParseReadReply(
      reply: reply,
      addr: 0x1234,
      len: 0x40,
    );
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
    expect(await radioReadReplyLen(len: 0x40), 0x44);
  });

  test('acks are recognised', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
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

    final decoded = await radioDecodeChannels(
      image: written,
      modelId: 'uv-5r-mini',
    );
    expect(decoded, hasLength(2));
    expect(decoded[0].name, 'W1AW');
    expect(decoded[0].slot, 1);
    expect(decoded[0].rxFreqHz, 146940000);
    expect(decoded[0].txTone.mode, 'ctcss');
    expect(decoded[0].txTone.ctcssTenthHz, 1000);
    expect(decoded[1].slot, 2);
  });

  test(
    'an image of the wrong size is caught before it is written back',
    () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');

      expect(
        await radioImageIsComplete(imageLen: 0x8240, modelId: 'uv-5r-mini'),
        isTrue,
      );
      // A read cut short must never be written back: the radio would be left
      // holding half a codeplug.
      expect(
        await radioImageIsComplete(imageLen: 0x1000, modelId: 'uv-5r-mini'),
        isFalse,
      );
    },
  );

  test('a short image is refused rather than read past', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    expect(
      () => radioDecodeChannels(image: [1, 2, 3], modelId: 'uv-5r-mini'),
      throwsA(anything),
    );
  });

  group('the UV-5R family', () {
    /// A blank image: ident, empty slots, a firmware string.
    Future<Uint8List> blankImage(String firmware) async {
      final image = Uint8List(await uv5RImageLen());
      image.setRange(0, 8, [0xAA, 0x30, 0x76, 0x04, 0x00, 0x05, 0x20, 0xDD]);
      for (var slot = 0; slot < 128; slot++) {
        image.fillRange(8 + slot * 16, 8 + slot * 16 + 16, 0xFF);
        final name = 8 + 0x1000 + slot * 16;
        image.fillRange(name, name + 16, 0xFF);
      }
      // Radio 0x1EF0 sits at 8 + 0x1800 + (0x1EF0 - 0x1EC0) in the image.
      const firmwareAt = 8 + 0x1800 + 0x30;
      image.fillRange(firmwareAt, firmwareAt + 14, 0xFF);
      image.setRange(
        firmwareAt,
        firmwareAt + firmware.length,
        firmware.codeUnits,
      );
      return image;
    }

    test('channels survive the boundary both ways', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final written = await uv5REncodeChannels(
        image: await blankImage('BFB297'),
        channels: [channel('W1AW')],
        modelId: 'uv5r',
      );
      final read = await uv5RDecodeChannels(image: written, modelId: 'uv5r');
      expect(read.single.name, 'W1AW');
      expect(read.single.rxFreqHz, 146940000);
      expect(read.single.txFreqHz, 146340000);
      expect(read.single.txTone.ctcssTenthHz, 1000);
    });

    test('a write sends only the blocks that changed', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final base = await blankImage('BFB297');
      final updated = await uv5REncodeChannels(
        image: base,
        channels: [channel('W1AW')],
        modelId: 'uv5r',
      );
      final blocks = await uv5RChangedBlocks(
        base: base,
        updated: updated,
        modelId: 'uv5r',
      );
      expect([for (final b in blocks) b.addr], [0x0000, 0x1000]);
    });

    test('band limits cross with their layout', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final applied = await uv5RApplyBandLimits(
        image: await blankImage('BFB290'),
        limits: const BandLimitsDto(
          vhf: BandLimitDto(txEnabled: true, lowerMhz: 136, upperMhz: 174),
          uhf: BandLimitDto(txEnabled: false, lowerMhz: 400, upperMhz: 520),
          layout: '',
        ),
        modelId: 'uv5r',
      );
      final limits = await uv5RReadBandLimits(image: applied, modelId: 'uv5r');
      expect(limits.layout, 'old');
      expect(limits.vhf.lowerMhz, 136);
      expect(limits.uhf.txEnabled, isFalse);
    });

    test('a radio this family does not cover is refused', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      await expectLater(uv5RIdentMagics(modelId: 'uv-5g'), throwsA(anything));
    });
  });
}
