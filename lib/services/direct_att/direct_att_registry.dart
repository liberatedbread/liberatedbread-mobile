// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Which devices the Linux router sends to the direct ATT path instead of
// BlueZ, persisted so the decision survives restarts.
//
// A device lands here only after BlueZ has visibly failed it the way the
// silent Server Supported Features probe makes it fail AND the direct walk
// then found services on it (see DirectAttRouter) — so an entry is a verified
// fact about that peripheral, not a guess, and the next connection skips the
// half minute of waiting for bluetoothd to give up. Nothing here is specific
// to any one device.

import 'dart:convert';

import '../../core/log.dart';
import '../settings_store.dart';

/// The devices routed to the direct ATT path. See the file comment.
class DirectAttRegistry {
  /// The preference key. A JSON list of device ids.
  static const String key = 'ble.linux.direct_att_devices';

  final Future<SettingsStore> _store;
  final Set<String> _devices = {};

  /// Ids routed direct for this process only, never persisted: the
  /// `LB_DIRECT_ATT=<mac>[,<mac>...]` override, for a device the user already
  /// knows BlueZ cannot enumerate and would rather not wait out the stall on.
  final Set<String> forced;

  /// Ids the spec catalogue says BlueZ cannot drive (a spec's
  /// `device.host_compatibility`), declared by the router as it connects
  /// them. In memory only: the stored list is for devices a hand-over
  /// VERIFIED, and a spec claim is re-derived on every run, so a corrected
  /// spec takes effect instead of lingering in preferences.
  final Set<String> _declared = {};

  late final Future<void> ready = _load();

  DirectAttRegistry(this._store, {Iterable<String> forced = const []})
    : forced = {for (final id in forced) normalizeDeviceId(id)};

  /// A registry over an already-open [store] — an in-memory one, in tests.
  DirectAttRegistry.over(
    SettingsStore store, {
    Iterable<String> forced = const [],
  }) : this(Future.value(store), forced: forced);

  /// The spelling ids are kept in. BlueZ names devices by upper-case address,
  /// and flutter_blue_plus's DeviceIdentifier hashes case-sensitively, so
  /// the registry compares in one case and the router echoes whatever
  /// spelling the caller used.
  static String normalizeDeviceId(String id) => id.trim().toUpperCase();

  Future<void> _load() async {
    try {
      final raw = await (await _store).read(key);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _devices.addAll(decoded.whereType<String>().map(normalizeDeviceId));
      }
    } catch (e) {
      Log.ble.warning('could not load the direct ATT device list', error: e);
    }
  }

  /// Every routed device: remembered, forced and declared. Valid once
  /// [ready] has completed.
  Set<String> get devices =>
      Set.unmodifiable({..._devices, ...forced, ..._declared});

  /// Whether [deviceId] is routed direct. Valid once [ready] has completed.
  bool contains(String deviceId) {
    final id = normalizeDeviceId(deviceId);
    return _devices.contains(id) ||
        forced.contains(id) ||
        _declared.contains(id);
  }

  /// Route [deviceId] direct for this process, on the catalogue's word.
  void declare(String deviceId) => _declared.add(normalizeDeviceId(deviceId));

  /// Whether [deviceId] is routed direct only on the catalogue's word.
  bool isDeclared(String deviceId) =>
      _declared.contains(normalizeDeviceId(deviceId));

  /// Remember [deviceId] as routed direct.
  Future<void> add(String deviceId) async {
    await ready;
    if (!_devices.add(normalizeDeviceId(deviceId))) return;
    await _persist();
  }

  /// Stop routing [deviceId] direct, remembered or declared (a forced id
  /// stays forced).
  Future<void> remove(String deviceId) async {
    await ready;
    final id = normalizeDeviceId(deviceId);
    _declared.remove(id);
    if (!_devices.remove(id)) return;
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await (await _store).write(key, jsonEncode(_devices.toList()..sort()));
    } catch (e) {
      Log.ble.warning('could not save the direct ATT device list', error: e);
    }
  }
}
