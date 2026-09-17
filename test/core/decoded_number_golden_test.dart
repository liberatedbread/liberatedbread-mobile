// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The number-semantics contract, end to end: real bytes through the real
// decoder, read back through decoded_number.dart.
//
// The unit tests on either side of the FFI each check one half —
// `codec::number::tests` that the arithmetic is right, `decoded_number_test`
// that the reader picks the right field. Neither would notice the two drifting
// apart: a DTO field renamed, a transform stopped being applied, a reading
// arriving raw. This file is the pin. It is also the regression test for the
// state this replaced, where the GATT browser printed "2350" for the same
// characteristic an entity card rendered as "23.50".
//
// Skips (rather than fails) when the host Rust library will not load — see
// helpers/host_rust_lib.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/decoded_number.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart' as rust;
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../helpers/host_rust_lib.dart';

const _thermoChar = '00002a6e-0000-1000-8000-00805f9b34fb';
const _gearChar = '0000fff1-0000-1000-8000-00805f9b34fb';
const _stateChar = '0000fff2-0000-1000-8000-00805f9b34fb';

const _yaml =
    '''
device:
  name: Golden
  manufacturer: Test
  manufacturer_status: abandoned
  protocol: ble
services:
  - uuid: 0000181a-0000-1000-8000-00805f9b34fb
    name: Environmental Sensing
    characteristics:
      - uuid: $_thermoChar
        name: Temperature
        properties: ["read"]
        format:
          - name: temperature
            type: int16
            offset: 0
            length: 2
            scale: 0.01
            unit: "C"
  - uuid: 0000fff0-0000-1000-8000-00805f9b34fb
    name: Vendor
    characteristics:
      - uuid: $_gearChar
        name: Probe
        properties: ["read"]
        format:
          - name: probe
            type: uint8
            offset: 0
            length: 1
            scale: 0.5
            value_offset: 85
            unit: "F"
            unit_source: device_setting
      - uuid: $_stateChar
        name: State
        properties: ["read"]
        format:
          - name: liquid_state
            type: uint8
            offset: 0
            length: 1
            values:
              0: standby
              5: heating
          - name: battery_percent
            type: uint8
            offset: 1
            length: 1
            unit: "%"
''';

Future<List<DecodedValueDto>> _decode(String charUuid, List<int> bytes) =>
    rust.decodeValue(specYaml: _yaml, charUuid: charUuid, bytes: bytes);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  test('a scaled reading arrives transformed and rendered', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    // 2350 centidegrees. The raw integer is still there beside the answer —
    // decoding stays lossless — but nothing downstream has to do the sum.
    final decoded = await _decode(_thermoChar, [0x2e, 0x09]);
    final field = decoded.single;

    expect(field.intValue, 2350);
    expect(rawNumberOf(field), 2350.0);
    expect(decodedNumberOf(field), closeTo(23.5, 1e-9));
    expect(decodedTextOf(field), '23.50');
    expect(labelledTextOf(field), '23.50');
    expect(unitOf(field), 'C');
    expect(field.decimals, 2);
  });

  test('scale AND value_offset both survive the crossing', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    // raw * 0.5 + 85. Dropping the offset reported a 135 F probe as 50 F.
    final field = (await _decode(_gearChar, [100])).single;

    expect(decodedNumberOf(field), closeTo(135.0, 1e-9));
    expect(decodedTextOf(field), '135.0');
    // ... and the unit is NOT stated, because the spec says the device owns
    // it. The same raw 100 is °C or °F depending on how the probe is set.
    expect(unitOf(field), isNull);
    expect(unitFollowsDeviceSetting(field), isTrue);
    expect(unitOf(field, entityUnit: '°F'), '°F');
  });

  test('an untransformed reading stays the integer it is', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final decoded = await _decode(_stateChar, [5, 80]);
    final battery = decoded.firstWhere((d) => d.name == 'battery_percent');

    expect(decodedNumberOf(battery), 80.0);
    // "80", never "80.00": a battery percentage has no decimals to claim.
    expect(decodedTextOf(battery), '80');
    expect(battery.decimals, 0);
    expect(unitOf(battery), '%');
  });

  test('a code table names the reading and the code stays beside it', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final decoded = await _decode(_stateChar, [5, 80]);
    final state = decoded.firstWhere((d) => d.name == 'liquid_state');

    expect(labelledTextOf(state), 'heating');
    expect(decodedTextOf(state), '5');
    expect(state.isOn, isTrue);

    final standby = (await _decode(_stateChar, [0, 80])).first;
    expect(labelledTextOf(standby), 'standby');
    expect(standby.isOn, isFalse);
  });

  test('the entity overlay rounds what Rust rendered', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    // 2347 centidegrees: 23.47 as encoded, "about 23.5" to a probe that only
    // knows tenths.
    final field = (await _decode(_thermoChar, [0x2b, 0x09])).single;

    expect(decodedTextOf(field), '23.47');
    expect(decodedTextOf(field, precision: 0.1), '23.5');
    expect(decodedTextOf(field, precision: 1), '23');
    // The number itself is untouched — a control seeds from this.
    expect(decodedNumberOf(field), closeTo(23.47, 1e-9));
    // An entity scale replaces the field's transform rather than compounding.
    expect(decodedNumberOf(field, scaleOverride: 0.1), closeTo(234.7, 1e-9));
  });
}
