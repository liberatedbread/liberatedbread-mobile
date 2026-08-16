// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../services/ecp2_control_service.dart';
import '../services/http_control_service.dart';
import '../services/kasa_control_service.dart';
import '../services/lifx_control_service.dart';
import '../services/rabbit_air_control_service.dart';
import '../services/rabbit_air_key_store.dart';
import '../services/soap_control_service.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';
import 'settings_store_provider.dart';
import 'spec_codec_provider.dart';

/// The SOAP transport, as a provider so tests can substitute an http client
/// that answers from canned XML instead of a network.
final soapControlClientProvider =
    Provider<SoapControlClient>((ref) => SoapControlClient());

/// The plain-HTTP transport — same substitution rule, for tests that answer
/// a keypress with a canned 200 instead of a Roku.
final httpControlClientProvider =
    Provider<HttpControlClient>((ref) => HttpControlClient());

/// The ECP2 signed-session transport — the Roku-only fallback for when plain
/// ECP is refused (the "Limited" control-by-mobile-apps gate). Same
/// substitution rule: tests drive it from a scripted socket, not a network.
final ecp2ControlServiceProvider =
    Provider<Ecp2ControlService>((ref) => Ecp2ControlService());

/// The LIFX binary-UDP transport — same substitution rule, for tests that
/// answer (or drop) a datagram with a fake socket instead of a real strip.
final lifxControlClientProvider =
    Provider<LifxControlClient>((ref) => LifxControlClient());

/// The Kasa TCP-JSON transport. Depends on the codec because the XOR cipher
/// and length framing live in Rust; tests substitute a client with a fake
/// socket exchange (and a fake codec) instead of a real plug.
final kasaControlClientProvider = Provider<KasaControlClient>(
    (ref) => KasaControlClient(ref.watch(specCodecProvider)));

/// The Rabbit Air per-device user keys, on the same secure settings store the
/// Hue bridge credentials use — a long-lived LAN secret, never in plain
/// preferences. Tests override [settingsStoreProvider] with an in-memory fake
/// and get an isolated store for free.
final rabbitAirKeyStoreProvider = Provider<RabbitAirKeyStore>(
    (ref) => RabbitAirKeyStore(ref.watch(settingsStoreProvider)));

/// The Rabbit Air encrypted-UDP transport. Depends on the codec because the
/// envelope rendering and the AES-128-CBC datagram crypto live in Rust; tests
/// substitute a client with a fake exchange (and a fake codec) instead of a
/// real purifier.
final rabbitAirControlClientProvider = Provider<RabbitAirControlClient>(
    (ref) => RabbitAirControlClient(ref.watch(specCodecProvider)));

/// Identity of one network device the control layer is asked about.
///
/// Value-equal so the family caches per device: `specKey` names the matched
/// spec the way stored spec choices already do (`deviceName|manufacturer`),
/// and `ssdpTargets` is what the device answered to — the input that narrows
/// a family spec to the model actually found.
@immutable
class NetworkControlRequest {
  final String deviceName;
  final String manufacturer;
  final List<String> ssdpTargets;

  const NetworkControlRequest({
    required this.deviceName,
    required this.manufacturer,
    required this.ssdpTargets,
  });

  @override
  bool operator ==(Object other) =>
      other is NetworkControlRequest &&
      other.deviceName == deviceName &&
      other.manufacturer == manufacturer &&
      listEquals(other.ssdpTargets, ssdpTargets);

  @override
  int get hashCode =>
      Object.hash(deviceName, manufacturer, Object.hashAll(ssdpTargets));
}

/// The matched spec's YAML plus the controls it declares for this device, or
/// null when the matched spec declares none (a printer — much of the network
/// catalogue). Null is what keeps the plain details sheet for those.
@immutable
class NetworkControls {
  final String specYaml;
  final List<NetworkEntityDto> entities;

  const NetworkControls({required this.specYaml, required this.entities});

  /// Whether these controls describe a hub — a device fronting children that
  /// must be paired with and enumerated over HTTP (a Hue bridge). This routes
  /// the tap: Roku is `http` too but has no instanced children and no pairing,
  /// so it keeps the ordinary control screen; only a hub gets the paired one.
  ///
  /// A Kasa power strip is ALSO instanced (its outlets), but is driven over the
  /// raw tcp-json socket with no pairing, so it stays on the ordinary control
  /// screen, which enumerates its outlets there. So a hub is an instanced
  /// entity whose control is NOT tcp-json.
  bool get isHub => entities.any((e) =>
      e.isInstanced && !e.actions.any((a) => a.transport == 'tcp-json'));
}

/// Resolve what the catalogue lets us control on one network device.
///
/// autoDispose for the same reason as the guess provider: hosts come and go
/// with DHCP, and dead identities must not accumulate. Failures resolve to
/// null rather than throwing — a broken control path must degrade to the
/// details sheet, not break the scan list that asked.
final networkControlsProvider = FutureProvider.autoDispose
    .family<NetworkControls?, NetworkControlRequest>((ref, request) async {
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  final match = parsed
      .where((p) =>
          p.spec.deviceName == request.deviceName &&
          p.spec.manufacturer == request.manufacturer)
      .toList();
  if (match.isEmpty) return null;

  final codec = ref.watch(specCodecProvider);
  try {
    final entities = await codec.networkEntitiesForDevice(
      specYaml: match.first.yaml,
      ssdpTargets: request.ssdpTargets,
    );
    if (entities.isEmpty) return null;
    return NetworkControls(specYaml: match.first.yaml, entities: entities);
  } catch (e) {
    Log.spec.warning(
        'network controls failed to resolve for "${request.deviceName}"',
        error: e);
    return null;
  }
});
