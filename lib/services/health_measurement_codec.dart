// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../src/rust/api/health_api.dart';
import '../src/rust/api/health_api.dart' as rust;
import 'spec_codec.dart';

export '../src/rust/api/health_api.dart'
    show
        BloodPressureReadingDto,
        HealthClockDto,
        HealthSampleDto,
        PulseOxHistoryChunkDto,
        PulseOxSampleDto,
        PulseOxSessionDto;

abstract interface class HealthMeasurementCodec {
  Future<HealthSampleDto> decodeSample({
    required String specYaml,
    required String charUuid,
    required List<int> bytes,
  });

  Future<PulseOxHistoryChunkDto> decodeHistory({
    required String specYaml,
    required List<int> bytes,
  });

  Future<EntityWriteDto> encodeCommand({
    required String specYaml,
    required String commandName,
    int? page,
    HealthClockDto? clock,
  });
}

class RustHealthMeasurementCodec implements HealthMeasurementCodec {
  const RustHealthMeasurementCodec();

  @override
  Future<HealthSampleDto> decodeSample({
    required String specYaml,
    required String charUuid,
    required List<int> bytes,
  }) => rust.decodeHealthSample(
    specYaml: specYaml,
    charUuid: charUuid,
    bytes: bytes,
  );

  @override
  Future<PulseOxHistoryChunkDto> decodeHistory({
    required String specYaml,
    required List<int> bytes,
  }) => rust.decodePulseOxHistory(specYaml: specYaml, bytes: bytes);

  @override
  Future<EntityWriteDto> encodeCommand({
    required String specYaml,
    required String commandName,
    int? page,
    HealthClockDto? clock,
  }) => rust.encodeHealthCommand(
    specYaml: specYaml,
    commandName: commandName,
    page: page,
    clock: clock,
  );
}
