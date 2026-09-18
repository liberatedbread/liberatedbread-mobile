// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// adoptableDevicesProvider and nearbySetupNetworkProvider, against the real
// vendored catalogue through the real Rust FFI. The claims are the ones a spec
// refresh could quietly break: the catalogue still yields exactly the two
// families the app can drive (Wemo over SOAP, LIFX over UDP), and an SSID in
// the air is matched to the right one.

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/adopt_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/adopt_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/wifi_network_scanner.dart';

import '../helpers/host_rust_lib.dart';

/// A scanner that reports a fixed set of SSIDs, standing in for the OS, and
/// counts how often it was asked.
class _FakeScanner extends WifiNetworkScanner {
  final List<String> ssids;
  int polls = 0;
  _FakeScanner(this.ssids) : super(isSupported: true);
  @override
  Future<List<String>> visibleSsids() async {
    polls++;
    return ssids;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final List<({DeviceSpecDto spec, String yaml})> parsed;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    if (!rustReady) return;
    final codec = RealSpecCodec();
    parsed = [
      for (final file in const ['wemo-devices.yaml', 'lifx-z.yaml'])
        (
          yaml: await rootBundle.loadString(
            'vendor/protocol-specs/device-specs/devices/$file',
          ),
          spec: await codec.loadDeviceSpec(
            await rootBundle.loadString(
              'vendor/protocol-specs/device-specs/devices/$file',
            ),
          ),
        ),
    ];
  });

  ProviderContainer containerWith(WifiNetworkScanner scanner) {
    final container = ProviderContainer(
      overrides: [
        specCodecProvider.overrideWithValue(RealSpecCodec()),
        specCatalogueProvider.overrideWith(
          (ref) async => FallbackSpecCatalogue.fromParsed(
            ref.watch(specCodecProvider),
            parsed,
          ),
        ),
        wifiNetworkScannerProvider.overrideWithValue(scanner),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the catalogue yields exactly the two adoptable families', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final container = containerWith(_FakeScanner(const []));
    final devices = await container.read(adoptableDevicesProvider.future);

    final byFamily = {for (final d in devices) d.family: d};
    expect(byFamily.keys, containsAll([AdoptFamily.wemo, AdoptFamily.lifx]));

    final wemo = byFamily[AdoptFamily.wemo]!;
    expect(wemo.profile.ssidPrefix, 'Wemo.');
    expect(wemo.profile.methodType, 'softap_soap');
    expect(wemo.specYaml, contains('Belkin'));

    final lifx = byFamily[AdoptFamily.lifx]!;
    expect(lifx.profile.ssidPrefix, 'LIFX');
    expect(lifx.profile.methodType, 'softap_udp');
  });

  /// The join's shadowing rule is insertion order, the same rule
  /// [specEntriesByKey] encodes for key lookups: remote pack specs load
  /// after bundled ones, so a pack carrying a corrected copy of a bundled
  /// device WINS the name join. A first-wins reading here silently handed
  /// adopt the stale bundled spec instead of the copy the user installed.
  test(
    'a later duplicate (an installed pack) overrides the bundled copy',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final wemo = parsed.first;
      // The pack copy differs in a field the PROFILE carries, not just in its
      // YAML text — otherwise the test cannot tell which copy produced the
      // card's profile, which is exactly the split-brain it exists to catch:
      // profiles generated from every parsed copy, deduped first-wins (the
      // bundled one), then paired with the winning copy's YAML.
      final packCopy = (
        yaml: wemo.yaml.replaceAll(
          'ssid_prefix: "Wemo."',
          'ssid_prefix: "WemoPack."',
        ),
        spec: wemo.spec,
      );
      final container = ProviderContainer(
        overrides: [
          specCodecProvider.overrideWithValue(RealSpecCodec()),
          specCatalogueProvider.overrideWith(
            (ref) async => FallbackSpecCatalogue.fromParsed(
              ref.watch(specCodecProvider),
              [...parsed, packCopy],
            ),
          ),
          wifiNetworkScannerProvider.overrideWithValue(_FakeScanner(const [])),
        ],
      );
      addTearDown(container.dispose);

      final devices = await container.read(adoptableDevicesProvider.future);
      final adopted = devices.firstWhere((d) => d.family == AdoptFamily.wemo);
      expect(
        adopted.specYaml,
        contains('WemoPack.'),
        reason: 'the later (pack) copy must win the name join',
      );
      // …and the profile beside it comes from that same copy.
      expect(
        adopted.profile.ssidPrefix,
        'WemoPack.',
        reason: 'a card must not wear the bundled profile over pack YAML',
      );
      expect(
        devices.where((d) => d.family == AdoptFamily.wemo),
        hasLength(1),
        reason: 'the shadowed copy must not also produce a card',
      );
    },
  );

  test('a visible Wemo setup SSID is matched to the Wemo family', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final container = containerWith(
      _FakeScanner(const ['SomeCafeWiFi', 'Wemo.Mini.4A2']),
    );
    final nearby = await container.read(nearbySetupNetworkProvider.future);
    expect(nearby, isNotNull);
    expect(nearby!.family, AdoptFamily.wemo);
  });

  test('a visible LIFX setup SSID is matched to the LIFX family', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final container = containerWith(_FakeScanner(const ['LIFX Z 04A3C1']));
    final nearby = await container.read(nearbySetupNetworkProvider.future);
    expect(nearby, isNotNull);
    expect(nearby!.family, AdoptFamily.lifx);
  });

  test('nothing matching yields no hint', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final container = containerWith(
      _FakeScanner(const ['HomeNetwork', 'Starbucks', 'MyPhone']),
    );
    final nearby = await container.read(nearbySetupNetworkProvider.future);
    expect(nearby, isNull);
  });

  test('disposing the provider stops the Wi-Fi polling', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    // The hint used to be an async* loop over Stream.periodic, which only
    // observes cancellation at a yield — and it yielded only when the match
    // CHANGED. With no setup network in sight (the common case) it never
    // did, so a disposed provider kept polling the Wi-Fi scan channel every
    // five seconds for the life of the process, once more per screen visit.
    final scanner = _FakeScanner(const ['HomeNetwork']);
    final container = ProviderContainer(
      overrides: [
        specCodecProvider.overrideWithValue(RealSpecCodec()),
        specCatalogueProvider.overrideWith(
          (ref) async => FallbackSpecCatalogue.fromParsed(
            ref.watch(specCodecProvider),
            parsed,
          ),
        ),
        wifiNetworkScannerProvider.overrideWithValue(scanner),
        nearbySetupPollIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 40),
        ),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(nearbySetupNetworkProvider, (_, _) {});
    await container.read(nearbySetupNetworkProvider.future);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(scanner.polls, greaterThan(2), reason: 'it polls while listened');

    sub.close();
    // autoDispose tears the provider down once the last listener is gone.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final after = scanner.polls;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      scanner.polls,
      after,
      reason: 'a disposed provider must not keep polling the OS',
    );
  });

  test('a platform that cannot enumerate Wi-Fi never hints', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    // isSupported false — the iOS/desktop reality. The hint is null without
    // ever polling, so the icon simply never animates there.
    final container = containerWith(WifiNetworkScanner(isSupported: false));
    final nearby = await container.read(nearbySetupNetworkProvider.future);
    expect(nearby, isNull);
  });
}
