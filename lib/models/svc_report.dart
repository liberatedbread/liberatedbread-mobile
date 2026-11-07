// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Which transport saw the unexpected services. The wire values are the
/// backend's (`ble` / `wifi` / `radio`); renaming one is a schema change.
enum SvcReportTransport {
  ble('ble', 'Bluetooth'),
  wifi('wifi', 'Wi-Fi'),

  /// A handheld radio's programming session, over its own Bluetooth or a
  /// USB cable ([SvcReportRadio.link]). Radios are not spec-driven: the
  /// report's subject is the programming profile.
  radio('radio', 'Radio programming');

  final String wire;
  final String label;
  const SvcReportTransport(this.wire, this.label);
}

/// Which radio programming profile a [SvcReportTransport.radio] report is
/// about. Profile and protocol, never the radio's own identity.
@immutable
class SvcReportRadio {
  /// `RadioProfile.id`, e.g. `uv5r`.
  final String profileId;

  /// `ProgrammingFamily.name`, e.g. `serialUv5r`.
  final String family;

  /// `ble` or `usb`.
  final String link;

  const SvcReportRadio({
    required this.profileId,
    required this.family,
    required this.link,
  });

  Map<String, Object?> toJson() => {
    'profile_id': profileId,
    'family': family,
    'link': link,
  };
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

/// What a device said back that the app could not make sense of: the
/// "unexpected response" half of a report.
///
/// PRIVACY: carries the SHAPE of an answer, not its content, except where the
/// content is the thing that failed. A Wi-Fi state reply contributes its key
/// names only, never their values (Kasa's get_sysinfo carries the MAC, the
/// user's name for the plug and its coordinates). A BLE value that would not
/// decode contributes its bytes, capped at [maxSampleBytes] and shown to the
/// user before sending, because a spec author cannot fix a format without
/// them. An unrecognised option contributes the option's raw value, capped
/// the same way.
@immutable
class SvcReportResponse {
  /// Longest [sample] sent, in bytes for hex and characters otherwise.
  static const int maxSampleBytes = 32;

  /// `undecodable_value` (BLE bytes the spec's format rejected),
  /// `unmapped_state` (a Wi-Fi state reply in which no field matched the
  /// entity), or `unrecognized_value` (a value outside the spec's options).
  final String problem;

  /// What answered: `gatt:<uuid>` or `command:<name>`.
  final String where;

  /// The spec entity it was read for, when there is one.
  final String? entity;

  /// One line for a person: an error message, the reply's key names.
  final String detail;

  /// The failing value itself (hex for BLE), when the class note allows it.
  final String? sample;

  const SvcReportResponse({
    required this.problem,
    required this.where,
    this.entity,
    required this.detail,
    this.sample,
  });

  /// A BLE value the spec's format rejected.
  factory SvcReportResponse.undecodableBle({
    required String charUuid,
    String? entity,
    required List<int> bytes,
    required Object error,
  }) => SvcReportResponse(
    problem: 'undecodable_value',
    where: 'gatt:$charUuid',
    entity: entity,
    detail: _oneLine('${bytes.length} bytes; $error'),
    sample: hexSample(bytes),
  );

  /// A Wi-Fi state reply in which no field mapped to [entity]. [keys] are the
  /// reply's field NAMES — never its values (see the class note).
  factory SvcReportResponse.unmappedState({
    required String command,
    required String entity,
    required Iterable<String> keys,
  }) {
    final names = {for (final k in keys) redactKey(k)}.toList()..sort();
    return SvcReportResponse(
      problem: 'unmapped_state',
      where: 'command:$command',
      entity: entity,
      detail: _oneLine(
        names.isEmpty ? 'empty reply' : 'reply keys: ${names.join(', ')}',
      ),
    );
  }

  /// A value outside the options the spec declares for [entity].
  factory SvcReportResponse.unrecognizedValue({
    required String where,
    required String entity,
    required String raw,
  }) => SvcReportResponse(
    problem: 'unrecognized_value',
    where: where,
    entity: entity,
    detail: 'not one of the spec\'s options',
    sample: textSample(raw),
  );

  /// A reply key with any identifier-shaped path segment replaced by `<id>`.
  /// Some replies key their children by MAC, UUID or serial; the shape is
  /// what a spec author needs, not which unit it was.
  ///
  /// IPv4 addresses go first, on the whole key, because the split on `.`
  /// would cut one into harmless-looking numbers.
  static String redactKey(String key) => [
    for (final part in key.replaceAll(_ipv4, '<id>').split('.'))
      _identifierLike.hasMatch(part) ? '<id>' : part,
  ].join('.');

  static final RegExp _ipv4 = RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b');

  static final RegExp _identifierLike = RegExp(
    // MAC (any separator), UUID, or 8+ hex digits / 6+ plain digits anywhere
    // in the segment.
    r'([0-9a-f]{2}[:-]){5}[0-9a-f]{2}|'
    r'[0-9a-f]{8}-[0-9a-f]{4}-|'
    r'[0-9a-f]{8,}|\d{6,}',
    caseSensitive: false,
  );

  /// Longest [detail] sent.
  static const int maxDetailChars = 240;

  static String _oneLine(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= maxDetailChars
        ? flat
        : '${flat.substring(0, maxDetailChars - 1)}…';
  }

  /// BLE bytes, hex-encoded and capped.
  static String hexSample(List<int> bytes) => [
    for (final b in bytes.take(maxSampleBytes))
      (b & 0xff).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// Text capped at [maxSampleBytes] characters.
  static String textSample(String raw) =>
      raw.length <= maxSampleBytes ? raw : raw.substring(0, maxSampleBytes);

  /// The same failure seen twice is one finding.
  String get itemKey => 'resp:$problem:$where:${entity ?? ''}';

  Map<String, Object?> toJson() => {
    'problem': problem,
    'where': where,
    if (entity != null) 'entity': entity,
    'detail': detail,
    if (sample != null) 'sample': sample,
  };

  @override
  bool operator ==(Object other) =>
      other is SvcReportResponse && other.itemKey == itemKey;

  @override
  int get hashCode => itemKey.hashCode;
}

/// "This device did something its spec does not describe": services the
/// spec does not declare, responses the app could not make sense of, or
/// both. The payload the banner sends to the svc-reports backend and puts in
/// the email.
///
/// PRIVACY: this is the whole of what leaves the phone, and it is shown to
/// the user verbatim before they send it. It deliberately carries NO
/// identifier: no BLE address or platform id, no IP, no hostname, no TXT
/// record (those carry MACs and serials), and no mDNS instance name (users
/// name their devices after rooms and people). The BLE advertised name is
/// included because it is what a spec's name matchers key on; it is a model
/// string on nearly every peripheral, and the user sees it before sending.
/// What a response may carry is [SvcReportResponse]'s note.
@immutable
class SvcReport {
  /// Bumped when the payload shape changes; the backend accepts the versions
  /// it knows and rejects the rest.
  ///
  /// 2: the `radio` transport and block, and the optional `user_note`.
  static const int schemaVersion = 2;

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

  /// Services the spec does not declare.
  final List<SvcReportEntry> unexpected;

  /// Responses the app could not make sense of.
  final List<SvcReportResponse> responses;

  /// Everything the device exposed, in the same normalized form, so a spec
  /// author can see the unexpected ones in context.
  final List<String> discovered;

  /// What the spec declares.
  final List<String> declared;
  final String appVersion;

  /// `android`, `ios`, `linux`, `macos`, `windows`.
  final String platform;

  /// Set on, and only on, a [SvcReportTransport.radio] report.
  final SvcReportRadio? radio;

  /// What the user chose to add in the banner's optional details box, or
  /// null. Free text the user typed and sees before sending; capped at
  /// [maxUserNoteChars].
  final String? userNote;

  /// Longest [userNote] sent.
  static const int maxUserNoteChars = 1000;

  const SvcReport({
    required this.reportId,
    required this.transport,
    required this.specKey,
    required this.specDeviceName,
    required this.specManufacturer,
    required this.advertisedName,
    required this.unexpected,
    this.responses = const [],
    required this.discovered,
    required this.declared,
    required this.appVersion,
    required this.platform,
    this.radio,
    this.userNote,
  });

  bool get isEmpty => unexpected.isEmpty && responses.isEmpty;

  /// One key per finding, stable across connects and independent of
  /// [reportId]: what a sent or dismissed banner remembers, so it stays gone
  /// for those findings and comes back only for new ones.
  List<String> get itemKeys => [
    for (final s in unexpected) '${_scope}svc:${s.kind}:${s.id}',
    for (final r in responses) '$_scope${r.itemKey}',
  ];

  String get _scope => '${transport.wire}|$specKey|';

  /// This report with [note] as its [userNote]: trimmed and capped, and
  /// null when blank.
  SvcReport withUserNote(String? note) {
    final trimmed = note?.trim() ?? '';
    return _copy(
      userNote: trimmed.isEmpty
          ? null
          : trimmed.length <= maxUserNoteChars
          ? trimmed
          : trimmed.substring(0, maxUserNoteChars),
      clearNote: trimmed.isEmpty,
    );
  }

  SvcReport _copy({
    String? reportId,
    List<SvcReportEntry>? unexpected,
    List<SvcReportResponse>? responses,
    String? userNote,
    bool clearNote = false,
  }) => SvcReport(
    reportId: reportId ?? this.reportId,
    transport: transport,
    specKey: specKey,
    specDeviceName: specDeviceName,
    specManufacturer: specManufacturer,
    advertisedName: advertisedName,
    unexpected: unexpected ?? this.unexpected,
    responses: responses ?? this.responses,
    discovered: discovered,
    declared: declared,
    appVersion: appVersion,
    platform: platform,
    radio: radio,
    userNote: clearNote ? null : userNote ?? this.userNote,
  );

  /// This report narrowed to the findings not in [handled], or null when
  /// none are left.
  SvcReport? without(Set<String> handled, {String? reportId}) {
    final services = [
      for (final s in unexpected)
        if (!handled.contains('${_scope}svc:${s.kind}:${s.id}')) s,
    ];
    final answers = [
      for (final r in responses)
        if (!handled.contains('$_scope${r.itemKey}')) r,
    ];
    if (services.isEmpty && answers.isEmpty) return null;
    return _copy(reportId: reportId, unexpected: services, responses: answers);
  }

  /// What the report is about, in a sentence: "its Acme Bulb spec", or for a
  /// radio "the Baofeng UV-5R programming profile".
  String get subject => transport == SvcReportTransport.radio
      ? 'the $specDeviceName programming profile'
      : "its ${specManufacturer.isEmpty ? '' : '$specManufacturer '}"
            '$specDeviceName spec';

  /// The subject's name alone, for a subject line.
  String get subjectName => specManufacturer.isEmpty
      ? specDeviceName
      : '$specManufacturer $specDeviceName';

  /// What the banner and email call it.
  String get headline => switch ((unexpected.isEmpty, responses.isEmpty)) {
    (false, true) => 'unexpected services',
    (true, false) => 'unexpected response',
    _ => 'unexpected services and responses',
  };

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
    'responses': [for (final r in responses) r.toJson()],
    'discovered': discovered,
    'declared': declared,
    'app': {'version': appVersion, 'platform': platform},
    if (radio != null) 'radio': radio!.toJson(),
    if (userNote != null) 'user_note': userNote,
  };

  /// [toJson], indented: what the details dialog shows and the email carries.
  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  String get emailSubject {
    final h = headline;
    return '${h[0].toUpperCase()}${h.substring(1)}: $subjectName';
  }

  /// A human-readable summary followed by the exact JSON, so a person can
  /// read it and a script can parse it.
  String get emailBody {
    final lines = <String>[
      transport == SvcReportTransport.radio
          ? 'Liberated Bread saw a radio answer in a way its programming '
                'profile does not expect.'
          : 'Liberated Bread saw a device do something its spec does not '
                'describe.',
      '',
      '${transport == SvcReportTransport.radio ? 'Profile' : 'Spec'}: '
          '$subjectName',
      'Transport: ${transport.label}'
          '${radio == null ? '' : ' (${radio!.link})'}',
      if (unexpected.isNotEmpty) ...[
        'Unexpected services:',
        for (final s in unexpected) '  - ${s.kind} ${s.id}',
      ],
      if (responses.isNotEmpty) ...[
        'Unexpected responses:',
        for (final r in responses)
          '  - ${r.where}${r.entity == null ? '' : ' (${r.entity})'}: '
              '${r.detail}',
      ],
      '',
      if (userNote != null) ...['', 'From the user:', userNote!],
      if (userNote == null)
        'Anything you can add (model number, firmware version, what the '
            'device does that the app does not show) helps.',
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
