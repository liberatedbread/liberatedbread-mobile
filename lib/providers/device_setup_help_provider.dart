// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../services/spec_codec.dart';
import 'device_spec_match_provider.dart';
import 'scan_match_provider.dart';
import 'spec_codec_provider.dart';

/// A device's pairing/troubleshooting help: the matched product's name and its
/// spec's renderable `device.setup` instructions.
@immutable
class DeviceSetupHelp {
  /// The matched spec's product name — "Ember Mug" — for the screen title, so
  /// the help says whose instructions these are.
  final String deviceName;
  final SetupInstructionsDto instructions;

  const DeviceSetupHelp({required this.deviceName, required this.instructions});
}

/// The setup/troubleshooting help for a device we could not connect to, or null
/// when the catalogue does not confidently name it or the named spec carries no
/// setup prose.
///
/// This runs on a connect failure, when there are no discovered GATT services
/// to match on — so it matches on the ADVERTISED identity (name, service UUIDs,
/// company ids) exactly as the scan list does, via [ScanGuess]. It only speaks
/// up when the guess [ScanGuess.namesAProduct]: showing one device's
/// factory-reset steps because a whole vendor's OUI matched would be worse than
/// showing nothing. The matcher's `specIndex` recovers the exact YAML the guess
/// came from, so the instructions are always the matched product's own.
///
/// Keyed on [ScanIdentity] (not the device id) and `autoDispose`, mirroring
/// [scanGuessProvider]: the same identity is resolved once however many times a
/// failed screen rebuilds, and a rotating BLE address does not leak an entry.
final deviceSetupHelpProvider = FutureProvider.autoDispose
    .family<DeviceSetupHelp?, ScanIdentity>((ref, identity) async {
  final codec = ref.watch(specCodecProvider);
  final parsed = await ref.watch(parsedDeviceSpecsProvider.future);
  final identities = await ref.watch(specIdentitiesProvider.future);
  if (parsed.isEmpty || identities.isEmpty) return null;

  final List<ScanMatch> matches;
  try {
    matches = await codec.matchScannedDevice(
      identities: identities,
      device: ScannedDeviceDto(
        name: identity.name,
        serviceUuids: identity.serviceUuids,
        companyIds: Uint16List.fromList(identity.companyIds),
        macAddress: identity.macAddress,
      ),
    );
  } catch (e) {
    Log.spec
        .warning('setup-help matching failed for "${identity.name}"', error: e);
    return null;
  }

  // Only offer help when the match names a product; a bare OUI tie could point
  // the reset steps at the wrong device.
  final guess = ScanGuess.fromMatches(matches);
  if (guess == null || !guess.namesAProduct) return null;

  final best = matches.first;
  // `specIndex` is the position in the identities list, which is built from
  // `parsed` in the same order — so it recovers the exact spec that matched.
  // Guard the bound rather than trust it: a codec that returned a stale index
  // must not throw a RangeError into a screen that is already an error state.
  if (best.specIndex < 0 || best.specIndex >= parsed.length) return null;
  final yaml = parsed[best.specIndex].yaml;

  final SetupInstructionsDto? instructions;
  try {
    instructions = await codec.setupInstructions(yaml);
  } catch (e) {
    Log.spec.warning('setup-help extraction failed for "${best.deviceName}"',
        error: e);
    return null;
  }
  if (instructions == null) return null;

  return DeviceSetupHelp(
      deviceName: best.deviceName, instructions: instructions);
});
