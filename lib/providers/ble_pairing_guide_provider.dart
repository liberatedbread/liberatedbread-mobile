// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/setup_content.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';

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

  /// `device.protocol_handler`, which says whether the Wi-Fi adopt screen can
  /// drive this device's Bluetooth provisioning conversation.
  final String? protocolHandler;

  final SetupInstructionsDto instructions;

  const BlePairingGuideEntry({
    required this.deviceName,
    required this.manufacturer,
    required this.category,
    required this.pictogram,
    required this.instructions,
    this.protocolHandler,
  });

  /// Whether one of its setup routes hands it Wi-Fi credentials over
  /// Bluetooth (`ble_provisioning`): a Wi-Fi device found on this tab first,
  /// which a scan-and-connect alone does not finish setting up.
  bool get provisionsWifiOverBle =>
      instructions.methods.any((m) => m.methodType == 'ble_provisioning');
}

/// Whether [spec] is something a Bluetooth scan can find: it declares an
/// advertised name, service, company id or GATT service to be known by.
///
/// Read off the identity projection the scan matcher already ranks against,
/// rather than `device.protocol`, which only the full DTO carries — asking
/// [SpecCatalogue.specAt] for every spec to read one field would decode the
/// whole catalogue. The two agree over the vendored catalogue (pinned in the
/// real-catalogue test); where they do not, this is the right answer for the
/// guide: a Wi-Fi purifier that is provisioned over Bluetooth (Rabbit Air) is
/// found on this tab first.
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

/// Whether [instructions] say how to pair: at least one setup route with
/// content ([setupMethodHasContent], the same test the instructions screen
/// draws a route's card by). A spec whose setup block is only a factory reset
/// or a rejoin note has nothing to offer someone about to pair a new device,
/// and a row that opens onto no pairing steps reads as a broken link.
@visibleForTesting
bool hasPairingSteps(SetupInstructionsDto instructions) =>
    instructions.methods.any(setupMethodHasContent);

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
/// Shadowing comes before those filters, by [specEntriesByKey]'s rule (name
/// AND maker, a pack's copy over the bundled one): a pack that corrects a
/// spec to `identify_only` or `malicious` must hide the device, not be
/// skipped so the stale bundled copy shows through. The instructions come
/// from one [SpecCatalogue.setupInstructions] call over the held parses.
/// autoDispose: worth asking when the guide opens, not worth holding after.
final blePairingGuideProvider =
    FutureProvider.autoDispose<List<BlePairingGuideEntry>>((ref) async {
      final catalogue = await ref.watch(specCatalogueProvider.future);

      final candidates = [
        for (final spec in specEntriesByKey(catalogue.specs).values)
          if (isBluetoothSpec(spec) &&
              spec.identity.integration != 'identify_only' &&
              spec.identity.securityAdvisory?.severity != 'malicious')
            spec,
      ];
      final setups = await catalogue.setupInstructions([
        for (final spec in candidates) spec.index,
      ]);

      final entries = <BlePairingGuideEntry>[
        for (final (i, spec) in candidates.indexed)
          if (setups[i] case final setup? when hasPairingSteps(setup))
            BlePairingGuideEntry(
              deviceName: spec.deviceName,
              manufacturer: spec.manufacturer,
              category: spec.identity.category,
              pictogram: spec.identity.pictogram,
              protocolHandler: spec.protocolHandler,
              instructions: setup,
            ),
      ];
      return entries..sort((a, b) {
        final byName = a.deviceName.toLowerCase().compareTo(
          b.deviceName.toLowerCase(),
        );
        return byName != 0
            ? byName
            : a.manufacturer.toLowerCase().compareTo(
                b.manufacturer.toLowerCase(),
              );
      });
    });
