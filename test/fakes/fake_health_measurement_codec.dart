// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/health_measurement_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

class FakeHealthMeasurementCodec implements HealthMeasurementCodec {
  HealthSampleDto sample;
  PulseOxHistoryChunkDto Function(List<int> bytes)? historyFor;
  HealthSampleDto Function(List<int> bytes)? sampleFor;
  Object? decodeError;
  Object? encodeError;

  final List<({String commandName, int? page, HealthClockDto? clock})>
  commands = [];
  final List<List<int>> historyCalls = [];

  FakeHealthMeasurementCodec({
    HealthSampleDto? sample,
    this.historyFor,
    this.sampleFor,
    this.decodeError,
    this.encodeError,
  }) : sample = sample ?? const HealthSampleDto();

  @override
  Future<HealthSampleDto> decodeSample({
    required String specYaml,
    required String charUuid,
    required List<int> bytes,
  }) async {
    if (decodeError != null) throw decodeError!;
    return sampleFor?.call(bytes) ?? sample;
  }

  @override
  Future<PulseOxHistoryChunkDto> decodeHistory({
    required String specYaml,
    required List<int> bytes,
  }) async {
    historyCalls.add(List.of(bytes));
    if (decodeError != null) throw decodeError!;
    final history = historyFor;
    if (history == null) {
      return const PulseOxHistoryChunkDto(
        consumed: 0,
        sessions: [],
        records: 0,
        skipped: 0,
        endOfTransfer: false,
      );
    }
    return history(bytes);
  }

  @override
  Future<EntityWriteDto> encodeCommand({
    required String specYaml,
    required String commandName,
    int? page,
    HealthClockDto? clock,
  }) async {
    commands.add((commandName: commandName, page: page, clock: clock));
    if (encodeError != null) throw encodeError!;
    return EntityWriteDto(
      serviceUuid: 'health-service',
      characteristicUuid: commandName,
      bytes: Uint8List.fromList([page ?? 0]),
    );
  }
}
