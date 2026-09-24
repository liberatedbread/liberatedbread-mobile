// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The catalogue when the native core is NOT loaded. This file deliberately
// never initialises RustLib: the first FFI call the catalogue makes throws
// flutter_rust_bridge's "has not been initialized", which is what a device
// whose framework failed to load sees — and what main() decided the app
// carries on from. The catalogue used to reject the whole load on it, the
// provider went AsyncError, and every screen watching it showed an error the
// user could do nothing about. It is an empty catalogue now, with the reason
// on every key so the provider's one "native codec unavailable" line keeps
// its count.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

void main() {
  test(
    'an uninitialised bridge yields an empty catalogue, not an error',
    () async {
      final catalogue = await RealSpecCodec().loadCatalogue({
        'a.yaml': 'device: {name: A}',
        'b.yaml': 'device: {name: B}',
      });

      expect(catalogue, isA<EmptySpecCatalogue>());
      expect(catalogue.specs, isEmpty);
      expect(catalogue.failures.map((f) => f.key), ['a.yaml', 'b.yaml']);
      for (final failure in catalogue.failures) {
        expect(
          isBridgeUninitialised(failure.message),
          isTrue,
          reason: 'the reason travels with every key: ${failure.message}',
        );
      }
      expect(
        await catalogue.matchDevice(deviceName: 'A', serviceUuids: const []),
        isEmpty,
      );
      expect(await catalogue.udpBroadcastProbes(), isEmpty);
    },
  );
}
