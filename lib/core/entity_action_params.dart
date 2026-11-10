// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../src/rust/api/device_api.dart';

/// What a resolved BLE action sends besides what the user chose.
///
/// A spec can bind a role to a command WITH values — the Lumalou's night
/// light turns on as `{command: set_light_color, values: {color: 0}}` — and
/// Rust resolves the role only because those values fill the command's blanks.
/// Every sender of an [EntityActionDto] goes through [withFixed]; one that
/// forgot would send a command missing a parameter, which the encoder refuses
/// rather than guessing at.
extension EntityActionParams on EntityActionDto {
  /// [userValues] with the values the spec binds this role to on top. The
  /// spec's win a collision: they are what the binding means.
  Map<String, double> withFixed([Map<String, double> userValues = const {}]) =>
      fixedParams.isEmpty ? userValues : {...userValues, ...fixedParams};
}
