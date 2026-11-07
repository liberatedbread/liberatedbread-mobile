// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';
import 'spec_codec_provider.dart';

/// One device in the Bluetooth pairing guide: who it is, and its spec's own
/// `device.setup` instructions.
@immutable
class BlePairingGuideEntry {
  /// The spec's product name — "Ember Mug".
  final String deviceName;
  final String manufacturer;

  /// `device.category` and `device.pictogram`, for the row's glyph.
  final String? category;
  final String? pictogram;

  final SetupInstructionsDto instructions;

  const BlePairingGuideEntry({
    required this.deviceName,
    required this.manufacturer,
    required this.category,
    required this.pictogram,
    required this.instructions,
  });
}

/// Whether [spec] is something a Bluetooth scan can find: it declares an
/// advertised name, service, company id or GATT service to be known by.
///
/// Read off the identity projection the scan matcher already ranks against,
/// rather than `device.protocol`, which only the full DTO carries — fetching
/// that for every spec to decide which to list would ship the whole
/// catalogue across the FFI to read one field. The two agree over the
/// vendored catalogue (pinned in the real-catalogue test); where they do
/// not, this is the right answer for the guide: a Wi-Fi purifier that is
/// provisioned over Bluetooth (Rabbit Air) is found on this tab first.
@visibleForTesting
bool isBluetoothSpec(CatalogueSpec spec) {
  final id = spec.identity;
  return id.localNamePrefixes.isNotEmpty ||
      id.localNames.isNotEmpty ||
      id.serviceUuids.isNotEmpty ||
      id.companyIds.isNotEmpty ||
      id.manufacturerDataPrefixes.isNotEmpty ||
      id.nameMatchers.isNotEmpty ||
      spec.gattServiceUuids.isNotEmpty;
}

/// Whether [instructions] say how to pair: at least one setup route with a
/// description or steps. A spec whose setup block is only a factory reset or
/// a rejoin note has nothing to offer someone about to pair a new device, and
/// a row that opens onto no pairing steps reads as a broken link.
@visibleForTesting
bool hasPairingSteps(SetupInstructionsDto instructions) =>
    instructions.methods.any(
      (m) =>
          (m.description ?? '').trim().isNotEmpty ||
          m.steps.isNotEmpty ||
          m.stages.isNotEmpty,
    );

/// Every Bluetooth device the catalogue carries pairing instructions for,
/// sorted by name — the list behind the Nearby tab's "Pairing a new device".
///
/// The Bluetooth counterpart of the Wi-Fi adopt picker, with one difference
/// worth stating: a BLE device needs no credentials pushed to it, so this is
/// a guide, not a flow. Getting a device into pairing mode is the step the
/// app cannot do and the spec knows how to describe; finding and connecting
/// to it afterwards is the scan the user came from.
///
/// Left out:
/// - `identify_only` specs: this app names them but does not drive them, so
///   pairing one here leads nowhere.
/// - specs carrying a `malicious` security advisory (card skimmers): there is
///   no such thing as pairing with one, and listing it beside real products
///   would read as an endorsement.
/// - specs with no pairing route ([hasPairingSteps]).
///
/// A pack's copy of a bundled spec shadows it by device name, later wins —
/// the same rule the adopt picker uses — so the steps shown are the ones the
/// pack exists to correct. autoDispose: it parses each listed spec's setup
/// block, which is worth doing when the guide opens and not worth holding
/// once it closes.
final blePairingGuideProvider =
    FutureProvider.autoDispose<List<BlePairingGuideEntry>>((ref) async {
      // Everything watched before the first await.
      final codec = ref.watch(specCodecProvider);
      final catalogue = await ref.watch(specCatalogueProvider.future);

      final byName = <String, CatalogueSpec>{};
      for (final spec in catalogue.specs) {
        if (!isBluetoothSpec(spec)) continue;
        final id = spec.identity;
        if (id.integration == 'identify_only') continue;
        if (id.securityAdvisory?.severity == 'malicious') continue;
        byName[spec.deviceName] = spec;
      }

      final entries = await Future.wait(
        byName.values.map((spec) async {
          final SetupInstructionsDto? instructions;
          try {
            instructions = await codec.setupInstructions(spec.yaml);
          } catch (e) {
            // One spec's bad setup block costs that one row, not the guide.
            Log.spec.warning(
              'pairing guide: setup extraction failed for '
              '"${spec.deviceName}"',
              error: e,
            );
            return null;
          }
          if (instructions == null || !hasPairingSteps(instructions)) {
            return null;
          }
          return BlePairingGuideEntry(
            deviceName: spec.deviceName,
            manufacturer: spec.manufacturer,
            category: spec.identity.category,
            pictogram: spec.identity.pictogram,
            instructions: instructions,
          );
        }),
      );

      return entries.nonNulls.toList()..sort(
        (a, b) =>
            a.deviceName.toLowerCase().compareTo(b.deviceName.toLowerCase()),
      );
    });
