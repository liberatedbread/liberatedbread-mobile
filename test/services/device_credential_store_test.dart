// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The generic credential store's contract. What makes it generic is that it
// knows no device and no credential name: the spec supplies both, and this
// files what it is told under the device identity the certificate pin already
// uses.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/device_credential_store.dart';

import '../fakes/in_memory_settings_store.dart';

void main() {
  const printer = 'mac:aa:bb:cc:dd:ee:ff';
  const television = 'host:10.0.0.7';

  late InMemorySettingsStore settings;
  late DeviceCredentialStore store;

  setUp(() {
    settings = InMemorySettingsStore();
    store = DeviceCredentialStore(settings);
  });

  test('a value round-trips under the name its spec gave it', () async {
    expect(await store.read(printer, 'serial'), isNull);
    await store.save(printer, 'serial', '01P00A123456789');
    expect(await store.read(printer, 'serial'), '01P00A123456789');
  });

  test('credentials come back as the map a render is given', () async {
    await store.save(printer, 'serial', '01P00A123456789');
    await store.save(printer, 'password', 'a1b2c3d4');
    expect(await store.credentials(printer),
        {'serial': '01P00A123456789', 'password': 'a1b2c3d4'});
  });

  test('one device\'s credentials are not another\'s', () async {
    // The failure this prevents is not hypothetical: two devices on one LAN
    // whose specs both name `serial` would otherwise share a value, and the
    // second would address the first.
    await store.save(printer, 'serial', 'PRINTER');
    await store.save(television, 'serial', 'TELEVISION');
    expect(await store.read(printer, 'serial'), 'PRINTER');
    expect(await store.credentials(television), {'serial': 'TELEVISION'});
  });

  test('an empty value is not a credential', () async {
    // Stored, it renders a path with a blank segment — which reaches the
    // device as a request for somebody else's resource rather than as the
    // visible failure a missing credential is supposed to be.
    await store.save(printer, 'serial', '');
    expect(await store.read(printer, 'serial'), isNull);
    expect(await store.credentials(printer), isEmpty);
  });

  test('forgetting a device forgets every credential it held', () async {
    await store.save(printer, 'serial', '01P00A123456789');
    await store.save(printer, 'password', 'a1b2c3d4');
    await store.save(television, 'client_id', r'phone$normal');

    await store.forget(printer);

    expect(await store.credentials(printer), isEmpty);
    // And only that device's: forgetting one must not unpair the rest.
    expect(await store.credentials(television), {'client_id': r'phone$normal'});
  });

  test('forgetting one credential leaves the others', () async {
    await store.save(printer, 'serial', '01P00A123456789');
    await store.save(printer, 'password', 'a1b2c3d4');
    await store.forgetOne(printer, 'password');
    expect(await store.credentials(printer), {'serial': '01P00A123456789'});
  });

  test('the namespace does not collide with the device-specific stores',
      () async {
    // The three older stores key by their own device-issued ids under their
    // own prefixes; a bare name here would let one read the other's values.
    await store.save(printer, 'serial', 'value');
    expect(settings.values.keys.single, startsWith('credential.'));
  });
}
