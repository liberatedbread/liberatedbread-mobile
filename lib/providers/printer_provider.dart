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

  /// The family variant this printer is, when its spec has several heads.
  final String? variant;

  const SavedPrinter({
    required this.name,
    required this.specYaml,
    required this.raster,
    this.ble,
    this.network,
    this.variant,
  });

  bool get isBle => ble != null;

  /// A Bluetooth Classic printer: saved with the Bluetooth devices, printed
  /// to over an SPP socket rather than GATT.
  bool get isClassic => raster.transport == 'rfcomm_stream';
}

/// The saved devices that are label printers this build can drive: a BLE
/// printer whose handler writes a GATT plan, a Bluetooth Classic printer that
/// takes a stream over SPP, or a network printer that takes a raw stream. A printer whose spec names an encoder this build lacks is
/// left out rather than offered and failed.
final savedPrintersProvider = FutureProvider.autoDispose<List<SavedPrinter>>((
  ref,
) async {
  // Every watch before the first await: a watch after one is unsound.
  final saved = ref.watch(savedDevicesProvider);
  final savedNetwork = ref.watch(savedNetworkDevicesProvider);
  final codec = ref.watch(specCodecProvider);
  final catalogueFuture = ref.watch(specCatalogueProvider.future);
  final candidates = [
    ...saved.where((d) => d.category == 'printer' && d.specKey != null),
    ...savedNetwork.where((d) => d.category == 'printer' && d.specKey != null),
  ];
  if (candidates.isEmpty) return const [];

  final catalogue = await catalogueFuture;
  final byKey = specEntriesByKey(catalogue.specs);
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
      final isBle = device is SavedDevice;
      // A family of heads (the P-touch Cube) is told apart by the name the
      // printer answers to; the BLE families narrow by their own matcher.
      final variant = isBle
          ? await codec.rasterPrintVariantForName(
              specYaml: entry.yaml,
              deviceName: name,
            )
          : null;
      final raster = await codec.rasterPrintForSpec(
        specYaml: entry.yaml,
        variant: variant,
      );
      if (raster == null || !raster.encodable) continue;
      if (isBle && raster.variants.isNotEmpty) {
        final matched = await codec.bleVariantNamesForDevice(
          yaml: entry.yaml,
          deviceName: name,
          serviceUuids: const [],
        );
        if (matched.isNotEmpty && !raster.variants.any(matched.contains)) {
          continue;
        }
      }
      final wanted = isBle
          ? const {'ble_write_plan', 'rfcomm_stream'}
          : const {'raw_stream'};
      if (!wanted.contains(raster.transport)) continue;
      printers.add(
        SavedPrinter(
          name: name.isNotEmpty ? name : entry.deviceName,
          specYaml: entry.yaml,
          raster: raster,
          ble: isBle ? device : null,
          network: isBle ? null : device as SavedNetworkDevice,
          variant: variant,
        ),
      );
    } on Object catch (e) {
      Log.spec.warning('saved printer "$name" did not resolve', error: e);
    }
  }
  return printers;
});
