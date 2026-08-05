// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/spec_choice_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SpecChoiceStore> _store([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SpecChoiceStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('empty store loads as an empty map', () async {
    final store = await _store();
    expect(store.load(), isEmpty);
  });

  test('save/load round-trips and overwrites per device', () async {
    final store = await _store();
    await store.save('AA:BB', 'SmartDawn Smart Lights|Daniao');
    await store.save('CC:DD', 'Other|X');
    await store.save('AA:BB', 'SuperPix|Daniao'); // user changed their mind

    expect(store.load(), {
      'AA:BB': 'SuperPix|Daniao',
      'CC:DD': 'Other|X',
    });
  });

  test('remove forgets one device and keeps the rest', () async {
    final store = await _store();
    await store.save('AA:BB', 'A|A');
    await store.save('CC:DD', 'B|B');
    await store.remove('AA:BB');

    expect(store.load(), {'CC:DD': 'B|B'});
  });

  test('a corrupt blob loads as empty instead of throwing at startup',
      () async {
    final store = await _store({'spec_choices_v1': 'not-json{'});
    expect(store.load(), isEmpty);
  });

  test('non-map json and non-string values are ignored', () async {
    expect((await _store({'spec_choices_v1': '[1,2]'})).load(), isEmpty);
    final mixed = await _store({
      'spec_choices_v1': jsonEncode({'ok': 'kept', 'bad': 7}),
    });
    expect(mixed.load(), {'ok': 'kept'});
  });
}
