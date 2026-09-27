// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The fake keeps RadioProgrammer.readCodeplug's ordering contract: the image
// reaches onResult BEFORE the last event, as SerialRadioProgrammer and
// BaofengBleProgrammer do. It used to yield every event first, so a screen
// that treated the final `done` as "result ready" would pass against the fake
// and misbehave on hardware.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

import 'fake_radio_programmer.dart';

void main() {
  test('readCodeplug hands over the image before the last event', () async {
    final order = <String>[];
    await FakeRadioProgrammer()
        .readCodeplug(
          deviceId: 'd',
          profile: uv5rProfile,
          onResult: (_) => order.add('result'),
        )
        .forEach((event) => order.add(event.stage.name));
    expect(order, [RadioProgressStage.connecting.name, 'result', 'done']);
  });

  test('with no events it still hands over the image', () async {
    var results = 0;
    final events = await FakeRadioProgrammer(events: const [])
        .readCodeplug(
          deviceId: 'd',
          profile: uv5rProfile,
          onResult: (_) => results++,
        )
        .toList();
    expect(events, isEmpty);
    expect(results, 1);
  });
}
