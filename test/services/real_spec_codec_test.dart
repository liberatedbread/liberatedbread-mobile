// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Exercises the real flutter_rust_bridge path through [RealSpecCodec] against
// the bundled example spec. Requires the host-target Rust library (cargo build
// + LD_LIBRARY_PATH, same as CI); the group is skipped if it isn't loaded.
import 'dart:typed_data' show Uint16List;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../helpers/host_rust_lib.dart';

const _cmdChar = '0000fff1-0000-1000-8000-00805f9b34fb';
const _statusChar = '0000fff2-0000-1000-8000-00805f9b34fb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = RealSpecCodec();
  late final bool rustReady;
  late final String yaml;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    yaml = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/examples/example-bulb.yaml');
  });

  test('loadDeviceSpec parses the bundled bulb spec', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final spec = await codec.loadDeviceSpec(yaml);
    expect(spec.deviceName, 'Example Smart Bulb');
    expect(spec.localNamePrefixes, const ['ACME_']);

    final control =
        spec.services.firstWhere((s) => s.name == 'Control Service');
    final command = control.characteristics.first;
    // Exact list, in order: the spec's declaration order has to survive the
    // YAML parse and the FFI round-trip, because it is the order the device
    // screen renders the controls in.
    expect(
      command.commands.map((c) => c.name).toList(),
      <String>['power_on', 'power_off', 'set_brightness', 'set_color'],
    );
    expect(
      command.commands
          .firstWhere((c) => c.name == 'set_color')
          .parameters
          .map((p) => p.name)
          .toList(),
      <String>['red', 'green', 'blue'],
    );
    expect(
      command.commands.firstWhere((c) => c.name == 'power_on').isFixed,
      isTrue,
    );
    final setBrightness =
        command.commands.firstWhere((c) => c.name == 'set_brightness');
    expect(setBrightness.isFixed, isFalse);
    expect(setBrightness.parameters.single.name, 'brightness');
  });

  test('encodeCommand produces the spec-defined bytes', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final powerOn = await codec.encodeCommand(
      specYaml: yaml,
      charUuid: _cmdChar,
      commandName: 'power_on',
      params: const {},
    );
    expect(powerOn, [1, 1]);

    final setBrightness = await codec.encodeCommand(
      specYaml: yaml,
      charUuid: _cmdChar,
      commandName: 'set_brightness',
      params: const {'brightness': 50.0},
    );
    expect(setBrightness, [2, 50]);
  });

  test('decodeValue names the status fields', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final decoded = await codec.decodeValue(
      specYaml: yaml,
      charUuid: _statusChar,
      bytes: const [1, 80, 255, 180, 50],
    );
    // Ordered, not just present: decoded fields come back in the spec's
    // `format` order, which is what the UI lists them in.
    expect(
      decoded.map((d) => d.name).toList(),
      <String>['power_state', 'brightness', 'red', 'green', 'blue'],
    );
    final byName = {for (final d in decoded) d.name: d};
    expect(byName['brightness']!.uintValue, 80);
  });

  test('matchDeviceToSpec matches by name prefix', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final spec = await codec.loadDeviceSpec(yaml);
    final matches = await codec.matchDeviceToSpec(
      specs: [spec],
      deviceName: 'ACME_Living_Room',
      advertisedServiceUuids: const [],
    );
    expect(matches, isNotEmpty);
    expect(matches.first.matchedByNamePrefix, isTrue);
  });

  // ── the pass-throughs that nothing was calling ────────────────────────────
  //
  // Four of RealSpecCodec's methods had never been executed — 8 of its 19 lines
  // — because every widget test drives FakeSpecCodec instead, and the widgets
  // are where these are called from. Each is "a thin pass-through to the
  // generated FFI function", which is exactly the kind of code that looks too
  // boring to test and then transposes two arguments: `width`/`height` and
  // `frameIndex`/`maxPayloadPerWrite` are adjacent ints, and a swap compiles.
  //
  // These deliberately do NOT re-test the Rust behaviour — rust/tests and the
  // crate's own unit tests own that, and cargo llvm-cov now measures it. What
  // they pin is that the Dart side names its arguments correctly on the way in
  // and hands back what came out.

  test('matchNetworkDevice reaches the network matcher', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    // Built by hand rather than read from a spec: the point is the argument
    // wiring, and an identity written here says exactly which field is
    // expected to do the matching.
    final identity = SpecIdentityDto(
      deviceName: 'Philips Hue Bridge',
      manufacturer: 'Signify',
      localNamePrefixes: const [],
      serviceUuids: const [],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceType: '_hue._tcp.local.',
      ssdpSearchTargets: const [],
      defaultPort: 80,
    );
    const device = NetworkDeviceDto(
      name: 'Philips Hue',
      hostname: 'Philips-hue.local',
      serviceTypes: ['_hue._tcp.local'],
      ssdpTargets: [],
      port: 443,
    );

    final matches = await codec.matchNetworkDevice(
      identities: [identity],
      device: device,
    );

    expect(matches, isNotEmpty,
        reason: 'the advertised mDNS service type is the identity it matches');
    expect(matches.first.specIndex, 0,
        reason: 'the index has to point back into the list that was passed in');
    expect(matches.first.deviceName, 'Philips Hue Bridge');
  });

  test('identifyStandardProfiles names a well-known service', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final profiles = await codec.identifyStandardProfiles(
      const ['0000180f-0000-1000-8000-00805f9b34fb'],
    );

    expect(profiles, hasLength(1));
    expect(profiles.single.serviceUuid, '0000180f-0000-1000-8000-00805f9b34fb');
    expect(profiles.single.profileName, contains('Battery'));
  });

  test('encodeEntityValue sends the value to the entity that owns it',
      () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    // Gerbing is the direct-write setpoint: the raw byte IS the percentage, so
    // a mis-passed argument shows up as a wrong number rather than as a
    // plausible-looking blob.
    final gerbing = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/gerbing-thermogauge.yaml');

    final write = await codec.encodeEntityValue(
      specYaml: gerbing,
      entityName: 'Heat Level 1',
      value: 60,
    );
    expect(write.bytes, orderedEquals(<int>[60]));

    // Channel 2 is a different characteristic, and sending channel 2's value to
    // channel 1 is the failure a swapped entity name would produce.
    final other = await codec.encodeEntityValue(
      specYaml: gerbing,
      entityName: 'Heat Level 2',
      value: 60,
    );
    expect(other.characteristicUuid, isNot(write.characteristicUuid));
  });

  test('encodeImageFrame keeps width, height and the frame index apart',
      () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final display = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/smartdawn-smart-lights.yaml');

    // Each of the four numeric arguments is checked by something it alone can
    // move. They are adjacent ints in the signature, and a transposition
    // compiles.
    //
    // A solid 40x34 canvas encodes as ONE TUTU chunk, so frame 0 is exactly
    // three logical packets: ui_end_sync + doodle_start (the session open)
    // and the pixel chunk. The frame index must come back advanced by all
    // three — advancing by one would make the next frame's serials collide
    // with this frame's and corrupt fragment reassembly on the device.
    final first = await codec.encodeImageFrame(
      specYaml: display,
      width: 40,
      height: 34,
      rgb: List<int>.filled(40 * 34 * 3, 0xAB),
      frameIndex: 0,
      maxPayloadPerWrite: 509,
    );

    expect(first.nextFrameIndex, 3, reason: 'frameIndex reached the encoder');
    expect(first.writes, hasLength(3));
    expect(first.serviceUuid, isNotEmpty);
    expect(
      first.writes.every((w) => w.bytes.length <= 509),
      isTrue,
      reason: 'no BLE write may exceed maxPayloadPerWrite',
    );

    // A later frame skips the session open, streams on the OTHER (bulk)
    // characteristic, and derives its fragment serial from frameIndex —
    // which is how that argument proves it arrived.
    final later = await codec.encodeImageFrame(
      specYaml: display,
      width: 40,
      height: 34,
      rgb: List<int>.filled(40 * 34 * 3, 0xAB),
      frameIndex: first.nextFrameIndex,
      maxPayloadPerWrite: 509,
    );
    expect(later.writes, hasLength(1));
    expect(later.writes.single.bytes[0], first.nextFrameIndex);
    expect(later.nextFrameIndex, first.nextFrameIndex + 1);
    expect(
      later.writes.single.characteristicUuid,
      isNot(first.writes.first.characteristicUuid),
      reason: 'pixels go to the bulk channel, not the command channel',
    );

    // maxPayloadPerWrite is enforced, not advisory: at the 20-byte BLE floor
    // this canvas's single chunk cannot fit one write, and the device does
    // not reassemble split chunks, so the encoder must refuse.
    await expectLater(
      codec.encodeImageFrame(
        specYaml: display,
        width: 40,
        height: 34,
        rgb: List<int>.filled(40 * 34 * 3, 0xAB),
        frameIndex: 5,
        maxPayloadPerWrite: 20,
      ),
      throwsA(anything),
    );

    // And width/height: the encoder rejects a pixel buffer that is not
    // width x height x 3, so a swapped or dropped dimension cannot pass
    // unnoticed.
    await expectLater(
      codec.encodeImageFrame(
        specYaml: display,
        width: 40,
        height: 34,
        rgb: List<int>.filled(40 * 33 * 3, 0xAB),
        frameIndex: 0,
        maxPayloadPerWrite: 20,
      ),
      throwsA(anything),
    );
  });
}
