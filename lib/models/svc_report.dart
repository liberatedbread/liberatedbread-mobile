// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Which transport saw the unexpected services. The wire values are the
/// backend's (`ble` / `wifi`); renaming one is a schema change.
enum SvcReportTransport {
  ble('ble'),
  wifi('wifi');

  final String wire;
  const SvcReportTransport(this.wire);
}

/// A GATT characteristic of an unexpected service: what a spec author needs
/// to start describing it, and nothing that identifies the unit.
@immutable
class SvcReportCharacteristic {
  final String uuid;
  final List<String> properties;

  const SvcReportCharacteristic({required this.uuid, required this.properties});

  Map<String, Object?> toJson() => {'uuid': uuid, 'properties': properties};
}

/// One service the matched spec does not declare. For BLE it carries the
/// service's characteristics; for Wi-Fi it is an mDNS type or SSDP target
/// and [characteristics] is empty.
@immutable
class SvcReportEntry {
  /// `gatt`, `mdns` or `ssdp`.
  final String kind;
  final String id;
  final List<SvcReportCharacteristic> characteristics;

  const SvcReportEntry({
    required this.kind,
    required this.id,
    this.characteristics = const [],
  });

  Map<String, Object?> toJson() => {
    'kind': kind,
    'id': id,
    if (characteristics.isNotEmpty)
      'characteristics': [for (final c in characteristics) c.toJson()],
  };
}

/// "This device exposes services its spec does not describe" — the payload
/// the banner sends to the svc-reports backend and puts in the email.
///
/// PRIVACY: this is the whole of what leaves the phone, and it is shown to
/// the user verbatim before they send it. It deliberately carries NO
/// identifier: no BLE address or platform id, no IP, no hostname, no TXT
/// record (those carry MACs and serials), and no mDNS instance name (users
/// name their devices after rooms and people). The BLE advertised name is
/// included because it is what a spec's name matchers key on; it is a model
/// string on nearly every peripheral, and the user sees it before sending.
@immutable
class SvcReport {
  /// Bumped when the payload shape changes; the backend accepts the versions
  /// it knows and rejects the rest.
  static const int schemaVersion = 1;

  /// Random per report, generated on the phone. Lets the backend drop a
  /// retried POST and lets an email be matched to its server copy. Not
  /// derived from anything about the user or device.
  final String reportId;
  final SvcReportTransport transport;

  /// [specKeyFor] of the matched spec.
  final String specKey;
  final String specDeviceName;
  final String specManufacturer;

  /// The BLE advertised name; always null for Wi-Fi (see the class note).
  final String? advertisedName;

  /// What the spec does not declare — the reason for the report.
  final List<SvcReportEntry> unexpected;

  /// Everything the device exposed, in the same normalized form, so a spec
  /// author can see the unexpected ones in context.
  final List<String> discovered;

  /// What the spec declares.
  final List<String> declared;
  final String appVersion;

  /// `android`, `ios`, `linux`, `macos`, `windows`.
  final String platform;

  const SvcReport({
    required this.reportId,
    required this.transport,
    required this.specKey,
    required this.specDeviceName,
    required this.specManufacturer,
    required this.advertisedName,
    required this.unexpected,
    required this.discovered,
    required this.declared,
    required this.appVersion,
    required this.platform,
  });

  /// Identifies "the same surprise" across connects, so a dismissed or sent
  /// banner stays gone for that spec until the device shows something else.
  /// Independent of [reportId], which is new every time.
  String get dedupeKey => [
    transport.wire,
    specKey,
    for (final s in unexpected) '${s.kind}:${s.id}',
  ].join('|');

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'report_id': reportId,
    'transport': transport.wire,
    'spec': {
      'key': specKey,
      'device_name': specDeviceName,
      'manufacturer': specManufacturer,
    },
    if (advertisedName != null) 'advertised_name': advertisedName,
    'unexpected': [for (final s in unexpected) s.toJson()],
    'discovered': discovered,
    'declared': declared,
    'app': {'version': appVersion, 'platform': platform},
  };

  /// [toJson], indented: what the details dialog shows and the email carries.
  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  String get emailSubject =>
      'Unexpected services: $specManufacturer $specDeviceName';

  /// A human-readable summary followed by the exact JSON, so a person can
  /// read it and a script can parse it.
  String get emailBody {
    final lines = <String>[
      'Liberated Bread found services on a device that its spec does not '
          'describe.',
      '',
      'Spec: $specManufacturer $specDeviceName',
      'Transport: ${transport == SvcReportTransport.ble ? 'Bluetooth' : 'Wi-Fi'}',
      'Unexpected:',
      for (final s in unexpected) '  - ${s.kind} ${s.id}',
      '',
      'Anything you can add (model number, firmware version, what the device '
          'does that the app does not show) helps.',
      '',
      '--- report $reportId ---',
      toPrettyJson(),
    ];
    return lines.join('\n');
  }

  /// A `mailto:` URI for [to].
  ///
  /// Built by hand rather than through `Uri(queryParameters:)`, which encodes
  /// spaces as `+`: mail clients take the query literally and show the `+`.
  Uri mailtoUri(String to) => Uri.parse(
    'mailto:$to'
    '?subject=${Uri.encodeComponent(emailSubject)}'
    '&body=${Uri.encodeComponent(emailBody)}',
  );
}

/// A random RFC 4122 version-4 UUID, from a cryptographic source so report
/// ids cannot be predicted or collide by construction.
String newReportId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
  return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10, 16).join()}';
}
