// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../services/saved_device_store.dart';
import '../services/saved_network_device_store.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';
import 'saved_device_provider.dart';
import 'saved_network_device_provider.dart';
import 'spec_codec_provider.dart';

/// A saved label printer this build can print to, with the spec facts the
/// composer needs. Exactly one of [ble] and [network] is set.
@immutable
class SavedPrinter {
  final String name;
  final String specYaml;
  final RasterPrintDto raster;
  final SavedDevice? ble;
  final SavedNetworkDevice? network;

  const SavedPrinter({
    required this.name,
    required this.specYaml,
    required this.raster,
    this.ble,
    this.network,
  });

  bool get isBle => ble != null;
}

/// The saved devices that are label printers this build can drive: a BLE
/// printer whose handler writes a GATT plan, or a network printer that takes
/// a raw stream. A printer whose spec names an encoder this build lacks (the
/// MXW01) is left out rather than offered and failed.
final savedPrintersProvider = FutureProvider.autoDispose<List<SavedPrinter>>((
  ref,
) async {
  final saved = ref.watch(savedDevicesProvider);
  final savedNetwork = ref.watch(savedNetworkDevicesProvider);
  final candidates = [
    ...saved.where((d) => d.category == 'printer' && d.specKey != null),
    ...savedNetwork.where((d) => d.category == 'printer' && d.specKey != null),
  ];
  if (candidates.isEmpty) return const [];

  final catalogue = await ref.watch(specCatalogueProvider.future);
  final byKey = specEntriesByKey(catalogue.specs);
  final codec = ref.watch(specCodecProvider);
  final printers = <SavedPrinter>[];
  for (final device in candidates) {
    final (key, name) = switch (device) {
      SavedDevice d => (d.specKey!, d.name),
      SavedNetworkDevice d => (d.specKey!, d.name),
      _ => throw StateError('unreachable'),
    };
    final entry = byKey[key];
    if (entry == null) continue;
    try {
      final raster = await codec.rasterPrintForSpec(specYaml: entry.yaml);
      if (raster == null || !raster.encodable) continue;
      final isBle = device is SavedDevice;
      final wanted = isBle ? 'ble_write_plan' : 'raw_stream';
      if (raster.transport != wanted) continue;
      printers.add(
        SavedPrinter(
          name: name.isNotEmpty ? name : entry.deviceName,
          specYaml: entry.yaml,
          raster: raster,
          ble: isBle ? device : null,
          network: isBle ? null : device as SavedNetworkDevice,
        ),
      );
    } on Object catch (e) {
      Log.spec.warning('saved printer "$name" did not resolve', error: e);
    }
  }
  return printers;
});
