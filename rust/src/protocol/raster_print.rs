// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! Which raster printers this build can drive, and how their bytes travel.
//!
//! A spec says it is a raster printer with the `raster_print` feature marker
//! beside its `image_upload` entry. That marker is declarative; driving the
//! printer needs a handler here, and the handler decides the transport:
//!
//! - [`RasterTransport::RawStream`] — one unframed byte stream over TCP (the
//!   Brother QL raster language on port 9100). The caller opens a socket and
//!   writes what the job encoder returns.
//! - [`RasterTransport::BleWritePlan`] — a GATT write plan from the
//!   image-upload registry (cat printers, Fichero D11). The caller runs the
//!   plan's writes against the connected device.
//! - [`RasterTransport::RfcommStream`] — one unframed byte stream over a
//!   Bluetooth Classic SPP socket (the Brother P-touch Cube's PT raster
//!   language). The caller opens RFCOMM and writes what the job encoder
//!   returns, then reads status frames until the printer says it is done.
//!
//! BLE printers are not listed twice: any `image_upload` handler a
//! `raster_print` spec names is, by definition, its print encoder, so this
//! module asks that registry rather than keeping a second one to drift.

use crate::spec::types::{DeviceSpec, Feature, PrintMedia};

use super::{brother_pt, brother_ql, image_upload_handler};

/// How a raster printer's job reaches it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RasterTransport {
    RawStream,
    BleWritePlan,
    RfcommStream,
}

impl RasterTransport {
    /// The wire name the Dart side routes on.
    pub fn as_str(self) -> &'static str {
        match self {
            RasterTransport::RawStream => "raw_stream",
            RasterTransport::BleWritePlan => "ble_write_plan",
            RasterTransport::RfcommStream => "rfcomm_stream",
        }
    }
}

/// Raw-stream handlers: the ones whose job is a whole byte stream rather
/// than a GATT write plan.
const RAW_STREAM_HANDLERS: &[&str] = &[brother_ql::HANDLER_NAME];

/// Handlers whose job is a byte stream over Bluetooth Classic SPP.
const RFCOMM_STREAM_HANDLERS: &[&str] = &[brother_pt::HANDLER_NAME];

/// The transport for a `protocol_handler` name, or `None` when this build
/// implements no raster encoder under that name.
pub fn transport_for(handler: &str) -> Option<RasterTransport> {
    if RAW_STREAM_HANDLERS.contains(&handler) {
        Some(RasterTransport::RawStream)
    } else if RFCOMM_STREAM_HANDLERS.contains(&handler) {
        Some(RasterTransport::RfcommStream)
    } else if image_upload_handler(handler).is_some() {
        Some(RasterTransport::BleWritePlan)
    } else {
        None
    }
}

/// Whether the spec carries the `raster_print` marker.
pub fn is_raster_printer(spec: &DeviceSpec) -> bool {
    spec.features
        .iter()
        .any(|f| f.feature_type == "raster_print")
}

/// The `image_upload` entry that describes a raster printer's bitmap, when
/// the spec is one. A family spec with one entry per head answers with its
/// first; [`raster_feature_for`] picks the one for a known variant.
pub fn raster_feature(spec: &DeviceSpec) -> Option<&Feature> {
    raster_feature_for(spec, None)
}

/// The `image_upload` entry for `variant`: the one whose `variants` names it
/// (ignoring case), else an entry scoped to no variant, else — for no variant
/// given — the first. A named variant no entry covers gets `None` rather
/// than another model's head: printing a 24 mm layout on a 12 mm head is the
/// mistake this exists to stop.
pub fn raster_feature_for<'a>(spec: &'a DeviceSpec, variant: Option<&str>) -> Option<&'a Feature> {
    if !is_raster_printer(spec) {
        return None;
    }
    let mut entries = spec
        .features
        .iter()
        .filter(|f| f.feature_type == "image_upload");
    let Some(variant) = variant else {
        return entries.next();
    };
    let entries: Vec<&Feature> = entries.collect();
    entries
        .iter()
        .find(|f| f.variants.iter().any(|v| v.eq_ignore_ascii_case(variant)))
        .or_else(|| entries.iter().find(|f| f.variants.is_empty()))
        .copied()
}

/// The variant a raster printer is, from the name it answers to: the
/// longest `device.variants[].model` the name begins with, ignoring case.
/// The Cube family answers as "PT-" + model + the serial's last four
/// numerals, and its models are written with the "PT-" (`PT-P710BT` for
/// `PT-P710BT1234`), so a model is a prefix of every name that model gives.
/// Longest wins so a `PT-P300BTz…` is not read as a `PT-P300BT`. `None` when
/// no model fits, and the caller then takes the spec's first print surface.
pub fn variant_for_device_name(spec: &DeviceSpec, device_name: &str) -> Option<String> {
    let name = device_name.trim().to_ascii_lowercase();
    spec.device
        .variants
        .as_ref()?
        .as_sequence()?
        .iter()
        .filter_map(|v| v.get("model")?.as_str())
        .filter(|model| !model.is_empty() && name.starts_with(&model.to_ascii_lowercase()))
        .max_by_key(|model| model.len())
        .map(str::to_owned)
}

/// The spec's roll matching what a printer reports as loaded: same kind
/// (any die-cut shape counts as die-cut), same width to the millimetre, and
/// for die-cut labels the same length. `None` when the spec lists no such
/// roll — the caller then falls back to arithmetic from the millimetres.
pub fn matching_media(
    feature: &Feature,
    width_mm: u8,
    length_mm: u8,
    die_cut: bool,
) -> Option<&PrintMedia> {
    feature.media.iter().find(|m| {
        let is_die_cut = m.kind != "continuous";
        is_die_cut == die_cut
            && m.width_mm.round() as i64 == i64::from(width_mm)
            && (!die_cut || m.length_mm.map(|l| l.round() as i64) == Some(i64::from(length_mm)))
    })
}

/// Head resolution when a spec does not state one: the 8 dots/mm of
/// practically every cheap thermal mechanism.
pub const ASSUMED_DPI: u32 = 203;

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(yaml: &str) -> DeviceSpec {
        crate::spec::parser::parse_device_spec(yaml).expect("spec parses")
    }

    fn vendored(name: &str) -> DeviceSpec {
        let path = format!(
            "{}/../vendor/protocol-specs/device-specs/devices/{name}",
            env!("CARGO_MANIFEST_DIR")
        );
        parse(&std::fs::read_to_string(path).expect("vendored spec exists"))
    }

    #[test]
    fn transports_follow_the_handler_registries() {
        assert_eq!(
            transport_for("brother_ql_raster"),
            Some(RasterTransport::RawStream)
        );
        assert_eq!(
            transport_for("cat_printer"),
            Some(RasterTransport::BleWritePlan)
        );
        assert_eq!(
            transport_for("fichero_d11"),
            Some(RasterTransport::BleWritePlan)
        );
        assert_eq!(
            transport_for("cat_printer_mxw01"),
            Some(RasterTransport::BleWritePlan)
        );
        assert_eq!(
            transport_for("brother_pt_raster"),
            Some(RasterTransport::RfcommStream)
        );
        assert_eq!(transport_for("nope"), None);
    }

    #[test]
    fn every_vendored_raster_printer_parses_with_its_geometry() {
        let brother = vendored("brother-ql-1110nwb.yaml");
        let feature = raster_feature(&brother).expect("brother is a raster printer");
        let geometry = feature.print_geometry.as_ref().expect("brother geometry");
        assert_eq!(geometry.dpi, Some(300));
        assert_eq!(geometry.head_dots, Some(1296));
        assert_eq!(geometry.mirror_rows, Some(true));
        assert!(feature.media.iter().any(|m| m.kind == "die_cut"));
        assert!(feature
            .media
            .iter()
            .any(|m| m.kind == "continuous" && m.width_mm == 62.0));

        for name in [
            "cat-printer.yaml",
            "cat-printer-mxw01.yaml",
            "fichero-d11-printer.yaml",
            "niimbot-d110.yaml",
        ] {
            let spec = vendored(name);
            assert!(
                raster_feature(&spec).is_some(),
                "{name} is a raster printer"
            );
        }

        let fichero = vendored("fichero-d11-printer.yaml");
        let density = raster_feature(&fichero)
            .and_then(|f| f.print_density.clone())
            .expect("fichero density");
        assert_eq!(density.allowed, vec![0, 1, 2]);
        assert_eq!(density.command.as_deref(), Some("set_density"));
    }

    #[test]
    fn a_family_spec_answers_with_the_head_of_the_variant_asked_for() {
        let cube = vendored("brother-ptouch-cube.yaml");
        let head = |variant| {
            raster_feature_for(&cube, variant)
                .and_then(|f| f.print_geometry.as_ref())
                .and_then(|g| g.head_dots)
        };
        assert_eq!(head(None), Some(128), "the first entry, as before");
        assert_eq!(head(Some("PT-P300BT")), Some(128));
        assert_eq!(head(Some("PT-P910BT")), Some(560));
        assert_eq!(head(Some("pt-p910bt")), Some(560));
        let p710 = raster_feature_for(&cube, Some("PT-P710BT")).unwrap();
        assert_eq!(p710.max_height, Some(7086));
        assert!(raster_feature_for(&cube, Some("PT-N25BT")).is_none());
        // A spec whose entry names no variants serves every variant.
        let brother = vendored("brother-ql-1110nwb.yaml");
        assert!(raster_feature_for(&brother, Some("anything")).is_some());
    }

    #[test]
    fn a_cube_names_its_variant_by_its_advertised_name() {
        let cube = vendored("brother-ptouch-cube.yaml");
        let of = |name| variant_for_device_name(&cube, name);
        assert_eq!(of("PT-P710BT1234").as_deref(), Some("PT-P710BT"));
        assert_eq!(of("PT-P300BTz0001").as_deref(), Some("PT-P300BTz"));
        assert_eq!(of("PT-P300BT0001").as_deref(), Some("PT-P300BT"));
        assert_eq!(of("pt-p910bt9999").as_deref(), Some("PT-P910BT"));
        assert_eq!(of("QL-1110NWB"), None);
        assert_eq!(of(""), None);
    }

    #[test]
    fn a_malformed_print_block_does_not_drop_the_spec() {
        let spec = parse(
            r#"
device:
  name: "Broken Printer"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
  category: "printer"
features:
  - type: "image_upload"
    max_width: 96
    print_geometry: "not a mapping"
    print_density: { allowed: "nope" }
    media:
      - { name: "ok", kind: "continuous", width_mm: 12 }
      - { kind: "missing name" }
  - type: "raster_print"
"#,
        );
        let feature = raster_feature(&spec).expect("still a raster printer");
        assert!(feature.print_geometry.is_none());
        assert!(feature.print_density.is_none());
        assert_eq!(feature.media.len(), 1);
        assert_eq!(feature.max_width, Some(96));
    }

    #[test]
    fn an_image_panel_is_not_a_printer() {
        let spec = parse(
            r#"
device:
  name: "Panel"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
  category: "display"
features:
  - type: "image_upload"
    max_width: 32
"#,
        );
        assert!(raster_feature(&spec).is_none());
    }
}
