// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// DirectAttRegistry (which devices the Linux router sends direct) and
// installDirectAttRouter's guards (when it wraps the platform at all).

import 'dart:io' show Platform;

import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_registry.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_router.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';

import '../../fakes/in_memory_settings_store.dart';

const _meter = '18:7A:93:12:DE:94';

/// A store whose every call fails, as a broken preferences backend would.
class _BrokenStore implements SettingsStore {
  @override
  Future<String?> read(String key) async => throw StateError('broken');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('broken');
  @override
  Future<void> delete(String key) async => throw StateError('broken');
  @override
  Future<Map<String, String>> readAll() async => throw StateError('broken');
}

void main() {
  group('DirectAttRegistry', () {
    test('starts from what the store holds, in any case', () async {
      final registry = DirectAttRegistry.over(
        InMemorySettingsStore({DirectAttRegistry.key: '["18:7a:93:12:de:94"]'}),
      );
      await registry.ready;
      expect(registry.contains(_meter), isTrue);
      expect(registry.contains(_meter.toLowerCase()), isTrue);
      expect(registry.contains('AA:AA:AA:AA:AA:AA'), isFalse);
    });

    test('persists additions sorted and upper-cased, once', () async {
      final store = InMemorySettingsStore();
      final registry = DirectAttRegistry.over(store);
      await registry.add('bb:bb:bb:bb:bb:bb');
      await registry.add(_meter);
      await registry.add(_meter.toLowerCase());
      expect(
        store.values[DirectAttRegistry.key],
        '["$_meter","BB:BB:BB:BB:BB:BB"]',
      );
    });

    test('forgets a device on request', () async {
      final store = InMemorySettingsStore();
      final registry = DirectAttRegistry.over(store);
      await registry.add(_meter);
      await registry.remove(_meter.toLowerCase());
      expect(registry.contains(_meter), isFalse);
      expect(store.values[DirectAttRegistry.key], '[]');
    });

    test('forced ids route without ever being written down', () async {
      final store = InMemorySettingsStore();
      final registry = DirectAttRegistry.over(
        store,
        forced: [_meter.toLowerCase()],
      );
      await registry.ready;
      expect(registry.contains(_meter), isTrue);
      expect(registry.devices, {_meter});
      await registry.remove(_meter);
      expect(registry.contains(_meter), isTrue, reason: 'still forced');
      expect(store.values, isEmpty);
    });

    test('a corrupt preference reads as an empty list', () async {
      final registry = DirectAttRegistry.over(
        InMemorySettingsStore({DirectAttRegistry.key: 'not json'}),
      );
      await registry.ready;
      expect(registry.devices, isEmpty);
    });

    test('a store that fails is survived, not thrown', () async {
      final registry = DirectAttRegistry.over(_BrokenStore());
      await registry.ready;
      expect(registry.devices, isEmpty);
      await registry.add(_meter);
      expect(registry.contains(_meter), isTrue, reason: 'held in memory');
    });
  });

  // The router is Linux's by design: anywhere else installing it is a no-op.
  group('installDirectAttRouter', skip: !Platform.isLinux, () {
    final store = Future<SettingsStore>.value(InMemorySettingsStore());

    test('does nothing when told LB_DIRECT_ATT=off', () {
      FlutterBluePlusPlatform.instance = FlutterBluePlusLinux();
      expect(
        installDirectAttRouter(store, environment: {'LB_DIRECT_ATT': 'off'}),
        isNull,
      );
      expect(FlutterBluePlusPlatform.instance, isA<FlutterBluePlusLinux>());
    });

    test('wraps only the stock BlueZ backend', () {
      final other = _OtherPlatform();
      FlutterBluePlusPlatform.instance = other;
      expect(installDirectAttRouter(store, environment: const {}), isNull);
      expect(FlutterBluePlusPlatform.instance, same(other));
    });

    test('wraps BlueZ once, and is idempotent', () async {
      final bluez = FlutterBluePlusLinux();
      FlutterBluePlusPlatform.instance = bluez;
      final router = installDirectAttRouter(
        store,
        environment: {'LB_DIRECT_ATT': '$_meter, not-an-address'},
      );
      expect(router, isNotNull);
      expect(router!.inner, same(bluez));
      expect(FlutterBluePlusPlatform.instance, same(router));
      expect(
        installDirectAttRouter(store, environment: const {}),
        same(router),
      );
      await router.registry.ready;
      expect(router.registry.forced, {_meter}, reason: 'the bad entry dropped');
    });
  });
}

final class _OtherPlatform extends FlutterBluePlusPlatform {}
