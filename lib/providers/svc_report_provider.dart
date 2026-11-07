// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/hex.dart';
import '../core/log.dart';
import '../core/unexpected_services.dart';
import '../models/ble_discovered_service.dart';
import '../models/network_device.dart';
import '../models/svc_report.dart';
import '../services/spec_codec.dart' show CatalogueSpec, DeviceSpecDto;
import '../services/svc_report_service.dart';
import 'device_spec_match_provider.dart';
import 'saved_device_provider.dart';

final svcReportServiceProvider = Provider<SvcReportService>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return SvcReportService(client: client);
});

/// This build's platform in the backend's vocabulary.
String svcReportPlatform() =>
    kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();

/// The BLE report for a connected device, or null when its matched [spec]
/// declares every service worth mentioning.
SvcReport? buildBleSvcReport({
  required DeviceSpecDto spec,
  required List<BleDiscoveredService> services,
  required String advertisedName,
  String? reportId,
}) {
  final declared = [
    for (final s in spec.serviceUuids) normalizeUuid(s),
    for (final s in spec.services) normalizeUuid(s.uuid),
  ];
  final unexpected = unexpectedGattServices(
    declared: declared,
    discovered: [for (final s in services) s.uuid],
  );
  if (unexpected.isEmpty) return null;
  final byUuid = {for (final s in services) normalizeUuid(s.uuid): s};
  return SvcReport(
    reportId: reportId ?? newReportId(),
    transport: SvcReportTransport.ble,
    specKey: specKeyFor(spec),
    specDeviceName: spec.deviceName,
    specManufacturer: spec.manufacturer,
    advertisedName: advertisedName.trim().isEmpty ? null : advertisedName,
    unexpected: [
      for (final uuid in unexpected)
        SvcReportEntry(
          kind: 'gatt',
          id: uuid,
          characteristics: [
            for (final c
                in byUuid[uuid]?.characteristics ??
                    const <BleDiscoveredCharacteristic>[])
              SvcReportCharacteristic(
                uuid: normalizeUuid(c.uuid),
                properties: [
                  if (c.canRead) 'read',
                  if (c.canWriteWithResponse) 'write',
                  if (c.canWriteWithoutResponse) 'write_without_response',
                  if (c.canWrite &&
                      !c.canWriteWithResponse &&
                      !c.canWriteWithoutResponse)
                    'write',
                  if (c.canNotify) 'notify',
                ],
              ),
          ],
        ),
    ],
    discovered: {for (final s in services) normalizeUuid(s.uuid)}.toList()
      ..sort(),
    declared: declared.toSet().toList()..sort(),
    appVersion: AppConstants.appVersion,
    platform: svcReportPlatform(),
  );
}

/// The Wi-Fi report for [device] against the spec [entry] it matched, or null
/// when the spec declares every mDNS type and SSDP target worth mentioning.
SvcReport? buildWifiSvcReport({
  required CatalogueSpec entry,
  required NetworkDevice device,
  String? reportId,
}) {
  final identity = entry.identity;
  final mdns = unexpectedMdnsTypes(
    declared: identity.mdnsServiceTypes,
    announced: device.serviceTypes,
  );
  final ssdp = unexpectedSsdpTargets(
    declared: identity.ssdpSearchTargets,
    answered: device.ssdpTargets,
  );
  if (mdns.isEmpty && ssdp.isEmpty) return null;
  return SvcReport(
    reportId: reportId ?? newReportId(),
    transport: SvcReportTransport.wifi,
    specKey: specKeyOf(identity.deviceName, identity.manufacturer),
    specDeviceName: identity.deviceName,
    specManufacturer: identity.manufacturer,
    // Never the mDNS instance name: users name devices after people and
    // rooms. See SvcReport's privacy note.
    advertisedName: null,
    unexpected: [
      for (final t in mdns) SvcReportEntry(kind: 'mdns', id: t),
      for (final t in ssdp) SvcReportEntry(kind: 'ssdp', id: t),
    ],
    discovered: [
      ...{for (final t in device.serviceTypes) normalizeServiceType(t)},
      // A uuid: target is a per-unit serial; it stays on the phone.
      ...{
        for (final t in device.ssdpTargets)
          if (!t.toLowerCase().startsWith('uuid:')) t.toLowerCase(),
      },
    ]..sort(),
    declared: [
      ...{for (final t in identity.mdnsServiceTypes) normalizeServiceType(t)},
      ...{for (final t in identity.ssdpSearchTargets) t.toLowerCase()},
    ]..sort(),
    appVersion: AppConstants.appVersion,
    platform: svcReportPlatform(),
  );
}

/// The Wi-Fi report for a device whose matched spec is known by [specKey],
/// resolved against the loaded catalogue. Null while the catalogue loads,
/// for an unknown key, or when nothing is unexpected.
final wifiSvcReportProvider = FutureProvider.autoDispose
    .family<SvcReport?, ({String specKey, NetworkDevice device})>((
      ref,
      args,
    ) async {
      final catalogue = await ref.watch(specCatalogueProvider.future);
      final entry = specEntriesByKey(catalogue.specs)[args.specKey];
      if (entry == null) return null;
      return buildWifiSvcReport(entry: entry, device: args.device);
    });

/// [SvcReport.dedupeKey]s the user has already sent or dismissed. The banner
/// stays hidden for those until the device shows a different set.
class SvcReportHandledNotifier extends Notifier<Set<String>> {
  static const storageKey = 'svc_report_handled_keys';

  /// FIFO cap so the set cannot grow without bound over the app's life.
  static const maxKeys = 128;

  /// SharedPreferences, or null when it is not wired in this scope: the
  /// banner is optional UI and must render in a screen test without prefs.
  SharedPreferences? _prefsOrNull() {
    try {
      return ref.read(sharedPreferencesProvider);
    } catch (_) {
      return null;
    }
  }

  @override
  Set<String> build() {
    final stored = _prefsOrNull()?.getString(storageKey);
    if (stored == null) return <String>{};
    try {
      final decoded = jsonDecode(stored);
      if (decoded is List) return {for (final k in decoded) '$k'};
    } on FormatException {
      // Fall through to the warning below.
    }
    Log.reports.warning('ignoring corrupt handled-report list');
    return <String>{};
  }

  Future<void> markHandled(String dedupeKey) async {
    if (state.contains(dedupeKey)) return;
    final next = [...state, dedupeKey];
    final kept = next.length > maxKeys
        ? next.sublist(next.length - maxKeys)
        : next;
    state = kept.toSet();
    try {
      await _prefsOrNull()?.setString(storageKey, jsonEncode(kept));
    } catch (e) {
      // In memory for this session either way; next launch may ask again.
      Log.reports.warning('could not persist a handled report', error: e);
    }
  }
}

final svcReportHandledProvider =
    NotifierProvider<SvcReportHandledNotifier, Set<String>>(
      SvcReportHandledNotifier.new,
    );
