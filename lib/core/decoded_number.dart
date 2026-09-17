// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A reader for the spec's number-semantics contract, which is evaluated in
// Rust.
//
// A `format:` field can say far more than "two bytes here": `scale` and
// `value_offset` give the linear transform `value = raw * scale +
// value_offset`, `unit` names what the result is measured in, `values` is a
// code table turning an enumerated raw into a word, and `unit_source` says
// whether the unit is a constant of the protocol at all. Applying all of that
// is protocol logic, so it happens in `rust/src/codec/number.rs` and arrives
// already done on every [DecodedValueDto]: `decodedNumber`, `decodedText`,
// `decimals`, `rawNumber`, `valueLabel`, `unit`, `unitSource`, `isOn`.
//
// It used to be applied here, in Dart, and separately again for network
// readings in Rust — the file this replaced opened by declaring itself "the
// one implementation" and then listed the three copies that had to be kept in
// step. Nothing below computes a transform any more; these functions choose
// between the fields Rust already filled in, which is the whole reason they
// still exist as functions rather than as bare field reads: the choices
// (entity unit over field unit, code-table label over number) are the parts a
// layout has to make and must not each invent.
//
// The one arithmetic left is the ENTITY overlay — `state_mapping.scale` and
// `precision`, which belong to an entity rather than to the field and so are
// not known at decode time. It is marked where it happens.

import '../services/spec_codec.dart';

/// The raw integer a decoded field carries, or null when it is not numeric.
///
/// This is the value Rust decoded, not the one the FFI could carry: a `u64`
/// above `i64::MAX` is clamped into [DecodedValueDto.uintValue] and would read
/// as `i64::MAX`, while `rawNumber` is what the device actually sent.
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
    value.rawNumber ?? (value.intValue ?? value.uintValue)?.toDouble();

/// [value] through the spec's linear transform, or null when the field is not
/// numeric.
///
/// The transform itself was applied in Rust; this reads the answer.
///
/// [scaleOverride] is an entity's `state_mapping.scale`, which REPLACES the
/// field's transform rather than compounding with it — an entity-level scale
/// is that layer's complete statement about its own value, which is exactly
/// how `bindings::setpoint_transform` resolves it on the write path. Letting
/// the two multiply would make a reading silently wrong rather than visibly
/// broken, and would put decode and encode out of step. The entity is not
/// known when the characteristic is decoded, so this one multiplication
/// happens here; its Rust twin is `NumberSemantics.scale_override`.
double? decodedNumberOf(DecodedValueDto value, {double? scaleOverride}) {
  if (scaleOverride == null) return value.decodedNumber;
  final raw = rawNumberOf(value);
  return raw == null ? null : raw * scaleOverride;
}

/// Decimal places implied by the transform `raw * scale + offset`.
///
/// Rust already decided this for the reading itself — it is
/// [DecodedValueDto.decimals], and [decodedTextOf] is rendered at it. This
/// spelling exists for the one caller that has to re-render the number rather
/// than show the text: the Home Assistant forwarder sends a JSON number, and
/// an untransformed field has to stay an integer there.
int decimalsForTransform({double? scale, double? valueOffset}) {
  final byScale = _decimalPlaces(scale ?? 1.0);
  final byOffset = _decimalPlaces(valueOffset ?? 0.0);
  return byScale > byOffset ? byScale : byOffset;
}

/// Decimal places for an entity's declared `precision`, expressed as the
/// smallest increment worth showing: 0.1 is one place, 1.0 is none.
///
/// This answers a different question from [decimalsForTransform], which is
/// why it can override it. The transform says how finely the value was
/// *encoded*; `precision` says how finely the device actually *knows* it.
/// They agree most of the time, and where they do not it is because the
/// encoding is finer than the sensor — a characteristic carrying centidegrees
/// from a probe accurate to a tenth renders "23.47 °C" and means "about
/// 23.5". Only a spec author can tell those apart, so nothing is inferred:
/// with no `precision` the transform keeps deciding.
int decimalsForPrecision(double precision) => _decimalPlaces(precision);

/// Decimal places needed to write [v] exactly, capped at [_maxDecimals].
///
/// The mirror of `decimal_places` in `rust/src/codec/number.rs`, kept in step
/// with it by the golden cases in `decoded_number_test.dart`.
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
/// Rust rendered this; with neither entity override in play it is read
/// straight off the DTO, so the GATT browser, the entity cards and the Home
/// Assistant forwarder cannot disagree about what one characteristic read
/// means.
///
/// Never includes the unit or the code-table label — see [labelledTextOf] and
/// [unitOf] for those, which callers combine as their layout needs.
String decodedTextOf(
  DecodedValueDto value, {
  double? scaleOverride,
  double? precision,
}) {
  final hasPrecision = precision != null && precision > 0;
  if (scaleOverride == null && !hasPrecision) {
    return value.decodedText ?? value.display;
  }
  // The entity overlay: an entity's own scale and display precision, neither
  // of which the decoder knows about. Mirrors `NumberSemantics.render`.
  final decoded = decodedNumberOf(value, scaleOverride: scaleOverride);
  if (decoded == null) return value.decodedText ?? value.display;
  if (hasPrecision) {
    // Round to the increment, then print exactly that many places: a
    // precision of 0.5 has to reach 23.5 rather than merely render 23.47 with
    // one place, and both halves are the same statement about resolution.
    //
    // A non-finite reading has no increment to round to — `round()` throws on
    // one — so it is rendered as itself. A malformed spec should read
    // "Infinity", not take the card down.
    final rounded = decoded.isFinite
        ? (decoded / precision).round() * precision
        : decoded;
    return rounded.toStringAsFixed(decimalsForPrecision(precision));
  }
  return decoded.toStringAsFixed(decimalsForTransform(scale: scaleOverride));
}

/// The reading as a person should read it: the `values:` code-table name when
/// the spec declares one, else [decodedTextOf].
///
/// The label wins because for an enumerated field the number IS the code —
/// Ember's `liquid_state: 5` means "heating", and 5 on its own means nothing
/// to anyone who does not have the spec open.
String labelledTextOf(
  DecodedValueDto value, {
  double? scaleOverride,
  double? precision,
}) =>
    value.valueLabel ??
    decodedTextOf(value, scaleOverride: scaleOverride, precision: precision);

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
