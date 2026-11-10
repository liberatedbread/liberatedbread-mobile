// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/iot_device.dart';
import '../services/classic_spp_service.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';
import 'saved_device_provider.dart';
import 'scan_match_provider.dart';
import 'spec_choice_provider.dart';

/// The Classic SPP printer handlers this build drives.
const brotherQlHandler = 'brother_ql_raster';
const brotherPtHandler = 'brother_pt_raster';
const _classicHandlers = {brotherQlHandler, brotherPtHandler};

@immutable
class ClassicPrinterProfile {
  final String specYaml;
  final String specKey;

  /// The spec's handler: which printer language the setup panel speaks.
  final String protocolHandler;

  const ClassicPrinterProfile({
    required this.specYaml,
    required this.specKey,
    this.protocolHandler = brotherQlHandler,
  });
}

@immutable
class ClassicPrinterRequest {
  final String deviceId;
  final ScanIdentity identity;

  const ClassicPrinterRequest({required this.deviceId, required this.identity});

  factory ClassicPrinterRequest.of(
    IoTDevice device, {
    Map<int, List<Uint8List>> declaredPrefixes = const {},
  }) => ClassicPrinterRequest(
    deviceId: device.id,
    identity: ScanIdentity.of(device, declaredPrefixes: declaredPrefixes),
  );

  @override
  bool operator ==(Object other) =>
      other is ClassicPrinterRequest &&
      other.deviceId == deviceId &&
      other.identity == identity;

  @override
  int get hashCode => Object.hash(deviceId, identity);
}

/// Whether the matched spec describes a network/Classic printer and no BLE
/// GATT surface. A stored spec identity wins, as it does for direct ATT;
/// otherwise the scan's own match decides before anything calls connect().
final classicPrinterProfileProvider = Provider.autoDispose
    .family<ClassicPrinterProfile?, ClassicPrinterRequest>((ref, request) {
      // The scan row has already resolved these by the time it is tappable.
      // Do not hold every other device's connect behind a fresh catalogue
      // load: an unresolved cache means "keep the old GATT path", not "wait".
      final catalogue = ref.watch(specCatalogueProvider).valueOrNull;
      if (catalogue == null) return null;
      final saved = ref
          .watch(savedDevicesProvider)
          .where((d) => d.id == request.deviceId)
          .firstOrNull;
      final savedKey =
          ref.watch(specChoicesProvider)[request.deviceId] ?? saved?.specKey;

      CatalogueSpec? entry;
      if (savedKey != null) {
        entry = specEntriesByKey(catalogue.specs)[savedKey];
      }
      if (entry == null) {
        final guess = ref
            .watch(scanGuessProvider(request.identity))
            .valueOrNull;
        final index = guess?.specIndex;
        if (guess == null || !guess.namesAProduct) return null;
        if (index == null || index < 0 || index >= catalogue.specs.length) {
          return null;
        }
        entry = catalogue.specs[index];
      }
      final handler = entry.protocolHandler;
      if (handler == null ||
          !_classicHandlers.contains(handler) ||
          entry.gattServiceUuids.isNotEmpty) {
        return null;
      }
      return ClassicPrinterProfile(
        specYaml: entry.yaml,
        specKey: specKeyOf(entry.deviceName, entry.manufacturer),
        protocolHandler: handler,
      );
    });

final classicSppServiceProvider = Provider<ClassicSppService>(
  (ref) => ClassicSppService.system(),
);
