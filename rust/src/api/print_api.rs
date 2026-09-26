// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The printing surface Dart sees: what a raster printer is, in the units a
//! label composer needs to size its canvas.

use crate::api::device_api::BrotherQlJobParamsDto;
use crate::protocol::dither::{self, DitherMode};
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
    /// The spec variants this print surface belongs to; empty for every
    /// model. A caller that knows which variant it is connected to offers
    /// printing only when that one is listed.
    pub variants: Vec<String>,
    /// True unless the spec says it has not been run against real hardware
    /// (`device.testing.status: untested`) — the composer says so, rather
    /// than let a first print on a reported-only protocol look routine.
    pub hardware_tested: bool,
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
        variants: feature.variants.clone(),
        hardware_tested: spec
            .device
            .extensions
            .get("testing")
            .and_then(|t| t.get("status"))
            .and_then(|s| s.as_str())
            != Some("untested"),
    })
}

/// How [`prepare_print_raster`] turns grey into black and white.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrintDither {
    /// A hard cut at the threshold — text, QR codes, line art.
    Threshold,
    /// Floyd–Steinberg error diffusion — photos.
    FloydSteinberg,
    /// Atkinson error diffusion — photos, lighter and crisper.
    Atkinson,
}

/// Reduce a composed RGBA canvas (straight alpha) to the black-and-white
/// RGB888 every raster printer encoder takes, and the preview shows.
pub fn prepare_print_raster(
    rgba: Vec<u8>,
    width: u32,
    height: u32,
    dither: PrintDither,
    threshold: u8,
) -> anyhow::Result<Vec<u8>> {
    let (w, h) = (width as usize, height as usize);
    if w == 0 || h == 0 {
        anyhow::bail!("an empty canvas has nothing to print");
    }
    if rgba.len() != w * h * 4 {
        anyhow::bail!(
            "an RGBA canvas of {width}x{height} is {} bytes, not {}",
            w * h * 4,
            rgba.len()
        );
    }
    let mode = match dither {
        PrintDither::Threshold => DitherMode::Threshold,
        PrintDither::FloydSteinberg => DitherMode::FloydSteinberg,
        PrintDither::Atkinson => DitherMode::Atkinson,
    };
    Ok(dither::to_mono_rgb(&rgba, w, h, mode, threshold))
}

/// The canvas a Brother QL label should be composed on for the loaded roll.
#[derive(Debug, Clone)]
pub struct LabelCanvasDto {
    /// Dots across the tape that print.
    pub width_dots: u32,
    /// Dots along the feed that print, for a die-cut label; None for
    /// continuous tape, whose length the content decides.
    pub length_dots: Option<u32>,
    pub dpi: u32,
    /// The spec's name for the roll ("62mm continuous (DK-22205)"), when the
    /// loaded media matched one.
    pub media_name: Option<String>,
}

/// Where a label canvas sits on a Brother QL head.
struct BrotherPlacement {
    head_dots: usize,
    /// Dots from the print's left edge to the canvas's column 0.
    left: usize,
    /// Widest canvas that prints.
    width: usize,
    /// Printable length of one die-cut label.
    length: Option<usize>,
    feed_margin: u16,
    dpi: u32,
    media_name: Option<String>,
}

fn brother_placement(
    spec: &crate::spec::types::DeviceSpec,
    params: &BrotherQlJobParamsDto,
) -> anyhow::Result<BrotherPlacement> {
    let feature = crate::protocol::image_upload::image_feature(spec)
        .ok_or_else(|| anyhow::anyhow!("the spec declares no image_upload feature"))?;
    let geometry = feature.print_geometry.clone().unwrap_or_default();
    let head_dots = geometry
        .head_dots
        .or(feature.max_width)
        .ok_or_else(|| anyhow::anyhow!("the spec states no head width"))?
        as usize;
    let dead_zone = geometry.additional_offset_right_dots.unwrap_or(0) as usize;
    let dpi = geometry.dpi.unwrap_or(300);
    let feed_margin = geometry.feed_margin_dots.unwrap_or(35);
    let media = raster_print::matching_media(
        feature,
        params.media_width_mm,
        params.media_length_mm,
        params.media_die_cut,
    );
    match media.and_then(|m| m.print_width_dots.map(|w| (m, w as usize))) {
        // The spec's roll table: brother_ql's placement — the printable width
        // sits `right_margin + dead zone` in from the head's right end.
        Some((m, width)) => {
            let right = m.right_margin_dots.unwrap_or(0) as usize + dead_zone;
            let width = width.min(head_dots.saturating_sub(right)).max(1);
            Ok(BrotherPlacement {
                head_dots,
                left: head_dots.saturating_sub(width + right),
                width,
                length: m
                    .print_length_dots
                    .map(|l| l as usize)
                    .filter(|_| params.media_die_cut),
                feed_margin: m
                    .feed_margin_dots
                    .map(|f| f as u16)
                    .unwrap_or(feed_margin as u16),
                dpi,
                media_name: Some(m.name.clone()),
            })
        }
        // A roll the spec does not list: millimetres to dots, left-aligned,
        // kept off the dead zone — the test label's long-standing arithmetic.
        None => {
            let width = (params.media_width_mm as usize * dpi as usize * 10 / 254)
                .min(head_dots.saturating_sub(dead_zone))
                .max(8);
            let length = params.media_die_cut.then(|| {
                let l = params.media_length_mm as usize * dpi as usize * 10 / 254;
                (l - l / 8).max(1)
            });
            Ok(BrotherPlacement {
                head_dots,
                left: 0,
                width,
                length,
                feed_margin: feed_margin as u16,
                dpi,
                media_name: None,
            })
        }
    }
}

/// The canvas to compose a Brother QL label on, for the media the printer
/// reported (or the caller assumed).
pub fn brother_ql_label_canvas(
    spec_yaml: String,
    params: BrotherQlJobParamsDto,
) -> anyhow::Result<LabelCanvasDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let p = brother_placement(&spec, &params)?;
    Ok(LabelCanvasDto {
        width_dots: p.width as u32,
        length_dots: p.length.map(|l| l as u32),
        dpi: p.dpi,
        media_name: p.media_name,
    })
}

/// Encode a composed label as a Brother QL raster job. `rgb` is RGB888 of
/// `width` x `height`, at most the canvas [`brother_ql_label_canvas`] gives;
/// a narrower canvas is centred in the printable width. The result is the
/// whole byte stream for TCP 9100.
pub fn render_brother_ql_job(
    spec_yaml: String,
    params: BrotherQlJobParamsDto,
    rgb: Vec<u8>,
    width: u32,
    height: u32,
) -> anyhow::Result<Vec<u8>> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let p = brother_placement(&spec, &params)?;
    let (w, h) = (width as usize, height as usize);
    if w == 0 || h == 0 || rgb.len() != w * h * 3 {
        anyhow::bail!(
            "an RGB canvas of {width}x{height} must be {} bytes",
            w * h * 3
        );
    }
    if w > p.width {
        anyhow::bail!(
            "the label is {w} dots wide but this roll prints {} — compose it on the roll's canvas",
            p.width
        );
    }
    let left = p.left + (p.width - w) / 2;
    let mut head = vec![255u8; p.head_dots * h * 3];
    for y in 0..h {
        let src = &rgb[y * w * 3..(y + 1) * w * 3];
        let at = (y * p.head_dots + left) * 3;
        head[at..at + w * 3].copy_from_slice(src);
    }
    let media = crate::protocol::brother_ql::Media {
        media_type: if params.media_die_cut {
            crate::protocol::brother_ql::MediaType::DieCut
        } else {
            crate::protocol::brother_ql::MediaType::Continuous
        },
        width_mm: params.media_width_mm,
        length_mm: if params.media_die_cut {
            params.media_length_mm
        } else {
            0
        },
    };
    let options = crate::protocol::brother_ql::JobOptions {
        auto_cut: params.auto_cut,
        margin_dots: p.feed_margin,
        ..Default::default()
    };
    Ok(crate::protocol::brother_ql::encode_print_job(
        &spec,
        &head,
        p.head_dots as u32,
        height,
        media,
        options,
    )?)
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

    fn params(width: u8, length: u8, die_cut: bool) -> BrotherQlJobParamsDto {
        BrotherQlJobParamsDto {
            media_width_mm: width,
            media_length_mm: length,
            media_die_cut: die_cut,
            auto_cut: true,
        }
    }

    /// Dot indices (from the print's left edge) lit in the first raster row.
    fn first_row_lit(job: &[u8], head_dots: usize) -> Vec<usize> {
        let row_bytes = head_dots / 8;
        let start = job
            .windows(3)
            .position(|w| w == [0x67, 0x00, row_bytes as u8])
            .expect("a raster row");
        let row = &job[start + 3..start + 3 + row_bytes];
        (0..head_dots)
            .filter(|i| row[i / 8] & (0x80 >> (i % 8)) != 0)
            .map(|i| head_dots - 1 - i)
            .rev()
            .collect()
    }

    #[test]
    fn the_62mm_roll_canvas_and_placement_come_from_the_spec() {
        let yaml = vendored("brother-ql-1110nwb.yaml");
        let canvas = brother_ql_label_canvas(yaml.clone(), params(62, 0, false)).unwrap();
        assert_eq!(canvas.dpi, 300);
        assert!(canvas.length_dots.is_none());
        assert!(canvas.media_name.unwrap().contains("62"));
        let w = canvas.width_dots as usize;

        let rgb = [0u8, 0, 0].repeat(w * 2);
        let job = render_brother_ql_job(yaml, params(62, 0, false), rgb, w as u32, 2).unwrap();
        let lit = first_row_lit(&job, 1296);
        assert_eq!(lit.len(), w, "the whole canvas prints");
        // The run ends right_margin (12) + dead zone (44) dots from the
        // head's right end, as brother_ql places it.
        assert_eq!(*lit.last().unwrap(), 1296 - 1 - (12 + 44));
    }

    #[test]
    fn a_die_cut_roll_fixes_the_length() {
        let yaml = vendored("brother-ql-1110nwb.yaml");
        let canvas = brother_ql_label_canvas(yaml, params(17, 54, true)).unwrap();
        assert_eq!(canvas.width_dots, 165);
        assert_eq!(canvas.length_dots, Some(566));
    }

    #[test]
    fn a_narrow_canvas_is_centred_and_an_oversized_one_refused() {
        let yaml = vendored("brother-ql-1110nwb.yaml");
        let canvas = brother_ql_label_canvas(yaml.clone(), params(62, 0, false)).unwrap();
        let full = canvas.width_dots as usize;
        let job = render_brother_ql_job(
            yaml.clone(),
            params(62, 0, false),
            [0u8, 0, 0].repeat(100),
            100,
            1,
        )
        .unwrap();
        let lit = first_row_lit(&job, 1296);
        let full_left = 1296 - (12 + 44) - full;
        assert_eq!(lit[0], full_left + (full - 100) / 2);

        let too_wide = (full + 1) as u32;
        assert!(render_brother_ql_job(
            yaml,
            params(62, 0, false),
            vec![0; (full + 1) * 3],
            too_wide,
            1
        )
        .is_err());
    }

    #[test]
    fn an_unlisted_roll_falls_back_to_millimetres() {
        let yaml = vendored("brother-ql-1110nwb.yaml");
        // No 45 mm roll in the table.
        let canvas = brother_ql_label_canvas(yaml, params(45, 0, false)).unwrap();
        assert!(canvas.media_name.is_none());
        assert_eq!(canvas.width_dots, 45 * 3000 / 254);
    }

    #[test]
    fn prepare_print_raster_checks_its_buffer() {
        assert!(prepare_print_raster(vec![0; 15], 2, 2, PrintDither::Threshold, 128).is_err());
        assert!(prepare_print_raster(vec![], 0, 0, PrintDither::Threshold, 128).is_err());
        let out =
            prepare_print_raster(vec![0, 0, 0, 255], 1, 1, PrintDither::Atkinson, 128).unwrap();
        assert_eq!(out, vec![0, 0, 0]);
    }

    #[test]
    fn the_niimbot_surface_is_scoped_to_the_d110() {
        let yaml = std::fs::read_to_string(format!(
            "{}/tests/specs/niimbot-d110.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        let dto = raster_print_for_spec(yaml)
            .unwrap()
            .expect("a raster printer");
        assert_eq!(dto.transport.as_deref(), Some("ble_write_plan"));
        assert_eq!(dto.variants, vec!["D110"]);
        assert_eq!(dto.printable_dots, Some(96));
        assert_eq!(dto.dpi, 203);
        assert_eq!(dto.density.unwrap().allowed, vec![1, 2, 3]);
        assert!(!dto.hardware_tested, "the D110 task is reported, not run");
    }
}
