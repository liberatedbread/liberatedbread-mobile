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
import '../models/radio_profile.dart';
import '../models/radio_target.dart';
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
/// declares every service worth mentioning and nothing in [responses] went
/// wrong.
SvcReport? buildBleSvcReport({
  required DeviceSpecDto spec,
  required List<BleDiscoveredService> services,
  required String advertisedName,
  String? deviceId,
  List<SvcReportResponse> responses = const [],
  String? reportId,
}) {
  // A device opened from the saved list carries the name it was saved
  // under, and a nameless one was saved as "Unknown (<id>)" — the id being
  // its Bluetooth address on Android and Linux. A name with the id in it is
  // not the device's own, and the report promises no address.
  final id = deviceId?.trim().toLowerCase() ?? '';
  final name = advertisedName.trim();
  final reportedName =
      name.isEmpty || (id.isNotEmpty && name.toLowerCase().contains(id))
      ? null
      : advertisedName;
  final declared = [
    for (final s in spec.serviceUuids) normalizeUuid(s),
    for (final s in spec.services) normalizeUuid(s.uuid),
  ];
  final unexpected = unexpectedGattServices(
    declared: declared,
    discovered: [for (final s in services) s.uuid],
  );
  if (unexpected.isEmpty && responses.isEmpty) return null;
  final byUuid = {for (final s in services) normalizeUuid(s.uuid): s};
  final unexpectedServices = [
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
  ];
  for (final service in unexpectedServices) {
    Log.reports.info(
      'unexpected ${service.kind} service ${service.id} for ${spec.deviceName}',
    );
  }
  return SvcReport(
    reportId: reportId ?? newReportId(),
    transport: SvcReportTransport.ble,
    specKey: specKeyFor(spec),
    specDeviceName: spec.deviceName,
    specManufacturer: spec.manufacturer,
    advertisedName: reportedName,
    unexpected: unexpectedServices,
    responses: responses,
    discovered: {for (final s in services) normalizeUuid(s.uuid)}.toList()
      ..sort(),
    declared: declared.toSet().toList()..sort(),
    appVersion: AppConstants.appVersion,
    platform: svcReportPlatform(),
  );
}

/// `_name._tcp` or `_name._udp`, with a subtype or domain after it at most.
final RegExp _serviceTypeShape = RegExp(r'^_[a-z0-9-]+\._(tcp|udp)(\.|$)');

/// The Wi-Fi report for [device] against the spec [entry] it matched, or null
/// when the spec declares every mDNS type and SSDP target worth mentioning
/// and nothing in [responses] went wrong.
SvcReport? buildWifiSvcReport({
  required CatalogueSpec entry,
  required NetworkDevice device,
  List<SvcReportResponse> responses = const [],
  String? reportId,
}) {
  final identity = entry.identity;
  final mdns = unexpectedMdnsTypes(
    declared: identity.mdnsServiceTypes,
    announced: device.serviceTypes,
  ).where(_serviceTypeShape.hasMatch).toList();
  final ssdp = unexpectedSsdpTargets(
    declared: identity.ssdpSearchTargets,
    answered: device.ssdpTargets,
  );
  if (mdns.isEmpty && ssdp.isEmpty && responses.isEmpty) return null;
  final unexpectedServices = [
    for (final t in mdns) SvcReportEntry(kind: 'mdns', id: t),
    for (final t in ssdp) SvcReportEntry(kind: 'ssdp', id: t),
  ];
  for (final service in unexpectedServices) {
    Log.reports.info(
      'unexpected ${service.kind} service ${service.id} '
      'for ${identity.deviceName}',
    );
  }
  return SvcReport(
    reportId: reportId ?? newReportId(),
    transport: SvcReportTransport.wifi,
    specKey: specKeyOf(identity.deviceName, identity.manufacturer),
    specDeviceName: identity.deviceName,
    specManufacturer: identity.manufacturer,
    // Never the mDNS instance name: users name devices after people and
    // rooms. See SvcReport's privacy note.
    advertisedName: null,
    unexpected: unexpectedServices,
    responses: responses,
    discovered: [
      // Only what reads as a service TYPE. A sighting the scanner could not
      // parse keeps its whole instance name here, and that is the user's
      // name for the device.
      ...{
        for (final t in device.serviceTypes)
          if (_serviceTypeShape.hasMatch(normalizeServiceType(t)))
            normalizeServiceType(t),
      },
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

/// The key a radio's programming failures are recorded under: per radio
/// AND profile, because a failure says the profile and this radio disagree,
/// and picking another model is a different question. Local only.
String radioAnomalyKey(RadioTarget target, RadioProfile profile) =>
    'radio:${target.transport.name}:${target.id}:${profile.id}';

/// The report for a radio whose programming session went wrong in a way the
/// [profile] does not expect, or null when [responses] is empty. Its subject
/// is the profile: radios are not spec-driven, and nothing about the radio
/// itself (its id, its name, its memory) goes in.
SvcReport? buildRadioSvcReport({
  required RadioProfile profile,
  required RadioTransport link,
  required List<SvcReportResponse> responses,
  String? reportId,
}) {
  if (responses.isEmpty) return null;
  return SvcReport(
    reportId: reportId ?? newReportId(),
    transport: SvcReportTransport.radio,
    specKey: 'radio:${profile.id}',
    specDeviceName: profile.displayName,
    specManufacturer: '',
    advertisedName: null,
    unexpected: const [],
    responses: responses,
    discovered: const [],
    declared: const [],
    appVersion: AppConstants.appVersion,
    platform: svcReportPlatform(),
    radio: SvcReportRadio(
      profileId: profile.id,
      family: profile.programmingFamily.name,
      link: link.name,
    ),
  );
}

/// The key a Wi-Fi device's responses are recorded under in
/// [responseAnomaliesProvider], per device AND the spec they were read
/// against ([specKey]): a failure under one spec says nothing about
/// another, and must not be reported as that one's. Local only — never
/// sent.
String wifiAnomalyKey(NetworkDevice device, String specKey) =>
    'wifi:${device.host}|$specKey';

/// The key a BLE device's responses are recorded under, per device AND the
/// spec text they were decoded with ([specYaml], the matched spec's yaml the
/// control panel hands its value widgets). Scoped for the reason
/// [wifiAnomalyKey] is: after the user picks another spec in the chooser,
/// the old spec's decode failures (and entity names) stay under the old
/// key instead of turning up in the new spec's report. A hash, not the
/// text, because the key is held for the life of the process. Local only.
String bleAnomalyKey(String deviceId, String specYaml) =>
    'ble:$deviceId|${specYaml.hashCode}';

/// The Wi-Fi report for a device whose matched spec is known by [specKey],
/// resolved against the loaded catalogue, folding in whatever responses from
/// it have been recorded. Null while the catalogue loads, for an unknown
/// key, or when nothing is unexpected.
final wifiSvcReportProvider = FutureProvider.autoDispose
    .family<SvcReport?, ({String specKey, NetworkDevice device})>((
      ref,
      args,
    ) async {
      final responses = ref.watch(
        responseAnomaliesProvider.select(
          (all) => all[wifiAnomalyKey(args.device, args.specKey)] ?? const [],
        ),
      );
      final catalogue = await ref.watch(specCatalogueProvider.future);
      final entry = specEntriesByKey(catalogue.specs)[args.specKey];
      if (entry == null) return null;
      return buildWifiSvcReport(
        entry: entry,
        device: args.device,
        responses: responses,
      );
    });

/// Responses devices gave that the app could not make sense of, by device
/// key ([bleAnomalyKey], [wifiAnomalyKey]), for the life of the process.
///
/// Anything that reads a device's answer — a BLE value widget, the Wi-Fi
/// state decoder — records a failure here, and the device's screen turns it
/// into the "unexpected response" banner. Recording never sends anything:
/// only the user's tap on that banner does.
class ResponseAnomalyNotifier
    extends Notifier<Map<String, List<SvcReportResponse>>> {
  /// Per device, so a device that fails every notification cannot grow the
  /// list (and the report) without bound. Counts findings still to report:
  /// ones already sent or dismissed are done with, and counting them shut
  /// out every later finding for the life of the process.
  static const maxPerDevice = 16;

  /// The most kept per device, reported or not.
  static const maxKeptPerDevice = 64;

  @override
  Map<String, List<SvcReportResponse>> build() => const {};

  /// Record [response] for [deviceKey]. The same finding twice is a no-op,
  /// so a notify stream that keeps failing does not rebuild the screen.
  void record(String deviceKey, SvcReportResponse response) {
    final existing = state[deviceKey] ?? const <SvcReportResponse>[];
    if (existing.contains(response) || existing.length >= maxKeptPerDevice) {
      return;
    }
    // A handled key is "<transport>|<spec>|<item key>"; the device key here
    // is not that scope, so match on the finding's own part of it.
    final handled = ref.read(svcReportHandledProvider);
    final open = existing
        .where((r) => !handled.any((key) => key.endsWith('|${r.itemKey}')))
        .length;
    if (open >= maxPerDevice) return;
    Log.reports.info('unexpected ${response.problem} at ${response.where}');
    state = {
      ...state,
      deviceKey: [...existing, response],
    };
  }
}

/// Record that a BLE value from [deviceId] would not decode. Empty bytes are
/// not recorded: that is a characteristic with nothing in it yet, not a
/// format the spec gets wrong.
void recordUndecodableBle(
  WidgetRef ref, {
  required String deviceId,
  required String specYaml,
  required String charUuid,
  String? entity,
  required List<int> bytes,
  required Object error,
}) {
  if (bytes.isEmpty) return;
  ref
      .read(responseAnomaliesProvider.notifier)
      .record(
        bleAnomalyKey(deviceId, specYaml),
        SvcReportResponse.undecodableBle(
          charUuid: normalizeUuid(charUuid),
          entity: entity,
          bytes: bytes,
          error: error,
        ),
      );
}

final responseAnomaliesProvider =
    NotifierProvider<
      ResponseAnomalyNotifier,
      Map<String, List<SvcReportResponse>>
    >(ResponseAnomalyNotifier.new);

/// [SvcReport.itemKeys] the user has already sent or dismissed. The banner
/// stays hidden for those findings and comes back only for new ones.
class SvcReportHandledNotifier extends Notifier<Set<String>> {
  static const storageKey = 'svc_report_handled_keys';

  /// FIFO cap so the set cannot grow without bound over the app's life.
  static const maxKeys = 512;

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

  Future<void> markHandled(Iterable<String> keys) async {
    final fresh = [
      for (final k in keys)
        if (!state.contains(k)) k,
    ];
    if (fresh.isEmpty) return;
    final next = [...state, ...fresh];
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
