// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../models/network_device.dart';
import '../services/ecp2_control_service.dart';
import '../services/http_control_service.dart';
import '../services/kasa_control_service.dart';
import '../services/lifx_control_service.dart';
import '../services/rabbit_air_ble_client.dart';
import '../services/network_command_sender.dart';
import '../services/rabbit_air_control_service.dart';
import '../services/rabbit_air_key_store.dart';
import '../services/rabbit_air_provision_service.dart';
import '../services/soap_control_service.dart';
import '../services/spec_codec.dart';
import 'ble_provider.dart';
import 'device_spec_match_provider.dart';
import 'network_scan_provider.dart';
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

/// The Rabbit Air entity surface of a BLE-matched spec, or null when the
/// matched spec is not a Rabbit Air purifier. Decided exactly the way
/// NetworkDeviceScreen does — entities riding the `udp` transport — but from
/// the BLE side's spec match, so the device screen can fork to the shared
/// Rabbit Air panel over the BLE transport instead of the raw GATT browser.
final rabbitAirBleControlsProvider = FutureProvider.autoDispose
    .family<List<NetworkEntityDto>?, String>((ref, specYaml) async {
  final codec = ref.watch(specCodecProvider);
  try {
    final entities = await codec.networkEntitiesForDevice(
      specYaml: specYaml,
      ssdpTargets: const [],
    );
    final isRabbitAir = entities.any((e) =>
        e.transport == 'udp' || e.actions.any((a) => a.transport == 'udp'));
    return isRabbitAir ? entities : null;
  } catch (e) {
    Log.spec.warning('rabbit air BLE surface failed to resolve', error: e);
    return null;
  }
});

/// The Rabbit Air spec's YAML and entity surface, resolved from the
/// catalogue by its mDNS service type rather than by a device match: a
/// setup-mode purifier ("RabbitAirSetup") is met before it can be matched,
/// and it IS this spec. Null when the catalogue carries no Rabbit Air spec.
final rabbitAirSpecSurfaceProvider = FutureProvider.autoDispose<
    ({String specYaml, List<NetworkEntityDto> entities})?>((ref) async {
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  final spec = parsed
      .where((p) => p.spec.mdnsServiceType == '_rabbitair._udp.local.')
      .firstOrNull;
  if (spec == null) return null;
  final codec = ref.watch(specCodecProvider);
  try {
    final entities = await codec.networkEntitiesForDevice(
      specYaml: spec.yaml,
      ssdpTargets: const [],
    );
    return (specYaml: spec.yaml, entities: entities);
  } catch (e) {
    Log.spec.warning('rabbit air spec surface failed to resolve', error: e);
    return null;
  }
});

/// The Rabbit Air BLE provisioning service. The link factory builds a client
/// on the app's [BleService]; the default verifier watches the network scan
/// for the Thing ID's mDNS hostname and proves the freshly pushed key with a
/// clock sync and a state read over the LAN protocol. Tests override the
/// whole provider with a service wired to fakes.
final rabbitAirProvisionServiceProvider =
    Provider<RabbitAirProvisionService>((ref) {
  final codec = ref.watch(specCodecProvider);
  return RabbitAirProvisionService(
    codec: codec,
    keyStore: ref.watch(rabbitAirKeyStoreProvider),
    linkFactory: () => RabbitAirBleClient(ref.watch(bleServiceProvider), codec),
    verifier: ({required thingId, required userKey}) async {
      final parsed = await ref.read(parsedDeviceSpecsProvider.future);
      final spec = parsed
          .where((p) => p.spec.mdnsServiceType == '_rabbitair._udp.local.')
          .firstOrNull;
      if (spec == null) return false;
      final scanner = ref.read(networkScanServiceProvider);
      final client = ref.read(rabbitAirControlClientProvider);
      // Scan windows until the outer timeout (the service's verifyTimeout)
      // cuts in: the purifier can take tens of seconds to join and announce.
      while (true) {
        NetworkDevice? found;
        await for (final device
            in scanner.scan(timeout: const Duration(seconds: 10))) {
          final hostname = device.hostname;
          if (hostname != null && hostname.startsWith(thingId)) {
            found = device;
            break;
          }
        }
        if (found == null) continue;
        final port = found.port ?? RabbitAirControlClient.defaultPort;
        await client.syncClock(found.host, port,
            specYaml: spec.yaml, userKey: userKey);
        final request = await codec.renderNetworkRabbitAirStateRequest(
          specYaml: spec.yaml,
          stateCommand: 'get_state',
          requestId: client.nextRequestId(),
          deviceTs: client.deviceTs(found.host),
        );
        await client.send(found.host, port, request, userKey: userKey);
        return true;
      }
    },
  );
});

/// Builds one [NetworkCommandSender] per device, wired to the same transport
/// providers the tests already substitute.
///
/// A factory rather than a family because the sender is stateful (it owns
/// the ECP2 session) and its lifecycle belongs to the caller: the device
/// screen closes its sender in dispose, and a group run closes each member's
/// as the member finishes. A family-cached instance would share one signed
/// session between surfaces that outlive each other, and nobody would know
/// who closes it.
typedef NetworkCommandSenderFactory = NetworkCommandSender Function({
  required NetworkDevice device,
  required String specYaml,
});

final networkCommandSenderFactoryProvider =
    Provider<NetworkCommandSenderFactory>((ref) {
  return ({required NetworkDevice device, required String specYaml}) =>
      NetworkCommandSender(
        host: device.host,
        discoveredControlPort: device.controlPort,
        devicePort: device.port,
        ssdpTargets: device.ssdpTargets,
        specYaml: specYaml,
        codec: ref.read(specCodecProvider),
        http: ref.read(httpControlClientProvider),
        soap: ref.read(soapControlClientProvider),
        kasa: ref.read(kasaControlClientProvider),
        rabbitAir: ref.read(rabbitAirControlClientProvider),
        ecp2: ref.read(ecp2ControlServiceProvider),
      );
});

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
  /// must be paired with and enumerated. This is what routes the tap: Roku is
  /// `http` too but has no instanced children and no pairing, so it keeps the
  /// ordinary control screen; only a hub gets the paired one.
  ///
  /// Instanced-but-not-a-hub is a real case, which is why the transport is
  /// part of the test: a Kasa power strip's outlets are instanced children,
  /// but they are driven directly over `tcp-json` with no pairing step, and
  /// they belong on the ordinary screen where the per-outlet switches live.
  bool get isHub => entities.any(
      (e) => e.isInstanced && !e.actions.any((a) => a.transport == 'tcp-json'));
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
