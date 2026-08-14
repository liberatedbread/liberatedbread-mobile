// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';

import '../fakes/in_memory_settings_store.dart';

void main() {
  late InMemorySettingsStore store;
  late RoombaCredentialStore credentials;

  setUp(() {
    store = InMemorySettingsStore();
    credentials = RoombaCredentialStore(store);
  });

  const blid = '3193C60472324700';
  const password = ':1:1486937829:gktkDoYpWaDxCfGh';

  test('round-trips everything a robot is adopted with', () async {
    await credentials.save(const RoombaCredentials(
      blid: blid,
      password: password,
      name: 'Dorita',
      sku: 'R980020',
      lastIp: '192.168.1.103',
    ));

    final found = await credentials.credentials(blid);
    expect(found, isNotNull);
    expect(found!.password, password);
    expect(found.name, 'Dorita');
    expect(found.sku, 'R980020');
    expect(found.lastIp, '192.168.1.103');
    expect(found.usesRest980, isFalse, reason: 'direct is the default');
  });

  /// The password is the whole point: a store that trims or splits it hands
  /// back a credential the broker refuses without explaining why.
  test('stores the password verbatim, colons and all', () async {
    await credentials
        .save(const RoombaCredentials(blid: blid, password: password));
    final found = await credentials.credentials(blid);
    expect(found!.password, password);
    expect(found.password.startsWith(':'), isTrue);
  });

  /// The two places a BLID arrives from disagree about case: the UDP
  /// announcement's hostname spells it uppercase and iRobot's account API
  /// lowercase. A store keyed by whichever arrived first would hide a
  /// credential the app already holds.
  test('finds a robot however the BLID was cased on the way in', () async {
    await credentials.save(
      const RoombaCredentials(blid: blid, password: password),
    );

    expect(await credentials.credentials(blid.toLowerCase()), isNotNull);
    expect(await credentials.credentials(blid.toUpperCase()), isNotNull);
  });

  /// Keyed by the robot, never by its DHCP lease — otherwise the credential is
  /// stranded the first time the address rotates and the owner has to redo the
  /// button handshake to recover something the app already had.
  test('is keyed by BLID and not by address', () async {
    await credentials.save(const RoombaCredentials(
      blid: blid,
      password: password,
      lastIp: '192.168.1.103',
    ));

    await credentials.rememberAddress(blid, '192.168.1.200');

    final found = await credentials.credentials(blid);
    expect(found!.password, password, reason: 'the credential survives a move');
    expect(found.lastIp, '192.168.1.200');
    expect(
      store.values.keys.any((key) => key.contains('192.168')),
      isFalse,
      reason: 'no key is built from an address',
    );
  });

  test('an unknown robot is null, not an empty credential', () async {
    expect(await credentials.credentials('NOSUCHROBOT'), isNull);
  });

  group('rest980 routing', () {
    test('is off until an address is set, and toggles back off', () async {
      await credentials
          .save(const RoombaCredentials(blid: blid, password: password));
      expect((await credentials.credentials(blid))!.usesRest980, isFalse);

      await credentials.setRest980BaseUrl(blid, 'http://pi.local:3000');
      final routed = await credentials.credentials(blid);
      expect(routed!.usesRest980, isTrue);
      expect(routed.rest980BaseUrl, 'http://pi.local:3000');

      await credentials.setRest980BaseUrl(blid, null);
      expect((await credentials.credentials(blid))!.usesRest980, isFalse);
    });

    /// The setter exists precisely so the settings screen does not have to
    /// read-modify-write the whole record — which is how a screen that never
    /// had the password ends up clobbering it.
    test('setting the server address leaves the password alone', () async {
      await credentials.save(const RoombaCredentials(
        blid: blid,
        password: password,
        name: 'Dorita',
      ));

      await credentials.setRest980BaseUrl(blid, 'http://pi.local:3000');

      final found = await credentials.credentials(blid);
      expect(found!.password, password);
      expect(found.name, 'Dorita');
    });

    /// Per robot, not per app: a rest980 instance has one robot's BLID and
    /// password baked into its container config, so a global setting would
    /// send one robot's commands to the other's server.
    test('is remembered per robot', () async {
      const other = 'AAAA1111BBBB2222';
      await credentials
          .save(const RoombaCredentials(blid: blid, password: password));
      await credentials
          .save(const RoombaCredentials(blid: other, password: password));

      await credentials.setRest980BaseUrl(blid, 'http://pi.local:3000');

      expect((await credentials.credentials(blid))!.usesRest980, isTrue);
      expect((await credentials.credentials(other))!.usesRest980, isFalse);
    });
  });

  /// Nothing changes on the robot itself — unlike a Hue whitelist entry there
  /// is no credential to revoke, and only a factory reset mints a new one. All
  /// this does is make the app forget.
  test('forget clears every field, including the server address', () async {
    await credentials.save(const RoombaCredentials(
      blid: blid,
      password: password,
      name: 'Dorita',
      sku: 'R980020',
      lastIp: '192.168.1.103',
      rest980BaseUrl: 'http://pi.local:3000',
    ));

    await credentials.forget(blid);

    expect(await credentials.credentials(blid), isNull);
    expect(
      store.values.keys.where((key) => key.startsWith('roomba.')),
      isEmpty,
      reason: 'no orphaned field is left behind for a later adoption to find',
    );
  });
}
