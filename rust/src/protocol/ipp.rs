// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! IPP status: build a Get-Printer-Attributes request and read the reply.
//!
//! RFC 8010 binary encoding, as the `ipp-network-printer` spec's
//! `protocol_details.ipp_status` states it. The request goes in the body of
//! an HTTP POST (`Content-Type: application/ipp`) that Dart sends; this
//! module owns the bytes on both sides. Read-only: nothing here prints.
//!
//! ```text
//! request:  [version 02 00][op 00 0B][request-id u32]
//!           [01] attributes-charset, attributes-natural-language,
//!                printer-uri, requested-attributes (1setOf keyword)
//!           [03]
//! attribute: [value-tag][name-len u16][name][value-len u16][value]
//!            (a further 1setOf value repeats the tag with name-len 0)
//! reply:    [version][status u16][request-id u32] groups... [03]
//! ```

use crate::error::ProtocolError;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "ipp_status";

const OP_GET_PRINTER_ATTRIBUTES: u16 = 0x000B;

const TAG_OPERATION: u8 = 0x01;
const TAG_END: u8 = 0x03;
const TAG_PRINTER: u8 = 0x04;

const VT_INTEGER: u8 = 0x21;
const VT_BOOLEAN: u8 = 0x22;
const VT_ENUM: u8 = 0x23;
const VT_TEXT_WITH_LANGUAGE: u8 = 0x35;
const VT_NAME_WITH_LANGUAGE: u8 = 0x36;
const VT_KEYWORD: u8 = 0x44;
const VT_URI: u8 = 0x45;
const VT_CHARSET: u8 = 0x47;
const VT_NATURAL_LANGUAGE: u8 = 0x48;

/// What the status screen asks for — and all it asks for, so a slow printer
/// is not made to serialise its whole attribute catalogue.
pub const REQUESTED_ATTRIBUTES: &[&str] = &[
    "printer-state",
    "printer-state-reasons",
    "printer-state-message",
    "printer-make-and-model",
    "marker-names",
    "marker-colors",
    "marker-types",
    "marker-levels",
    "marker-low-levels",
    "media-ready",
    "document-format-supported",
];

/// A Get-Printer-Attributes request for `printer_uri`
/// (`ipp://host:631/ipp/print`), IPP 2.0.
pub fn encode_get_printer_attributes(printer_uri: &str, request_id: u32) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&[0x02, 0x00]);
    out.extend_from_slice(&OP_GET_PRINTER_ATTRIBUTES.to_be_bytes());
    out.extend_from_slice(&request_id.to_be_bytes());
    out.push(TAG_OPERATION);
    attribute(&mut out, VT_CHARSET, "attributes-charset", b"utf-8");
    attribute(
        &mut out,
        VT_NATURAL_LANGUAGE,
        "attributes-natural-language",
        b"en",
    );
    attribute(&mut out, VT_URI, "printer-uri", printer_uri.as_bytes());
    for (i, name) in REQUESTED_ATTRIBUTES.iter().enumerate() {
        // The first value carries the name; each further one is an
        // additional value of the same 1setOf, with an empty name.
        let attr_name = if i == 0 { "requested-attributes" } else { "" };
        attribute(&mut out, VT_KEYWORD, attr_name, name.as_bytes());
    }
    out.push(TAG_END);
    out
}

fn attribute(out: &mut Vec<u8>, tag: u8, name: &str, value: &[u8]) {
    out.push(tag);
    out.extend_from_slice(&(name.len() as u16).to_be_bytes());
    out.extend_from_slice(name.as_bytes());
    out.extend_from_slice(&(value.len() as u16).to_be_bytes());
    out.extend_from_slice(value);
}

/// One ink or toner supply, from the index-aligned `marker-*` attributes.
#[derive(Debug, Clone, PartialEq)]
pub struct Marker {
    pub name: String,
    /// `#RRGGBB`, or several joined for a multi-colour cartridge; None when
    /// the printer does not say.
    pub color: Option<String>,
    /// `toner`, `ink-cartridge`, ... when stated.
    pub kind: Option<String>,
    /// Percent remaining; None when the printer reports unknown (-1, -2).
    /// -3 ("some remaining") is also None, with [`Self::some_remaining`].
    pub level: Option<u8>,
    pub some_remaining: bool,
    /// At or below this percent the printer calls the supply low.
    pub low_level: Option<u8>,
}

/// A decoded Get-Printer-Attributes reply.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PrinterStatus {
    /// The IPP status code; below 0x0100 is success.
    pub status_code: u16,
    /// `idle`, `processing`, `stopped`, or `unknown`.
    pub state: String,
    pub state_reasons: Vec<String>,
    pub state_message: Option<String>,
    pub make_and_model: Option<String>,
    pub markers: Vec<Marker>,
    pub media_ready: Vec<String>,
    pub document_formats: Vec<String>,
}

/// One attribute value as read off the wire.
#[derive(Debug, Clone)]
enum Value {
    Int(i32),
    Text(String),
    Other,
}

/// Decode a reply. Every length is checked against the buffer: a truncated
/// or hostile reply is an error, never a panic or an over-read.
pub fn decode_printer_attributes(bytes: &[u8]) -> Result<PrinterStatus, ProtocolError> {
    let bad = |reason: &str| ProtocolError::MalformedReply(format!("IPP reply {reason}"));
    if bytes.len() < 8 {
        return Err(bad("is shorter than its 8-byte header"));
    }
    let status_code = u16::from_be_bytes([bytes[2], bytes[3]]);
    let mut pos = 8;
    let mut group = 0u8;
    let mut current: Option<String> = None;
    let mut attrs: Vec<(String, Vec<Value>)> = Vec::new();

    let read_u16 = |pos: usize| -> Result<usize, ProtocolError> {
        bytes
            .get(pos..pos + 2)
            .map(|b| u16::from_be_bytes([b[0], b[1]]) as usize)
            .ok_or_else(|| bad("is truncated"))
    };

    loop {
        let tag = *bytes.get(pos).ok_or_else(|| bad("has no end tag"))?;
        pos += 1;
        if tag == TAG_END {
            break;
        }
        if tag < 0x10 {
            // A delimiter: a new attribute group begins.
            group = tag;
            current = None;
            continue;
        }
        let name_len = read_u16(pos)?;
        pos += 2;
        let name = bytes
            .get(pos..pos + name_len)
            .ok_or_else(|| bad("is truncated in a name"))?;
        pos += name_len;
        let value_len = read_u16(pos)?;
        pos += 2;
        let raw = bytes
            .get(pos..pos + value_len)
            .ok_or_else(|| bad("is truncated in a value"))?;
        pos += value_len;

        if name_len > 0 {
            current = Some(String::from_utf8_lossy(name).into_owned());
            if group == TAG_PRINTER {
                attrs.push((current.clone().unwrap(), Vec::new()));
            }
        }
        if group != TAG_PRINTER || current.is_none() {
            continue;
        }
        let value = match tag {
            VT_INTEGER | VT_ENUM if raw.len() == 4 => {
                Value::Int(i32::from_be_bytes([raw[0], raw[1], raw[2], raw[3]]))
            }
            VT_BOOLEAN => Value::Other,
            VT_TEXT_WITH_LANGUAGE | VT_NAME_WITH_LANGUAGE => {
                // [u16 lang len][lang][u16 text len][text]
                let lang = raw
                    .get(0..2)
                    .map(|b| u16::from_be_bytes([b[0], b[1]]) as usize)
                    .unwrap_or(usize::MAX);
                let text = raw.get(2 + lang..).and_then(|rest| {
                    let n = rest
                        .get(0..2)
                        .map(|b| u16::from_be_bytes([b[0], b[1]]) as usize)?;
                    rest.get(2..2 + n)
                });
                match text {
                    Some(t) => Value::Text(String::from_utf8_lossy(t).into_owned()),
                    None => Value::Other,
                }
            }
            // Out-of-band values (unknown, no-value, ...) carry nothing.
            0x10..=0x1F => Value::Other,
            // text, name, keyword, uri, mimeMediaType, charset, language, ...
            0x40..=0x4F => Value::Text(String::from_utf8_lossy(raw).into_owned()),
            _ => Value::Other,
        };
        if let Some(last) = attrs.last_mut() {
            last.1.push(value);
        }
    }

    let get = |name: &str| -> &[Value] {
        attrs
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_slice())
            .unwrap_or(&[])
    };
    let texts = |name: &str| -> Vec<String> {
        get(name)
            .iter()
            .filter_map(|v| match v {
                Value::Text(t) => Some(t.clone()),
                _ => None,
            })
            .collect()
    };
    let ints = |name: &str| -> Vec<Option<i32>> {
        get(name)
            .iter()
            .map(|v| match v {
                Value::Int(i) => Some(*i),
                _ => None,
            })
            .collect()
    };

    let state = match ints("printer-state").first().copied().flatten() {
        Some(3) => "idle",
        Some(4) => "processing",
        Some(5) => "stopped",
        _ => "unknown",
    }
    .to_string();

    let names = texts("marker-names");
    let colors = texts("marker-colors");
    let kinds = texts("marker-types");
    let levels = ints("marker-levels");
    let lows = ints("marker-low-levels");
    let pct = |v: Option<i32>| v.filter(|l| (0..=100).contains(l)).map(|l| l as u8);
    let markers = names
        .iter()
        .enumerate()
        .map(|(i, name)| {
            let raw = levels.get(i).copied().flatten();
            Marker {
                name: name.clone(),
                color: colors.get(i).cloned().filter(|c| c.starts_with('#')),
                kind: kinds.get(i).cloned(),
                level: pct(raw),
                some_remaining: raw == Some(-3),
                low_level: pct(lows.get(i).copied().flatten()),
            }
        })
        .collect();

    Ok(PrinterStatus {
        status_code,
        state,
        state_reasons: texts("printer-state-reasons")
            .into_iter()
            .filter(|r| r != "none")
            .collect(),
        state_message: texts("printer-state-message")
            .into_iter()
            .next()
            .filter(|m| !m.trim().is_empty()),
        make_and_model: texts("printer-make-and-model").into_iter().next(),
        markers,
        media_ready: texts("media-ready"),
        document_formats: texts("document-format-supported"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A reply built the way a printer would send it.
    struct Reply(Vec<u8>);

    impl Reply {
        fn new(status: u16) -> Self {
            let mut b = vec![0x02, 0x00];
            b.extend_from_slice(&status.to_be_bytes());
            b.extend_from_slice(&7u32.to_be_bytes());
            b.push(TAG_OPERATION);
            attribute(&mut b, VT_CHARSET, "attributes-charset", b"utf-8");
            b.push(TAG_PRINTER);
            Reply(b)
        }
        fn attr(mut self, tag: u8, name: &str, values: &[&[u8]]) -> Self {
            for (i, v) in values.iter().enumerate() {
                attribute(&mut self.0, tag, if i == 0 { name } else { "" }, v);
            }
            self
        }
        fn ints(self, tag: u8, name: &str, values: &[i32]) -> Self {
            let bytes: Vec<[u8; 4]> = values.iter().map(|v| v.to_be_bytes()).collect();
            let refs: Vec<&[u8]> = bytes.iter().map(|b| b.as_slice()).collect();
            self.attr(tag, name, &refs)
        }
        fn end(mut self) -> Vec<u8> {
            self.0.push(TAG_END);
            self.0
        }
    }

    #[test]
    fn the_request_is_rfc_8010_get_printer_attributes() {
        let req = encode_get_printer_attributes("ipp://192.168.1.50:631/ipp/print", 1);
        assert_eq!(&req[..8], &[0x02, 0x00, 0x00, 0x0B, 0, 0, 0, 1]);
        assert_eq!(req[8], TAG_OPERATION);
        // First attribute: charset, spelled out.
        let mut expect = vec![VT_CHARSET, 0x00, 18];
        expect.extend_from_slice(b"attributes-charset");
        expect.extend_from_slice(&[0x00, 5]);
        expect.extend_from_slice(b"utf-8");
        assert_eq!(&req[9..9 + expect.len()], expect.as_slice());
        assert_eq!(*req.last().unwrap(), TAG_END);
        // Every requested attribute is in there, and the 1setOf repeats the
        // keyword tag with an empty name.
        for name in REQUESTED_ATTRIBUTES {
            assert!(
                req.windows(name.len()).any(|w| w == name.as_bytes()),
                "{name}"
            );
        }
        let mut repeat = vec![VT_KEYWORD, 0x00, 0x00, 0x00, 21];
        repeat.extend_from_slice(b"printer-state-reasons");
        assert!(req.windows(repeat.len()).any(|w| w == repeat.as_slice()));
    }

    #[test]
    fn a_reply_decodes_state_supplies_and_paper() {
        let reply = Reply::new(0x0000)
            .ints(VT_ENUM, "printer-state", &[5])
            .attr(
                VT_KEYWORD,
                "printer-state-reasons",
                &[b"media-empty-error", b"toner-low-report"],
            )
            .attr(0x41, "printer-state-message", &[b"Load paper in tray 1"])
            .attr(0x41, "printer-make-and-model", &[b"Example LaserJet 400"])
            .attr(0x42, "marker-names", &[b"Black Toner", b"Cyan Toner"])
            .attr(0x42, "marker-colors", &[b"#000000", b"#00FFFF"])
            .attr(VT_KEYWORD, "marker-types", &[b"toner", b"toner"])
            .ints(VT_INTEGER, "marker-levels", &[12, -3])
            .ints(VT_INTEGER, "marker-low-levels", &[15, 15])
            .attr(VT_KEYWORD, "media-ready", &[b"iso_a4_210x297mm"])
            .attr(
                0x49,
                "document-format-supported",
                &[b"application/pdf", b"image/pwg-raster"],
            )
            .end();
        let s = decode_printer_attributes(&reply).unwrap();
        assert_eq!(s.status_code, 0);
        assert_eq!(s.state, "stopped");
        assert_eq!(
            s.state_reasons,
            vec!["media-empty-error", "toner-low-report"]
        );
        assert_eq!(s.state_message.as_deref(), Some("Load paper in tray 1"));
        assert_eq!(s.make_and_model.as_deref(), Some("Example LaserJet 400"));
        assert_eq!(s.markers.len(), 2);
        assert_eq!(s.markers[0].level, Some(12));
        assert_eq!(s.markers[0].low_level, Some(15));
        assert_eq!(s.markers[0].color.as_deref(), Some("#000000"));
        assert_eq!(s.markers[1].level, None);
        assert!(s.markers[1].some_remaining);
        assert_eq!(s.media_ready, vec!["iso_a4_210x297mm"]);
        assert_eq!(s.document_formats.len(), 2);
    }

    #[test]
    fn none_is_not_a_reason_and_unknown_levels_are_unknown() {
        let reply = Reply::new(0x0001)
            .ints(VT_ENUM, "printer-state", &[3])
            .attr(VT_KEYWORD, "printer-state-reasons", &[b"none"])
            .attr(0x42, "marker-names", &[b"Ink"])
            .ints(VT_INTEGER, "marker-levels", &[-1])
            .end();
        let s = decode_printer_attributes(&reply).unwrap();
        assert_eq!(s.state, "idle");
        assert!(s.state_reasons.is_empty());
        assert_eq!(s.markers[0].level, None);
        assert!(!s.markers[0].some_remaining);
    }

    #[test]
    fn a_text_with_language_value_is_read_through_its_language() {
        let mut v = vec![0x00, 0x02];
        v.extend_from_slice(b"en");
        v.extend_from_slice(&[0x00, 0x05]);
        v.extend_from_slice(b"Ready");
        let reply = Reply::new(0)
            .attr(VT_TEXT_WITH_LANGUAGE, "printer-state-message", &[&v])
            .end();
        let s = decode_printer_attributes(&reply).unwrap();
        assert_eq!(s.state_message.as_deref(), Some("Ready"));
        assert_eq!(s.state, "unknown");
    }

    #[test]
    fn a_truncated_reply_is_an_error_not_a_panic() {
        let full = Reply::new(0)
            .ints(VT_ENUM, "printer-state", &[3])
            .attr(0x42, "marker-names", &[b"Black"])
            .end();
        for cut in 0..full.len() {
            assert!(
                decode_printer_attributes(&full[..cut]).is_err(),
                "cut at {cut}"
            );
        }
        assert!(decode_printer_attributes(&full).is_ok());
    }

    #[test]
    fn operation_attributes_do_not_leak_into_the_printer_status() {
        let mut b = vec![0x02, 0x00, 0x00, 0x00, 0, 0, 0, 1, TAG_OPERATION];
        attribute(&mut b, VT_ENUM, "printer-state", &5i32.to_be_bytes());
        b.push(TAG_END);
        let s = decode_printer_attributes(&b).unwrap();
        assert_eq!(s.state, "unknown");
    }
}
