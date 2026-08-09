// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The one implementation of the spec's number-semantics contract.
//
// A `format:` field can say far more than "two bytes here": `scale` and
// `value_offset` give the linear transform `value = raw * scale +
// value_offset`, `unit` names what the result is measured in, `values` is a
// code table turning an enumerated raw into a word, and `unit_source` says
// whether the unit is a constant of the protocol at all. All five cross the
// FFI on every [DecodedValueDto] (see `rust/src/api/device_api.rs`).
//
// They used to be applied piecemeal, and differently per surface: the entity
// cards applied `scale` and silently dropped `value_offset`, the GATT browser
// applied neither and printed the raw integer, and the Home Assistant
// forwarder shipped that same raw integer into someone's long-term
// statistics. One characteristic, three answers. The rule lives here now, so
// there is one place to be right — and one place to change when the schema's
// number vocabulary grows.
//
// The Rust mirror of this file is `FormatField::apply_transform`; the inverse
// (decoded -> raw, for writes) is `ValueTransform::encode` in
// `rust/src/spec/bindings.rs`. Keep the three in step.

import '../services/spec_codec.dart';

/// The raw integer a decoded field carries, or null when it is not numeric.
///
/// A `bool` field is deliberately NOT numeric here. It has no transform worth
/// applying (the codec never attaches a `values:` label to one — the Rust side
/// resolves the code table from `int_value`/`uint_value` only), and its own
/// rendering, "on"/"off", is already the right answer. Treating it as 0/1
/// would turn every power-state row into a bare "1".
///
/// Controls that genuinely want a bool as a number — seeding a switch from
/// device state — use `EntityLiveValue.rawOf`, which is about wire values
/// rather than about what a person should read.
double? rawNumberOf(DecodedValueDto value) =>
    (value.intValue ?? value.uintValue)?.toDouble();

/// [value] through the spec's linear transform, or null when the field is not
/// numeric.
///
/// [scaleOverride] is an entity's `state_mapping.scale`, which REPLACES the
/// field's transform rather than compounding with it — an entity-level scale
/// is that layer's complete statement about its own value, which is exactly
/// how `bindings::setpoint_transform` resolves it on the write path. Letting
/// the two multiply would make a reading silently wrong rather than visibly
/// broken, and would put decode and encode out of step.
double? decodedNumberOf(DecodedValueDto value, {double? scaleOverride}) {
  final raw = rawNumberOf(value);
  if (raw == null) return null;
  if (scaleOverride != null) return raw * scaleOverride;
  return raw * (value.scale ?? 1.0) + (value.valueOffset ?? 0.0);
}

/// Decimal places implied by the transform `raw * scale + offset`.
///
/// Derived from the transform rather than fixed at 2: a scale of 0.01 wants
/// two places, 0.1 wants one, and an integral transform none — printing
/// "85.00" for a battery percentage claims precision the device never sent.
int decimalsForTransform({double? scale, double? valueOffset}) {
  final byScale = _decimalPlaces(scale ?? 1.0);
  final byOffset = _decimalPlaces(valueOffset ?? 0.0);
  return byScale > byOffset ? byScale : byOffset;
}

/// Decimal places needed to write [v] exactly, capped at [_maxDecimals].
///
/// Counted by walking the value up to a whole number rather than by splitting
/// `toString()` on '.': a small scale renders in exponent form ("1e-7"), which
/// has no '.' at all, and the old split-and-measure produced a nonsense place
/// count from the exponent digits.
int _decimalPlaces(double v) {
  final abs = v.abs();
  if (!abs.isFinite || abs == 0) return 0;
  var scaled = abs;
  var places = 0;
  while (places < _maxDecimals &&
      (scaled - scaled.roundToDouble()).abs() > _integralEpsilon) {
    scaled *= 10;
    places++;
  }
  return places;
}

/// Beyond this a reading is showing float noise, not resolution.
const int _maxDecimals = 6;

/// How close to whole counts as whole. Loose enough to absorb the float error
/// in a scale like 0.1, tight enough that a genuine fraction still counts.
const double _integralEpsilon = 1e-9;

/// The decoded reading as text: the transformed number at the precision its
/// transform implies, or the codec's own rendering for a non-numeric field
/// (a string, a byte blob).
///
/// Never includes the unit or the code-table label — see [labelledTextOf] and
/// [unitOf] for those, which callers combine as their layout needs.
String decodedTextOf(DecodedValueDto value, {double? scaleOverride}) {
  final decoded = decodedNumberOf(value, scaleOverride: scaleOverride);
  if (decoded == null) return value.display;
  final decimals = scaleOverride != null
      ? decimalsForTransform(scale: scaleOverride)
      : decimalsForTransform(scale: value.scale, valueOffset: value.valueOffset);
  return decoded.toStringAsFixed(decimals);
}

/// The reading as a person should read it: the `values:` code-table name when
/// the spec declares one, else [decodedTextOf].
///
/// The label wins because for an enumerated field the number IS the code —
/// Ember's `liquid_state: 5` means "heating", and 5 on its own means nothing
/// to anyone who does not have the spec open.
String labelledTextOf(DecodedValueDto value, {double? scaleOverride}) =>
    value.valueLabel ?? decodedTextOf(value, scaleOverride: scaleOverride);

/// The unit to render beside a reading, or null when there is none to state
/// honestly.
///
/// [entityUnit] is the surfacing entity's own `unit`, which wins over the
/// field's because it describes this reading rather than the field's general
/// encoding.
///
/// A field whose `unit_source` is `device_setting` returns null unless the
/// entity names one: the Inkbird iBBQ transmits whichever unit the device is
/// currently set to, so the same raw 165 is 165 °C or 165 °F and printing
/// either would be a guess dressed as a fact.
String? unitOf(DecodedValueDto value, {String? entityUnit}) {
  if (entityUnit != null && entityUnit.isNotEmpty) return entityUnit;
  if (unitFollowsDeviceSetting(value)) return null;
  final unit = value.unit;
  return (unit == null || unit.isEmpty) ? null : unit;
}

/// Whether the spec says this field's unit follows a device setting rather
/// than being a constant of the protocol.
bool unitFollowsDeviceSetting(DecodedValueDto value) =>
    value.unitSource == 'device_setting';
