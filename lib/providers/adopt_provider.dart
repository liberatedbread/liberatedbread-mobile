// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/adopt_service.dart';
import '../services/spec_codec.dart';
import '../services/wifi_network_scanner.dart';
import 'device_spec_match_provider.dart';
import 'network_control_provider.dart' show lifxControlClientProvider;
import 'spec_codec_provider.dart';

/// The service that drives the two adoption conversations. A provider so a test
/// can substitute one whose transports answer from canned bytes.
final adoptServiceProvider = Provider<AdoptService>((ref) {
  return AdoptService(
    codec: ref.watch(specCodecProvider),
    // Reuse the app's shared LIFX UDP client — the same one control uses.
    lifx: ref.watch(lifxControlClientProvider),
  );
});

/// The OS Wi-Fi network reader behind the "a setup network is nearby" hint.
final wifiNetworkScannerProvider =
    Provider<WifiNetworkScanner>((ref) => WifiNetworkScanner());

/// One adoptable device family, pairing the catalogue's softap profile with the
/// matched-spec YAML the flow needs to render its setup requests.
class AdoptableDevice {
  final SoftApProfileDto profile;
  final String specYaml;

  /// The conversation this family speaks, resolved from the profile's method
  /// type. Only families the app can drive are kept (see
  /// [adoptableDevicesProvider]).
  final AdoptFamily family;

  const AdoptableDevice({
    required this.profile,
    required this.specYaml,
    required this.family,
  });
}

/// Every device family the app can adopt: the catalogue's softap profiles,
/// narrowed to the transports [AdoptService] implements and joined to their
/// spec YAML.
///
/// Data-driven, like the rest of the catalogue: a third adoptable family
/// arrives by adding a `softap_*` spec upstream and an [AdoptFamily] arm.
final adoptableDevicesProvider =
    FutureProvider<List<AdoptableDevice>>((ref) async {
  final codec = ref.watch(specCodecProvider);
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  final byName = <String, String>{
    for (final entry in parsed) entry.spec.deviceName: entry.yaml,
  };
  final profiles =
      await codec.softApProfiles(parsed.map((p) => p.yaml).toList());

  final devices = <AdoptableDevice>[];
  final seen = <String>{};
  for (final profile in profiles) {
    final family = AdoptFamily.fromMethodType(profile.methodType);
    final yaml = byName[profile.specName];
    // Skip a family the app cannot drive (a future softap_http device) rather
    // than offer a button that dead-ends. Skip a duplicate prefix so the hint
    // and the picker each list a family once.
    if (family == null || yaml == null) continue;
    if (!seen.add(profile.ssidPrefix.toLowerCase())) continue;
    devices.add(AdoptableDevice(
      profile: profile,
      specYaml: yaml,
      family: family,
    ));
  }
  return devices;
});

/// One device family that is set up over Bluetooth rather than from a setup
/// network of its own: the catalogue's `ble_provisioning` profile joined to the
/// spec that declared it.
///
/// The softap sibling of [AdoptableDevice]. It carries no [AdoptFamily]: that
/// enum names the two conversations [AdoptService] itself speaks over a setup
/// AP, and a BLE provisioning conversation is a spec-named protocol handler
/// with its own service and screen (the sanctioned shape for a handshake too
/// stateful to declare). What the spec decides here is everything the UI shows
/// and scans for — the family's name, its icon, and the advertised name that
/// means "waiting to be set up".
class BleAdoptableDevice {
  final BleProvisioningProfileDto profile;
  final String specYaml;

  /// `protocol_handler` from the spec — which provisioning conversation this
  /// family speaks, and so which screen the card opens.
  final String? protocolHandler;

  const BleAdoptableDevice({
    required this.profile,
    required this.specYaml,
    required this.protocolHandler,
  });
}

/// Every device family the catalogue says is provisioned over BLE.
///
/// Unlike [adoptableDevicesProvider] this does NOT narrow to what the app can
/// drive: a card is only rendered for a family whose handler the adopt screen
/// knows, and that decision belongs to the screen (which owns the routing
/// table), not here.
final bleAdoptableDevicesProvider =
    FutureProvider<List<BleAdoptableDevice>>((ref) async {
  final codec = ref.watch(specCodecProvider);
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  final byName = <String, ({String yaml, String? handler})>{
    for (final entry in parsed)
      entry.spec.deviceName: (
        yaml: entry.yaml,
        handler: entry.spec.protocolHandler
      ),
  };
  final profiles =
      await codec.bleProvisioningProfiles(parsed.map((p) => p.yaml).toList());

  final devices = <BleAdoptableDevice>[];
  final seen = <String>{};
  for (final profile in profiles) {
    final spec = byName[profile.specName];
    if (spec == null) continue;
    // One card per advertised name: two specs in a product family that share a
    // setup peripheral are one thing to the user.
    if (!seen.add(profile.advertisedName.toLowerCase())) continue;
    devices.add(BleAdoptableDevice(
      profile: profile,
      specYaml: spec.yaml,
      protocolHandler: spec.handler,
    ));
  }
  return devices;
});

/// Whether a BLE peripheral advertising [advertisedName] is some family's
/// setup-mode unit — and if so, which. Null when it is an ordinary device.
///
/// The one place the "is this waiting to be set up" question is answered, so
/// the BLE device screen and the setup screen's own scan agree, and neither
/// spells a product's advertised name in Dart.
///
/// Deliberately NOT autoDispose. The setup screen asks this per scan
/// advertisement with `ref.read(...future)` and no lasting listener, and an
/// autoDispose family entry can be torn down while its future is still in
/// flight — the future is then never delivered and the peripheral silently
/// never joins the found list, which reads as "the app cannot see my
/// purifier". What is retained instead is one small record per distinct
/// advertised name seen in a session.
final bleSetupModeMatchProvider =
    FutureProvider.family<BleAdoptableDevice?, String>(
        (ref, advertisedName) async {
  final devices = await ref.watch(bleAdoptableDevicesProvider.future);
  if (devices.isEmpty) return null;
  final index = await ref.watch(specCodecProvider).matchBleProvisioningName(
        profiles: devices.map((d) => d.profile).toList(),
        advertisedName: advertisedName,
      );
  return index == null ? null : devices[index];
});

/// The adoptable family whose setup network the OS can currently see, or null.
///
/// The signal behind the spinning icon: it polls the OS Wi-Fi list on a slow
/// cadence and reports the first adoptable device whose SSID prefix matches
/// something in the air. Emits null immediately and forever on a platform that
/// cannot enumerate Wi-Fi (iOS, desktop), so the icon simply never animates
/// there rather than misleading.
final nearbySetupNetworkProvider =
    StreamProvider.autoDispose<AdoptableDevice?>((ref) async* {
  final scanner = ref.watch(wifiNetworkScannerProvider);
  if (!scanner.isSupported) {
    yield null;
    return;
  }
  final codec = ref.watch(specCodecProvider);
  final devices = await ref.watch(adoptableDevicesProvider.future);
  if (devices.isEmpty) {
    yield null;
    return;
  }
  final profiles = devices.map((d) => d.profile).toList();

  Future<AdoptableDevice?> poll() async {
    final ssids = await scanner.visibleSsids();
    for (final ssid in ssids) {
      final index = await codec.matchSoftApSsid(profiles: profiles, ssid: ssid);
      if (index != null) return devices[index];
    }
    return null;
  }

  // Emit the first poll now, then re-poll on a slow cadence — a cheap cache
  // read, not a scan — emitting only when the match changes so a listener does
  // not rebuild every interval for a hint that has not moved. The generator is
  // torn down when the provider auto-disposes, which ends the periodic stream.
  var match = await poll();
  yield match;
  var lastPrefix = match?.profile.ssidPrefix;
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 5))) {
    match = await poll();
    final prefix = match?.profile.ssidPrefix;
    if (prefix != lastPrefix) {
      lastPrefix = prefix;
      yield match;
    }
  }
});
