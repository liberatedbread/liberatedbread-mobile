// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The printing surface Dart sees: what a raster printer is, in the units a
//! label composer needs to size its canvas.

use crate::protocol::raster_print::{self, ASSUMED_DPI};
use crate::spec::types::{PrintChoice, PrintMedia};

/// A raster printer's print surface, resolved from its spec.
#[derive(Debug, Clone)]
pub struct RasterPrintDto {
    /// The spec's `protocol_handler`, when it names one.
    pub handler: Option<String>,
    /// `raw_stream` (write the job to a TCP socket) or `ble_write_plan` (run
    /// the image-upload write plan over GATT). None when this build has no
    /// encoder for the handler — the printer is known but not printable.
    pub transport: Option<String>,
    /// True when [`Self::transport`] is set: a print from this app will work.
    pub encodable: bool,
    /// Head resolution. Falls back to 203 when the spec states none, and
    /// [`Self::dpi_assumed`] says so.
    pub dpi: u32,
    pub dpi_assumed: bool,
    /// Dots across the head.
    pub head_dots: Option<u32>,
    /// Widest canvas that actually prints: `printable_dots`, else
    /// `head_dots`, else the image feature's `max_width`.
    pub printable_dots: Option<u32>,
    /// Longest label the printer produces, in feed dots.
    pub max_length_dots: Option<u32>,
    /// Loadable rolls and tapes, in spec order. Empty when the spec lists
    /// none (the BLE thermal printers take whatever roll fits the head).
    pub media: Vec<PrintMediaDto>,
    pub density: Option<PrintChoiceDto>,
    pub paper_type: Option<PrintChoiceDto>,
}

/// One loadable roll or tape.
#[derive(Debug, Clone)]
pub struct PrintMediaDto {
    pub name: String,
    /// `continuous`, `die_cut` or `round_die_cut`.
    pub kind: String,
    pub width_mm: f64,
    pub length_mm: Option<f64>,
    /// Dots of this roll that print, across the head.
    pub print_width_dots: Option<u32>,
    /// Dots of one label that print, along the feed (die-cut only).
    pub print_length_dots: Option<u32>,
}

/// A closed choice (density, paper type): wire values with labels.
#[derive(Debug, Clone)]
pub struct PrintChoiceDto {
    pub allowed: Vec<i64>,
    pub labels: Vec<String>,
    pub default_value: Option<i64>,
    pub command: Option<String>,
}

impl From<&PrintMedia> for PrintMediaDto {
    fn from(m: &PrintMedia) -> Self {
        PrintMediaDto {
            name: m.name.clone(),
            kind: m.kind.clone(),
            width_mm: m.width_mm,
            length_mm: m.length_mm,
            print_width_dots: m.print_width_dots,
            print_length_dots: m.print_length_dots,
        }
    }
}

impl From<&PrintChoice> for PrintChoiceDto {
    fn from(c: &PrintChoice) -> Self {
        PrintChoiceDto {
            allowed: c.allowed.clone(),
            labels: c.labels.clone(),
            default_value: c.default,
            command: c.command.clone(),
        }
    }
}

/// The spec's raster-print surface, or None when the spec is not a raster
/// printer (no `raster_print` marker, or no `image_upload` entry beside it).
pub fn raster_print_for_spec(spec_yaml: String) -> anyhow::Result<Option<RasterPrintDto>> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    Ok(raster_print_dto(&spec))
}

pub(crate) fn raster_print_dto(spec: &crate::spec::types::DeviceSpec) -> Option<RasterPrintDto> {
    let feature = raster_print::raster_feature(spec)?;
    let transport = spec
        .protocol_handler
        .as_deref()
        .and_then(raster_print::transport_for);
    let geometry = feature.print_geometry.clone().unwrap_or_default();
    Some(RasterPrintDto {
        handler: spec.protocol_handler.clone(),
        transport: transport.map(|t| t.as_str().to_string()),
        encodable: transport.is_some(),
        dpi: geometry.dpi.unwrap_or(ASSUMED_DPI),
        dpi_assumed: geometry.dpi.is_none(),
        head_dots: geometry.head_dots,
        printable_dots: geometry
            .printable_dots
            .or(geometry.head_dots)
            .or(feature.max_width),
        max_length_dots: geometry.max_length_dots.or(feature.max_height),
        media: feature.media.iter().map(PrintMediaDto::from).collect(),
        density: feature.print_density.as_ref().map(PrintChoiceDto::from),
        paper_type: feature.paper_type.as_ref().map(PrintChoiceDto::from),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vendored(name: &str) -> String {
        let path = format!(
            "{}/../vendor/protocol-specs/device-specs/devices/{name}",
            env!("CARGO_MANIFEST_DIR")
        );
        std::fs::read_to_string(path).expect("vendored spec exists")
    }

    #[test]
    fn brother_is_a_raw_stream_printer_with_its_rolls() {
        let dto = raster_print_for_spec(vendored("brother-ql-1110nwb.yaml"))
            .unwrap()
            .expect("brother prints");
        assert_eq!(dto.transport.as_deref(), Some("raw_stream"));
        assert!(dto.encodable);
        assert_eq!(dto.dpi, 300);
        assert!(!dto.dpi_assumed);
        assert_eq!(dto.printable_dots, Some(1252));
        let roll = dto
            .media
            .iter()
            .find(|m| m.kind == "continuous" && m.width_mm == 62.0)
            .expect("62 mm roll");
        assert!(roll.print_width_dots.is_some());
    }

    #[test]
    fn ble_printers_run_write_plans() {
        for name in ["cat-printer.yaml", "fichero-d11-printer.yaml"] {
            let dto = raster_print_for_spec(vendored(name)).unwrap().expect(name);
            assert_eq!(dto.transport.as_deref(), Some("ble_write_plan"), "{name}");
            assert!(dto.encodable);
            assert!(dto.printable_dots.is_some(), "{name} has a width");
        }
        let fichero = raster_print_for_spec(vendored("fichero-d11-printer.yaml"))
            .unwrap()
            .unwrap();
        assert_eq!(fichero.printable_dots, Some(96));
        assert_eq!(fichero.density.unwrap().default_value, Some(1));
    }

    #[test]
    fn a_printer_without_an_encoder_is_known_but_not_printable() {
        let dto = raster_print_for_spec(vendored("cat-printer-mxw01.yaml"))
            .unwrap()
            .expect("mxw01 is a raster printer");
        assert!(!dto.encodable);
        assert!(dto.transport.is_none());
    }

    #[test]
    fn a_non_printer_has_no_raster_surface() {
        let yaml = "device:\n  name: X\n  manufacturer: Y\n  manufacturer_status: active\n  protocol: ble\n  category: light\n";
        assert!(raster_print_for_spec(yaml.to_string()).unwrap().is_none());
    }
}
