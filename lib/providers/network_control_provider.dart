// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../services/soap_control_service.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';
import 'spec_codec_provider.dart';

/// The SOAP transport, as a provider so tests can substitute an http client
/// that answers from canned XML instead of a network.
final soapControlClientProvider =
    Provider<SoapControlClient>((ref) => SoapControlClient());

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
/// null when the matched spec declares none (a hub, a printer — most of the
/// network catalogue). Null is what keeps the plain details sheet for those.
@immutable
class NetworkControls {
  final String specYaml;
  final List<NetworkEntityDto> entities;

  const NetworkControls({required this.specYaml, required this.entities});
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
