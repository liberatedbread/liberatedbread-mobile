// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../core/log.dart';
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
  ///
  /// The name is the LAST segment and holds no dot of its own — see
  /// [_nameIn], which is what makes one device's keys separable from
  /// another's. The identity may hold dots (`host:bulb.local`); the name is
  /// what may not, because the key is read back by splitting at its LAST
  /// dot, and with a dotless name that split is unambiguous: two different
  /// (identity, name) pairs can never spell one key. The catalogue's names
  /// are identifiers (`serial`, `username`, `blid`, `appliance_id`,
  /// `mqtt_client_id`), so the rule costs a real spec nothing.
  ///
  /// Refused with [InvalidCredentialName] in every build, not asserted.
  /// Names come straight from the spec (`issues_credentials:` keys,
  /// `websocket.pairing.credential_name`) and neither Rust nor the schema
  /// restricts them, so this is the only check there is — and it used to be
  /// an assert, which a release build compiles out. There a pack declaring
  /// `credential_name: local.serial` for `host:bulb` filed the issued token
  /// under `credential.host:bulb.local.serial`, byte for byte the key
  /// `host:bulb.local` keeps its `serial` under: the sender never found it
  /// (a re-pair on every open), `forget('host:bulb')` left it in the
  /// keychain, and `credentials('host:bulb.local')` served it to the other
  /// device. An empty name is refused for the same reason: `credential.<id>.`
  /// is a key [credentials] and [forget] both pass over.
  static String _key(String identity, String name) {
    if (name.isEmpty || name.contains('.')) throw InvalidCredentialName(name);
    return '${_prefix(identity)}$name';
  }

  /// What every key of [identity]'s starts with — and, on its own, NOT a
  /// test of membership: see [_nameIn].
  static String _prefix(String identity) => 'credential.$identity.';

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

  /// File [value] as [identity]'s [name]. Fails with
  /// [InvalidCredentialName] — as a failed future, like a keystore refusal,
  /// so the callers that already catch one (the sender logs it, the
  /// credentials card shows it) catch this — when [name] could not be read
  /// back as this device's (see [_key]).
  Future<void> save(String identity, String name, String value) async {
    final key = _key(identity, name);
    Log.registerSecret(value);
    await _store.write(key, value);
  }

  Future<void> forgetOne(String identity, String name) async =>
      _store.delete(_key(identity, name));

  /// Every credential stored for one device, name → value.
  ///
  /// This is what a send needs: the renderer fills `credential:` parameters
  /// by name out of one map, and asking per name would mean knowing the names
  /// before reading the spec. Values that are empty are omitted for the reason
  /// [read] gives.
  Future<Map<String, String>> credentials(String identity) async {
    final prefix = _prefix(identity);
    final all = await _store.readAll();
    final found = {
      for (final entry in all.entries)
        if (_nameIn(entry.key, prefix) case final String name)
          if (entry.value.isNotEmpty) name: entry.value,
    };
    // Registered as [read] does, and it matters more here: this is the
    // reader every send uses. Without it, after a relaunch no stored
    // credential was registered until it was saved again, and an error
    // quoting a credential-filled path (a Hue `/api/<username>/...`) reached
    // the exportable Diagnostics buffer in clear.
    found.values.forEach(Log.registerSecret);
    return found;
  }

  /// Forget everything stored for one device — the un-pair half, which the
  /// forget-device flow calls so a removed device leaves nothing behind.
  Future<void> forget(String identity) async {
    final prefix = _prefix(identity);
    final all = await _store.readAll();
    for (final key in all.keys) {
      if (_nameIn(key, prefix) != null) await _store.delete(key);
    }
  }
}

/// A credential name [DeviceCredentialStore] cannot file without it reaching
/// into another device's keys: one that is empty or holds a `.`.
///
/// An [ArgumentError], because the name is the caller's (the spec's) to fix,
/// with a [toString] that reads as a reason — the credentials card shows a
/// failed save as `Could not store <name> — <error>`.
class InvalidCredentialName extends ArgumentError {
  InvalidCredentialName(String name)
    : super.value(name, 'name', 'not a usable credential name');

  @override
  String toString() =>
      'the spec names a credential "$invalidValue", and a credential name '
      'may not be empty or contain "."';
}
