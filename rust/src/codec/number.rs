// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The one implementation of the spec's number-semantics contract.
//!
//! A `format:` field says far more than "two bytes here": `scale` and
//! `value_offset` give the linear transform `value = raw * scale +
//! value_offset`, and an entity layered on top may narrow the result with a
//! `precision` or replace the transform outright with its own
//! `state_mapping.scale`. Turning a wire integer into the number a person
//! reads — and back again for a write — is protocol logic, so it lives here,
//! next to the codec that produced the integer, rather than being re-derived
//! by each consumer.
//!
//! It used to be derived by each consumer, and they disagreed: the Dart entity
//! cards applied `scale` and dropped `value_offset`, the GATT browser printed
//! the raw integer, and the Home Assistant forwarder shipped that same raw
//! integer into someone's long-term statistics. One characteristic, three
//! answers. Everything the FFI hands Dart about a number is computed here, so
//! there is one place to be right and one place to change when the schema's
//! number vocabulary grows.

/// Beyond this a reading is showing float noise, not resolution.
pub const MAX_DECIMALS: u32 = 6;

/// How close to whole counts as whole. Loose enough to absorb the float error
/// in a scale like 0.1, tight enough that a genuine fraction still counts.
const INTEGRAL_EPSILON: f64 = 1e-9;

/// Apply a field's linear transform: `value = raw * scale + value_offset`.
///
/// Returns `raw` unchanged when neither term is declared, which is the common
/// case.
pub fn apply_transform(raw: f64, scale: Option<f64>, value_offset: Option<f64>) -> f64 {
    raw * scale.unwrap_or(1.0) + value_offset.unwrap_or(0.0)
}

/// Invert the linear transform to get the raw value a decoded `value` encodes
/// to: `raw = round((value - value_offset) / scale)`.
///
/// `None` when `scale` is zero — that transform is not invertible, and
/// silently substituting 1.0 would write a number the user never asked for.
pub fn invert_transform(value: f64, scale: Option<f64>, value_offset: Option<f64>) -> Option<f64> {
    let scale = scale.unwrap_or(1.0);
    if scale == 0.0 {
        return None;
    }
    Some(((value - value_offset.unwrap_or(0.0)) / scale).round())
}

/// An entity's `state_mapping.scale`, which REPLACES the field's transform
/// rather than compounding with it.
///
/// An entity-level scale is that layer's complete statement about its own
/// value, which is exactly how `bindings::setpoint_transform` resolves it on
/// the write path. Letting the two multiply would make a reading silently
/// wrong rather than visibly broken, and would put decode and encode out of
/// step.
pub fn apply_scale_override(raw: f64, scale_override: f64) -> f64 {
    raw * scale_override
}

/// Decimal places implied by the transform `raw * scale + value_offset`.
///
/// Derived from the transform rather than fixed at 2: a scale of 0.01 wants
/// two places, 0.1 wants one, and an integral transform none — printing
/// "85.00" for a battery percentage claims precision the device never sent.
pub fn decimals_for_transform(scale: Option<f64>, value_offset: Option<f64>) -> u32 {
    let by_scale = decimal_places(scale.unwrap_or(1.0));
    let by_offset = decimal_places(value_offset.unwrap_or(0.0));
    by_scale.max(by_offset)
}

/// Decimal places for an entity's declared `precision`, expressed as the
/// smallest increment worth showing: 0.1 is one place, 1.0 is none.
///
/// This answers a different question from [`decimals_for_transform`], which is
/// why it can override it. The transform says how finely the value was
/// *encoded*; `precision` says how finely the device actually *knows* it.
/// They agree most of the time, and where they do not it is because the
/// encoding is finer than the sensor — a characteristic carrying centidegrees
/// from a probe accurate to a tenth renders "23.47 °C" and means "about
/// 23.5". Only a spec author can tell those apart, so nothing is inferred:
/// with no `precision` the transform keeps deciding.
pub fn decimals_for_precision(precision: f64) -> u32 {
    decimal_places(precision)
}

/// Decimal places needed to write `v` exactly, capped at [`MAX_DECIMALS`].
///
/// Counted by walking the value up to a whole number rather than by splitting
/// a rendered string on '.': a small scale renders in exponent form ("1e-7"),
/// which has no '.' at all, and splitting-and-measuring produced a nonsense
/// place count from the exponent digits.
fn decimal_places(v: f64) -> u32 {
    let abs = v.abs();
    if !abs.is_finite() || abs == 0.0 {
        return 0;
    }
    let mut scaled = abs;
    let mut places = 0;
    while places < MAX_DECIMALS && (scaled - scaled.round()).abs() > INTEGRAL_EPSILON {
        scaled *= 10.0;
        places += 1;
    }
    places
}

/// `value` rounded to the nearest multiple of `precision`.
///
/// A precision of 0.5 has to reach 23.5 rather than merely render 23.47 with
/// one place; rounding to the increment and printing exactly that many places
/// are the same statement about resolution, which is why [`render`] pairs them.
///
/// A non-positive precision is not a statement about resolution at all, and a
/// non-finite reading has nothing to round — both pass through untouched
/// rather than turning a displayable value into a panic.
pub fn round_to_precision(value: f64, precision: f64) -> f64 {
    if !value.is_finite() || !precision.is_finite() || precision <= 0.0 {
        return value;
    }
    (value / precision).round() * precision
}

/// `value` as text at `decimals` places.
///
/// A non-finite value is spelled the way a reader expects rather than padded
/// with zeros: a divide-by-zero scale or an overflowing offset produces
/// infinity, and "Infinity" is a truthful answer where "inf.00" is not. The
/// spellings match Dart's `double.toString()` so the same reading reads the
/// same on both sides of the FFI.
pub fn render(value: f64, decimals: u32) -> String {
    if value.is_nan() {
        return "NaN".to_string();
    }
    if value.is_infinite() {
        return if value.is_sign_negative() {
            "-Infinity".to_string()
        } else {
            "Infinity".to_string()
        };
    }
    format!("{value:.*}", decimals as usize)
}

/// One reading's worth of the contract: the transform, the decimals it
/// implies, and the text that comes out.
///
/// Bundled rather than called as three loose functions because the three have
/// to agree — rounding to a `precision` and then printing the *transform's*
/// decimals renders "23.50" for a value that is only known to "23.5".
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct NumberSemantics {
    /// The field's `scale`.
    pub scale: Option<f64>,
    /// The field's `value_offset`.
    pub value_offset: Option<f64>,
    /// An entity's `state_mapping.scale`. Replaces the field's transform;
    /// see [`apply_scale_override`].
    pub scale_override: Option<f64>,
    /// An entity's display `precision`, the smallest increment worth showing.
    pub precision: Option<f64>,
}

impl NumberSemantics {
    /// The field-level transform alone, with no entity layered on it.
    pub fn from_field(scale: Option<f64>, value_offset: Option<f64>) -> Self {
        Self {
            scale,
            value_offset,
            ..Self::default()
        }
    }

    /// `raw` through whichever transform applies.
    pub fn transform(&self, raw: f64) -> f64 {
        match self.scale_override {
            Some(scale) => apply_scale_override(raw, scale),
            None => apply_transform(raw, self.scale, self.value_offset),
        }
    }

    /// The decoded value back to a raw one, for a write. `None` when the
    /// transform's scale is zero and so cannot be inverted.
    pub fn invert(&self, value: f64) -> Option<f64> {
        match self.scale_override {
            Some(scale) => invert_transform(value, Some(scale), None),
            None => invert_transform(value, self.scale, self.value_offset),
        }
    }

    /// Decimal places a rendering should carry: the entity's `precision` when
    /// it declares one, else what the transform implies.
    pub fn decimals(&self) -> u32 {
        match self.precision {
            Some(p) if p > 0.0 => decimals_for_precision(p),
            _ => match self.scale_override {
                Some(scale) => decimals_for_transform(Some(scale), None),
                None => decimals_for_transform(self.scale, self.value_offset),
            },
        }
    }

    /// `raw` as the text to show: transformed, rounded to the declared
    /// precision, and printed at the places that precision is honest about.
    ///
    /// Never carries the unit or the `values:` code-table label — those are
    /// separate statements a caller combines as its layout needs.
    pub fn render(&self, raw: f64) -> String {
        let mut value = self.transform(raw);
        if let Some(p) = self.precision {
            if p > 0.0 {
                value = round_to_precision(value, p);
            }
        }
        render(value, self.decimals())
    }
}

/// Whether a numeric reading counts as "on".
///
/// `on_value` is the spec's `state_mapping.on_value` — Ember's charging base
/// reads a status code, not a flag. With none declared, any nonzero reading
/// counts, which is also what `on_when: nonzero` spells out explicitly.
pub fn is_on(raw: i64, on_value: Option<i64>) -> bool {
    match on_value {
        Some(on) => raw == on,
        None => raw != 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── transform ──────────────────────────────────────────────────────────

    #[test]
    fn transform_applies_scale_and_offset() {
        // Gerbing's thermometer is raw * 0.5 + 85 °F.
        assert_eq!(apply_transform(100.0, Some(0.5), Some(85.0)), 135.0);
    }

    #[test]
    fn transform_applies_an_offset_with_no_scale() {
        assert_eq!(apply_transform(60.0, None, Some(-40.0)), 20.0);
    }

    #[test]
    fn transform_without_either_term_is_the_identity() {
        assert_eq!(apply_transform(85.0, None, None), 85.0);
    }

    #[test]
    fn a_scale_override_replaces_the_fields_transform() {
        let s = NumberSemantics {
            scale: Some(0.01),
            value_offset: Some(100.0),
            scale_override: Some(0.1),
            precision: None,
        };
        // 0.1 * 50, NOT 50 * 0.01 * 0.1 and not + 100.
        assert_eq!(s.transform(50.0), 5.0);
    }

    // ── invert ─────────────────────────────────────────────────────────────

    #[test]
    fn invert_round_trips_the_transform() {
        assert_eq!(invert_transform(135.0, Some(0.5), Some(85.0)), Some(100.0));
        assert_eq!(invert_transform(23.5, Some(0.01), None), Some(2350.0));
        assert_eq!(invert_transform(20.0, None, Some(-40.0)), Some(60.0));
    }

    #[test]
    fn invert_rounds_to_a_whole_raw_value() {
        // 23.47 °C in centidegrees is 2347, not 2346.9999.
        assert_eq!(invert_transform(23.47, Some(0.01), None), Some(2347.0));
    }

    #[test]
    fn a_zero_scale_is_not_invertible() {
        assert_eq!(invert_transform(5.0, Some(0.0), None), None);
        let s = NumberSemantics::from_field(Some(0.0), None);
        assert_eq!(s.invert(5.0), None);
    }

    #[test]
    fn invert_honours_a_scale_override_alone() {
        let s = NumberSemantics {
            scale: Some(0.01),
            value_offset: Some(100.0),
            scale_override: Some(0.1),
            precision: None,
        };
        assert_eq!(s.invert(5.0), Some(50.0));
    }

    // ── decimals ───────────────────────────────────────────────────────────

    #[test]
    fn decimals_follow_the_scale() {
        assert_eq!(decimals_for_transform(Some(0.01), None), 2);
        assert_eq!(decimals_for_transform(Some(0.1), None), 1);
        assert_eq!(decimals_for_transform(Some(0.5), None), 1);
        assert_eq!(decimals_for_transform(Some(0.001), None), 3);
        assert_eq!(decimals_for_transform(Some(2.5), None), 1);
    }

    #[test]
    fn an_integral_transform_has_no_decimals() {
        assert_eq!(decimals_for_transform(None, None), 0);
        assert_eq!(decimals_for_transform(Some(1.0), None), 0);
        assert_eq!(decimals_for_transform(Some(2.0), Some(-40.0)), 0);
    }

    #[test]
    fn a_fractional_offset_carries_decimals_of_its_own() {
        assert_eq!(decimals_for_transform(Some(1.0), Some(0.25)), 2);
    }

    #[test]
    fn a_tiny_scale_is_capped_rather_than_exploding() {
        let places = decimals_for_transform(Some(1e-7), None);
        assert!(places > 0 && places <= MAX_DECIMALS);
    }

    #[test]
    fn a_negative_scale_counts_its_places_by_magnitude() {
        assert_eq!(decimals_for_transform(Some(-0.5), None), 1);
    }

    #[test]
    fn precision_decimals_read_the_increment() {
        assert_eq!(decimals_for_precision(0.1), 1);
        assert_eq!(decimals_for_precision(0.5), 1);
        assert_eq!(decimals_for_precision(1.0), 0);
        assert_eq!(decimals_for_precision(0.05), 2);
    }

    // ── precision ──────────────────────────────────────────────────────────

    #[test]
    fn precision_rounds_to_the_increment_and_prints_its_places() {
        let centi = NumberSemantics {
            scale: Some(0.01),
            precision: Some(0.1),
            ..Default::default()
        };
        assert_eq!(centi.render(2347.0), "23.5");

        let whole = NumberSemantics {
            scale: Some(0.01),
            precision: Some(1.0),
            ..Default::default()
        };
        assert_eq!(whole.render(2347.0), "23");

        let half = NumberSemantics {
            scale: Some(0.01),
            precision: Some(0.5),
            ..Default::default()
        };
        assert_eq!(half.render(2347.0), "23.5");
    }

    #[test]
    fn no_precision_leaves_the_transform_deciding() {
        let s = NumberSemantics::from_field(Some(0.01), None);
        assert_eq!(s.render(2347.0), "23.47");
    }

    #[test]
    fn a_non_positive_precision_is_not_a_statement_about_resolution() {
        for p in [0.0, -1.0] {
            let s = NumberSemantics {
                scale: Some(0.01),
                precision: Some(p),
                ..Default::default()
            };
            assert_eq!(s.render(2347.0), "23.47", "precision {p}");
        }
    }

    #[test]
    fn precision_does_not_change_the_number_itself() {
        // Controls seed from the transformed value, which must stay exact:
        // rounding for display must not round what gets sent back.
        let s = NumberSemantics {
            scale: Some(0.01),
            precision: Some(0.1),
            ..Default::default()
        };
        assert!((s.transform(2347.0) - 23.47).abs() < 1e-9);
    }

    // ── rendering the un-renderable ────────────────────────────────────────

    #[test]
    fn a_non_finite_reading_renders_instead_of_panicking() {
        // A spec can produce these: an overflowing offset, or an entity scale
        // of infinity from a malformed catalogue entry. The old Dart rounded
        // first and threw on the way.
        let s = NumberSemantics {
            scale: Some(f64::INFINITY),
            precision: Some(0.1),
            ..Default::default()
        };
        assert_eq!(s.render(1.0), "Infinity");

        let neg = NumberSemantics {
            scale: Some(f64::NEG_INFINITY),
            precision: Some(0.1),
            ..Default::default()
        };
        assert_eq!(neg.render(1.0), "-Infinity");

        let nan = NumberSemantics {
            scale: Some(f64::NAN),
            precision: Some(0.5),
            ..Default::default()
        };
        assert_eq!(nan.render(1.0), "NaN");
    }

    #[test]
    fn a_non_finite_reading_renders_without_precision_too() {
        assert_eq!(render(f64::INFINITY, 2), "Infinity");
        assert_eq!(render(f64::NAN, 0), "NaN");
    }

    #[test]
    fn rounding_to_precision_passes_non_finite_values_through() {
        assert!(round_to_precision(f64::INFINITY, 0.1).is_infinite());
        assert!(round_to_precision(f64::NAN, 0.1).is_nan());
        assert_eq!(round_to_precision(23.47, 0.0), 23.47);
    }

    // ── on/off ─────────────────────────────────────────────────────────────

    #[test]
    fn a_declared_on_value_is_the_only_on() {
        assert!(is_on(5, Some(5)));
        assert!(!is_on(1, Some(5)));
        assert!(!is_on(0, Some(5)));
    }

    #[test]
    fn with_no_on_value_any_nonzero_reading_is_on() {
        assert!(is_on(1, None));
        assert!(is_on(-3, None));
        assert!(!is_on(0, None));
    }

    #[test]
    fn zero_can_itself_be_the_on_value() {
        // `on_value: 0` is a real thing — a "not standby" status code.
        assert!(is_on(0, Some(0)));
        assert!(!is_on(1, Some(0)));
    }

    // ── the whole pipeline ─────────────────────────────────────────────────

    #[test]
    fn a_sig_temperature_reads_as_the_spec_says() {
        let s = NumberSemantics::from_field(Some(0.01), None);
        assert!((s.transform(2350.0) - 23.5).abs() < 1e-9);
        assert_eq!(s.decimals(), 2);
        assert_eq!(s.render(2350.0), "23.50");
        assert_eq!(s.invert(23.5), Some(2350.0));
    }

    #[test]
    fn an_untransformed_reading_stays_an_integer() {
        let s = NumberSemantics::default();
        assert_eq!(s.render(85.0), "85");
        assert_eq!(s.decimals(), 0);
    }
}
