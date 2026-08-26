// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'settings_store.dart';

/// The values a device's spec says a client must hold, kept per device and
/// per name.
///
/// The generic form of what three bespoke stores already do one device at a
/// time — [HubCredentialStore] for a Hue bridge's whitelist username,
/// [RoombaCredentialStore] for a robot's BLID and password,
/// [RabbitAirKeyStore] for a purifier's user key. Those exist because each
/// device's credential meant something particular to the flow that obtained
/// it; this exists because the SPEC already names them, and a fourth device
/// arriving with a `credential:` parameter should not need a fourth store.
///
/// The name is the whole contract, and it is the schema's, not this file's:
/// `source: credential:serial` on a command and `issues_credentials: {serial:
/// …}` on a setup method refer to the same stored value by the same spelling,
/// which is what lets a pairing flow's output fill a later request with no
/// per-device table in between. Rust reads that coupling out of the spec
/// (`credentialsForDevice`); this stores what it names.
///
/// Backed by [SettingsStore], so production writes land in the platform
/// keychain and tests inject an in-memory fake.
class DeviceCredentialStore {
  final SettingsStore _store;

  const DeviceCredentialStore(this._store);

  /// `credential.<identity>.<name>`.
  ///
  /// `identity` is the same handle the certificate pin is keyed by
  /// (`identityFor`), and deliberately so: both are things a client learned
  /// about one physical device and must not lose when its lease moves, and a
  /// device known by two different keys would carry two half-populated sets
  /// of secrets. The prefix keeps this namespace clear of the hub/roomba
  /// stores, which key by their own device-issued ids.
  static String _key(String identity, String name) =>
      'credential.$identity.$name';

  /// One stored value, or null when this device has never been given it.
  Future<String?> read(String identity, String name) async {
    final value = await _store.read(_key(identity, name));
    // An empty string is not a credential: it renders a path with a blank
    // segment, which reaches the device as a request for somebody else's
    // resource rather than as a visible failure.
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> save(String identity, String name, String value) =>
      _store.write(_key(identity, name), value);

  Future<void> forgetOne(String identity, String name) =>
      _store.delete(_key(identity, name));

  /// Every credential stored for one device, name → value.
  ///
  /// This is what a send needs: the renderer fills `credential:` parameters
  /// by name out of one map, and asking per name would mean knowing the names
  /// before reading the spec. Values that are empty are omitted for the reason
  /// [read] gives.
  Future<Map<String, String>> credentials(String identity) async {
    final prefix = _key(identity, '');
    final all = await _store.readAll();
    return {
      for (final entry in all.entries)
        if (entry.key.startsWith(prefix) && entry.value.isNotEmpty)
          entry.key.substring(prefix.length): entry.value,
    };
  }

  /// Forget everything stored for one device — the un-pair half, which the
  /// forget-device flow calls so a removed device leaves nothing behind.
  Future<void> forget(String identity) async {
    final prefix = _key(identity, '');
    final all = await _store.readAll();
    for (final key in all.keys) {
      if (key.startsWith(prefix)) await _store.delete(key);
    }
  }
}
