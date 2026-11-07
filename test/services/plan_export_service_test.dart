// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/channel_plan.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/services/plan_export_service.dart';

ChannelPlan _plan(
  String name, {
  List<RadioChannel> channels = const [],
  String radioProfileId = 'uv-5r-mini',
}) => ChannelPlan(
  id: 'p1',
  name: name,
  radioProfileId: radioProfileId,
  channels: channels,
  createdAt: DateTime.utc(2026, 8),
  modifiedAt: DateTime.utc(2026, 8),
);

/// The Location cell of each data row: the first cell, which no exported
/// channel here quotes.
Future<List<String>> _locations(ExportedFile exported) async {
  final lines = (await exported.file.readAsString()).split('\r\n');
  return [
    for (final line in lines.skip(1))
      if (line.isNotEmpty) line.split(',').first,
  ];
}

void main() {
  late Directory temp;
  late PlanExportService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plan_export_test');
    service = PlanExportService(dirResolver: () async => temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('writes a CSV under a radio_exports directory', () async {
    final exported = await service.exportChirpCsv(
      _plan(
        'Local',
        channels: const [
          RadioChannel(name: 'W1AW', rxFreqHz: 146940000, txFreqHz: 146340000),
        ],
      ),
    );

    expect(await exported.file.exists(), isTrue);
    expect(exported.file.path, contains('radio_exports'));
    expect(exported.displayName, 'Local.csv');

    final contents = await exported.file.readAsString();
    expect(contents.split('\r\n').first, startsWith('Location,Name,'));
    expect(contents, contains('W1AW'));
  });

  group('numbers channels as the plan\'s radio does', () {
    const channels = [
      RadioChannel(name: 'ONE', rxFreqHz: 146520000, txFreqHz: 146520000),
      RadioChannel(name: 'TWO', rxFreqHz: 446000000, txFreqHz: 446000000),
    ];

    // The UV-5G Mini's 1-30 are its fixed GMRS channels, which CHIRP will
    // not change and the app writes a plan after. Numbered from 1, the file
    // put the plan on them in a CHIRP import.
    test('from 31 on a UV-5G Mini', () async {
      final exported = await service.exportChirpCsv(
        _plan('GMRS', channels: channels, radioProfileId: 'uv-5g-mini'),
      );
      expect(await _locations(exported), ['31', '32']);
    });

    test('from 1 on a radio with no fixed channels', () async {
      final exported = await service.exportChirpCsv(
        _plan('Local', channels: channels),
      );
      expect(await _locations(exported), ['1', '2']);
    });

    // A plan for a radio this build no longer knows still exports, as the
    // radio-agnostic file it always was.
    test('from 1 when this build does not know the radio', () async {
      final exported = await service.exportChirpCsv(
        _plan('Old', channels: channels, radioProfileId: 'retired-radio'),
      );
      expect(await _locations(exported), ['1', '2']);
    });
  });

  test('an empty plan exports a header-only file', () async {
    final exported = await service.exportChirpCsv(_plan('Empty'));
    final contents = await exported.file.readAsString();
    expect(contents.trim().split('\r\n'), hasLength(1));
  });

  test('overwrites a previous export of the same plan', () async {
    await service.exportChirpCsv(_plan('Same'));
    final second = await service.exportChirpCsv(
      _plan(
        'Same',
        channels: const [
          RadioChannel(name: 'NEW', rxFreqHz: 146520000, txFreqHz: 146520000),
        ],
      ),
    );
    expect(await second.file.readAsString(), contains('NEW'));
  });

  group('file naming', () {
    test('keeps a plain name', () {
      expect(
        PlanExportService.fileNameFor(_plan('Local repeaters')),
        'Local-repeaters',
      );
    });

    test('strips characters a path cannot carry', () {
      // Users name plans things like "Dad's truck / GMRS", and a slash in a
      // path component is a directory rather than a character.
      expect(
        PlanExportService.fileNameFor(_plan("Dad's truck / GMRS")),
        'Dad-s-truck-GMRS',
      );
      expect(
        PlanExportService.fileNameFor(_plan('../../etc/passwd')),
        isNot(contains('/')),
      );
      expect(
        PlanExportService.fileNameFor(_plan('../../etc/passwd')),
        isNot(contains('..')),
      );
    });

    test('falls back when nothing usable is left', () {
      expect(PlanExportService.fileNameFor(_plan('///')), 'channel-plan');
      expect(PlanExportService.fileNameFor(_plan('   ')), 'channel-plan');
    });

    test('caps the length', () {
      final name = PlanExportService.fileNameFor(_plan('x' * 500));
      expect(name.length, lessThanOrEqualTo(60));
    });

    test('a hostile name still lands inside the export directory', () async {
      final exported = await service.exportChirpCsv(_plan('../../escape'));
      expect(exported.file.parent.path, endsWith('radio_exports'));
    });
  });
}
