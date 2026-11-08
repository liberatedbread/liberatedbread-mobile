// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/enphase_ble_client.dart';
import 'ble_provider.dart';
import 'classic_printer_provider.dart';
import 'device_spec_match_provider.dart';
import 'saved_device_provider.dart';
import 'scan_match_provider.dart';
import 'spec_choice_provider.dart';

final enphaseProfileProvider = Provider.autoDispose
    .family<String?, ClassicPrinterRequest>((ref, request) {
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
        if (entry != null && entry.key.endsWith('enphase-iqbattery-ble.yaml')) {
          return savedKey;
        }
      }
      final guess = ref.watch(scanGuessProvider(request.identity)).valueOrNull;
      final index = guess?.specIndex;
      if (guess == null || !guess.namesAProduct) return null;
      if (index == null || index < 0 || index >= catalogue.specs.length) {
        return null;
      }
      final entry = catalogue.specs[index];
      if (!entry.key.endsWith('enphase-iqbattery-ble.yaml')) return null;
      return specKeyOf(entry.deviceName, entry.manufacturer);
    });

final enphaseClientProvider = Provider<EnphaseClient Function(String)>(
  (ref) =>
      (deviceId) => EnphaseBleClient(
        ble: ref.read(bleServiceProvider),
        deviceId: deviceId,
      ),
);
