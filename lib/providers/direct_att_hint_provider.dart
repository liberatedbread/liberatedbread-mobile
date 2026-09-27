// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Whether the spec catalogue says a BLE device is one BlueZ's GATT client
// cannot drive but a direct ATT channel can — a spec's
// `device.host_compatibility` entry for `stack: bluez` with
// `status: incompatible` and `workaround: raw_att`, carried to Dart as the
// identity's `bluezRawAtt`.
//
// The Linux direct-ATT router (lib/services/direct_att/) asks this at
// connect, for any device it has not already routed direct, so a device the
// catalogue knows about goes direct from its FIRST connection instead of
// through the 32 s stall its runtime detection would otherwise wait out. The
// router knows nothing about specs and this file knows nothing about ATT; the
// router is only installed on Linux, so off Linux this is never asked.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hex.dart' show macAddressOrNull;
import '../services/direct_att/direct_att_router.dart'
    show BleSighting, DirectAttRouteHint;
import '../src/rust/api/device_api.dart' show MatchConfidence;
import 'device_spec_match_provider.dart';
import 'saved_device_provider.dart';
import 'scan_match_provider.dart';
import 'spec_choice_provider.dart';

/// See the file comment. Read lazily, inside the returned function, never
/// watched: the router holds the function for the life of the process, and
/// a watch here would rebuild the Bluetooth service whenever a spec choice or
/// a saved device changed.
final specDeclaresDirectAttProvider = Provider<DirectAttRouteHint>((ref) {
  return (String deviceId, BleSighting? seen) async {
    // A spec the app already ties to this device decides, either way: the
    // user's own choice, then the one recorded when it was last matched.
    final saved = ref
        .read(savedDevicesProvider)
        .where((d) => d.id == deviceId)
        .firstOrNull;
    final key = ref.read(specChoicesProvider)[deviceId] ?? saved?.specKey;
    if (key != null) {
      final catalogue = await ref.read(specCatalogueProvider.future);
      final entry = specEntriesByKey(catalogue.specs)[key];
      if (entry != null) return entry.identity.bluezRawAtt ?? false;
    }
    // Otherwise what it looks like, matched as the scan list matches it: its
    // last advertisement when a scan heard one, else — a saved device opened
    // without a scan — the name it was saved under. (A device saved while
    // BlueZ stalled on it has a name and no spec: its discovery found
    // nothing to match.)
    final name = seen?.name ?? saved?.name;
    if (name == null || name.isEmpty) return false;
    final guess = await ref.read(
      scanGuessProvider(
        ScanIdentity(
          name: name,
          serviceUuids: seen?.serviceUuids ?? const [],
          companyIds: seen?.companyIds ?? const [],
          macAddress: macAddressOrNull(deviceId),
        ),
      ).future,
    );
    // Only a guess that names a device class with some confidence, and on
    // which every equally good match agrees (ScanGuess.bluezRawAtt): routing
    // a stranger's device off BlueZ on one shared OUI would be the wrong
    // default.
    return guess != null &&
        guess.bluezRawAtt &&
        guess.confidence != MatchConfidence.possible;
  };
});
