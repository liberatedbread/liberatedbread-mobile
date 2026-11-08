// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/acinfinity_ble_client.dart';
import '../services/spec_codec.dart';
import '../services/yummly_ble_client.dart';
import 'ble_provider.dart';
import 'classic_printer_provider.dart';
import 'device_spec_match_provider.dart';
import 'saved_device_provider.dart';
import 'scan_match_provider.dart';
import 'spec_choice_provider.dart';

const yummlyHandler = 'yummly_xw2_tlv';
const acInfinityHandler = 'acinfinity_a5';

/// A BLE device this app reads through a read-only handler, which opens its
/// own panel and never reaches the generic GATT client.
@immutable
class ReadOnlyBleProfile {
  final String handler;
  final String specKey;
  final String specYaml;
  final String category;

  const ReadOnlyBleProfile({
    required this.handler,
    required this.specKey,
    required this.specYaml,
    required this.category,
  });
}

ReadOnlyBleProfile? _profileOf(CatalogueSpec entry, String specKey) =>
    switch (entry.protocolHandler) {
      yummlyHandler => ReadOnlyBleProfile(
        handler: yummlyHandler,
        specKey: specKey,
        specYaml: entry.yaml,
        category: 'sensor',
      ),
      acInfinityHandler => ReadOnlyBleProfile(
        handler: acInfinityHandler,
        specKey: specKey,
        specYaml: entry.yaml,
        category: 'climate',
      ),
      _ => null,
    };

/// The same choice the Enphase panel makes: a stored identity first, then the
/// scan's own match, decided before anything calls connect.
final readOnlyBleProfileProvider = Provider.autoDispose
    .family<ReadOnlyBleProfile?, ClassicPrinterRequest>((ref, request) {
      final catalogue = ref.watch(specCatalogueProvider).valueOrNull;
      if (catalogue == null) return null;
      final saved = ref
          .watch(savedDevicesProvider)
          .where((d) => d.id == request.deviceId)
          .firstOrNull;
      final savedKey =
          ref.watch(specChoicesProvider)[request.deviceId] ?? saved?.specKey;
      if (savedKey != null) {
        final entry = specEntriesByKey(catalogue.specs)[savedKey];
        if (entry != null) {
          final profile = _profileOf(entry, savedKey);
          if (profile != null) return profile;
        }
      }
      final guess = ref.watch(scanGuessProvider(request.identity)).valueOrNull;
      final index = guess?.specIndex;
      if (guess == null || !guess.namesAProduct) return null;
      if (index == null || index < 0 || index >= catalogue.specs.length) {
        return null;
      }
      final entry = catalogue.specs[index];
      return _profileOf(entry, specKeyOf(entry.deviceName, entry.manufacturer));
    });

final yummlyClientProvider = Provider<YummlyClient Function(String)>(
  (ref) =>
      (deviceId) => YummlyBleClient(
        ble: ref.read(bleServiceProvider),
        deviceId: deviceId,
      ),
);

final acInfinityClientProvider = Provider<AcInfinityClient Function(String)>(
  (ref) =>
      (deviceId) => AcInfinityBleClient(
        ble: ref.read(bleServiceProvider),
        deviceId: deviceId,
      ),
);
