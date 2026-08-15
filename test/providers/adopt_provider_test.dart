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

/// A scanner that reports a fixed set of SSIDs, standing in for the OS.
class _FakeScanner extends WifiNetworkScanner {
  final List<String> ssids;
  _FakeScanner(this.ssids) : super(isSupported: true);
  @override
  Future<List<String>> visibleSsids() async => ssids;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final List<({DeviceSpecDto spec, String yaml})> parsed;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    if (!rustReady) return;
    const codec = RealSpecCodec();
    parsed = [
      for (final file in const ['wemo-devices.yaml', 'lifx-z.yaml'])
        (
          yaml: await rootBundle
              .loadString('vendor/protocol-specs/device-specs/devices/$file'),
          spec: await codec.loadDeviceSpec(await rootBundle
              .loadString('vendor/protocol-specs/device-specs/devices/$file')),
        ),
    ];
  });

  ProviderContainer containerWith(WifiNetworkScanner scanner) {
    final container = ProviderContainer(overrides: [
      specCodecProvider.overrideWithValue(const RealSpecCodec()),
      parsedDeviceSpecsProvider.overrideWith((ref) async => parsed),
      wifiNetworkScannerProvider.overrideWithValue(scanner),
    ]);
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

  test('a visible Wemo setup SSID is matched to the Wemo family', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final container =
        containerWith(_FakeScanner(const ['SomeCafeWiFi', 'Wemo.Mini.4A2']));
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
        _FakeScanner(const ['HomeNetwork', 'Starbucks', 'MyPhone']));
    final nearby = await container.read(nearbySetupNetworkProvider.future);
    expect(nearby, isNull);
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
