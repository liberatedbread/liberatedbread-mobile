// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'settings_store.dart';
import 'package:liberated_bread_mobile/core/log.dart';

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
  ///
  /// The name is the LAST segment and holds no dot of its own — see
  /// [_nameIn], which is what makes one device's keys separable from
  /// another's. Spec credential names are identifiers (`serial`, `username`,
  /// `blid`, `appliance_id`, `mqtt_client_id`), so the restriction costs
  /// nothing; the assert is here so a spec that broke it would fail loudly in
  /// development rather than store a value [credentials] then silently drops.
  static String _key(String identity, String name) {
    assert(
      !name.contains('.'),
      'a credential name may not contain "." — it is the segment that ends '
      'the key, and a dotted one cannot be told from part of the next '
      'device\'s identity',
    );
    return 'credential.$identity.$name';
  }

  /// The credential name [key] holds for [identity], or null when the key is
  /// not this device's.
  ///
  /// `key.startsWith('credential.$identity.')` is NOT a namespace test, and
  /// treating it as one is how one device's sweep reaches another's secrets.
  /// An identity is `mac:<addr>` or `host:<hostname>` (see `identityFor`),
  /// and one hostname being another with a dotted suffix is the ordinary
  /// case, not a contrived one: mDNS hands out `bulb` and `bulb.local` for
  /// the same kind of device, and two of them on one LAN give
  /// `credential.host:bulb.serial` and `credential.host:bulb.local.serial`.
  /// A bare prefix test makes the second a member of the first's namespace.
  /// So `credentials('host:bulb')` returns the other device's secrets under
  /// the bogus name `local.serial` — and `forget('host:bulb')` DELETES them,
  /// which unpairs a device the user never asked to forget.
  ///
  /// The boundary is that the name is a single segment: it is what follows
  /// the prefix and it contains no dot, so a longer identity's key (which
  /// always has one) can never pass.
  static String? _nameIn(String key, String prefix) {
    if (!key.startsWith(prefix)) return null;
    final name = key.substring(prefix.length);
    return (name.isEmpty || name.contains('.')) ? null : name;
  }

  /// One stored value, or null when this device has never been given it.
  Future<String?> read(String identity, String name) async {
    final value = await _store.read(_key(identity, name));
    // An empty string is not a credential: it renders a path with a blank
    // segment, which reaches the device as a request for somebody else's
    // resource rather than as a visible failure.
    if (value == null || value.isEmpty) return null;
    // Registered so no record — a FormatException quoting a credential, a
    // token-bearing URL in a ClientException — carries it to the buffer the
    // Diagnostics screen exports.
    Log.registerSecret(value);
    return value;
  }

  Future<void> save(String identity, String name, String value) {
    Log.registerSecret(value);
    return _store.write(_key(identity, name), value);
  }

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
        if (_nameIn(entry.key, prefix) case final String name)
          if (entry.value.isNotEmpty) name: entry.value,
    };
  }

  /// Forget everything stored for one device — the un-pair half, which the
  /// forget-device flow calls so a removed device leaves nothing behind.
  Future<void> forget(String identity) async {
    final prefix = _key(identity, '');
    final all = await _store.readAll();
    for (final key in all.keys) {
      if (_nameIn(key, prefix) != null) await _store.delete(key);
    }
  }
}
