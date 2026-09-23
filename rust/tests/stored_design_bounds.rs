// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The stored-design FFI encoders refuse a canvas the device's "DN" container
//! cannot describe.
//!
//! `daniao_store` writes each layer's width, height and (for text) row stride
//! into ONE BYTE of the layer header, narrowing with `as u8`, and nothing
//! before the FFI boundary bounded the canvas: the UI rasterises a marquee at
//! the text's full run. A layer past the limit went out with a wrapped byte,
//! the upload committed, the app said "saved", and the panel played noise.
//! Driven through the public encoders against the vendored SmartDawn spec —
//! the one real `stored_upload` device — so the check is exercised exactly
//! where Dart calls it, and the limits are read from `daniao_store` so this
//! file cannot pin a number the container disagrees with.

use std::fs;
use std::path::PathBuf;

use liberated_bread_core::api::device_api::{
    decode_stored_upload_event, decode_stored_upload_events, encode_stored_image,
    encode_stored_text,
};
use liberated_bread_core::protocol::daniao_store::{MAX_LAYER_DIM, MAX_TEXT_WIDTH};

fn spec_yaml() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate should have a parent repo dir")
        .join("vendor/protocol-specs/device-specs/devices/smartdawn-smart-lights.yaml");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// A marquee bitmap: every pixel lit, `width * height` bytes.
fn text(width: u32, height: u32) -> Result<(), String> {
    encode_stored_text(
        spec_yaml(),
        None,
        width,
        height,
        vec![1; (width * height) as usize],
        "marquee".to_string(),
        905001,
        5,
        "left".to_string(),
        3,
        0,
    )
    .map(|_| ())
    .map_err(|e| e.to_string())
}

/// A solid red canvas, `width * height * 3` bytes.
fn image(width: u32, height: u32) -> Result<(), String> {
    let rgb: Vec<u8> = [255, 0, 0].repeat((width * height) as usize);
    encode_stored_image(
        spec_yaml(),
        None,
        width,
        height,
        rgb,
        "picture".to_string(),
        905002,
        5,
        "none".to_string(),
        0,
        0,
    )
    .map(|_| ())
    .map_err(|e| e.to_string())
}

/// The everyday marquee — a sentence, wider than 255 px — must still store:
/// the text layer's width limit is its stride byte, not its width byte.
#[test]
fn a_sentence_wide_marquee_is_accepted() {
    text(300, 20).expect("300 px is an ordinary marquee and fits the stride byte");
    text(MAX_TEXT_WIDTH, 20).expect("the widest stride the header can say");
}

#[test]
fn a_marquee_wider_than_the_stride_byte_is_refused_with_the_limit_named() {
    let err = text(MAX_TEXT_WIDTH + 1, 20).expect_err("one past the stride byte");
    assert!(
        err.contains(&MAX_TEXT_WIDTH.to_string()),
        "the error must name the limit so the UI can act on it: {err}"
    );
    assert!(
        err.contains("text"),
        "the error must say which layer: {err}"
    );
}

#[test]
fn a_marquee_taller_than_a_byte_is_refused() {
    text(20, MAX_LAYER_DIM).expect("the tallest the header can say");
    text(20, MAX_LAYER_DIM + 1).expect_err("height is a single header byte");
}

#[test]
fn a_picture_wider_or_taller_than_a_byte_is_refused() {
    let err = image(MAX_LAYER_DIM + 1, 20).expect_err("a 256 px picture cannot be described");
    assert!(
        err.contains("image"),
        "the error must say which layer: {err}"
    );
    assert!(
        err.contains(&MAX_LAYER_DIM.to_string()),
        "the error must name the limit: {err}"
    );
    image(20, MAX_LAYER_DIM + 1).expect_err("height rides the same one-byte header field");
}

#[test]
fn a_picture_at_the_byte_limit_is_accepted() {
    image(MAX_LAYER_DIM, MAX_LAYER_DIM).expect("the largest picture the header can say");
}

/// The dimension check runs before the spec is consulted, so its message is
/// the same whatever spec Dart hands over — but it must never mask a real
/// canvas error: a bitmap that does not match its stated size is still the
/// container builder's typed error, not a panic and not a limit message.
#[test]
fn a_mismatched_bitmap_inside_the_limit_is_still_a_typed_error() {
    let err = encode_stored_text(
        spec_yaml(),
        None,
        10,
        10,
        vec![1; 99],
        "short".to_string(),
        905003,
        5,
        "left".to_string(),
        3,
        0,
    )
    .expect_err("99 bytes are not a 10x10 bitmap")
    .to_string();
    assert!(
        !err.contains("at most"),
        "not a dimension-limit error: {err}"
    );
}

/// The other unbounded input at this boundary: the design's NAME.
///
/// The "DN" header holds the TinyProgram protobuf between offset 10 and the
/// base AMX at 256, and the name is embedded TWICE (as `name` and as
/// `description`), so every byte costs two of that 246-byte budget. Past it,
/// the AMX copy used to overwrite the protobuf's tail and the header CRC
/// sealed the damage — a container the device refuses without saying why,
/// after an upload the app reported as saved. `daniao_store` refuses it, and
/// this is that refusal seen from where Dart calls it: the name is the only
/// thing the message needs to name, and `MAX_NAME_BYTES` is read from the
/// container so the file cannot pin a number the builder disagrees with.
#[test]
fn a_stored_name_the_header_cannot_hold_is_refused_at_the_ffi() {
    use liberated_bread_core::protocol::daniao_store::MAX_NAME_BYTES;

    let store = |name: String| -> Result<(), String> {
        encode_stored_image(
            spec_yaml(),
            None,
            2,
            2,
            [255, 0, 0].repeat(4),
            name,
            905003,
            5,
            "none".to_string(),
            0,
            0,
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    };

    store("n".repeat(MAX_NAME_BYTES)).expect("the advertised limit must actually store");
    let err = store("n".repeat(MAX_NAME_BYTES + 100))
        .expect_err("a name past the header budget must not encode");
    assert!(
        err.contains("name") && err.contains(&MAX_NAME_BYTES.to_string()),
        "the refusal must name the input and its limit: {err}"
    );
    // And a name past the whole buffer is an error too, not a slice panic
    // crossing the FFI as a PanicException.
    assert!(store("n".repeat(5000)).is_err());
}

/// An M_UPLOAD_COMPLETE the device sends, as a 23-byte MTU delivers it: two
/// notifications behind [serial][total][remaining][tag] headers, 16 DNX bytes
/// each. The SimpleMessage (i1 = 0, i3 = 0: success) lands entirely in the
/// second.
fn fragmented_upload_complete() -> Vec<Vec<u8>> {
    let mut dnx = vec![0xF1, 0x01, 0x00, 0x07, 0x00, 0x00, 0x0B, 0x76]; // mt 2934
    dnx.extend_from_slice(&[0; 12]); // up to DNX offset 20
    dnx.extend_from_slice(&[0x08, 0x00, 0x18, 0x00]); // SimpleMessage
    let chunks: Vec<&[u8]> = dnx.chunks(16).collect();
    let total = chunks.len() as u8;
    assert_eq!(total, 2, "the fixture must actually fragment");
    chunks
        .iter()
        .enumerate()
        .map(|(i, chunk)| {
            let mut frag = vec![0x21, total, total - 1 - i as u8, 0x00];
            frag.extend_from_slice(chunk);
            frag
        })
        .collect()
}

#[test]
fn a_fragmented_upload_complete_is_decoded_from_the_window() {
    let fragments = fragmented_upload_complete();
    // One notification at a time — what the app used to do — sees nothing:
    // the first fragment stops short of the SimpleMessage.
    assert!(
        decode_stored_upload_event(spec_yaml(), fragments[0].clone())
            .unwrap()
            .is_none(),
        "a first fragment is not a verdict"
    );
    // The window reassembles first.
    let events = decode_stored_upload_events(spec_yaml(), fragments.clone()).unwrap();
    assert_eq!(events.len(), 1);
    assert!(matches!(
        events[0].kind,
        liberated_bread_core::api::device_api::StoredUploadEventKind::Complete
    ));
    // And a window with only the first fragment is still nothing.
    let events = decode_stored_upload_events(spec_yaml(), vec![fragments[0].clone()]).unwrap();
    assert!(events.is_empty());
}

#[test]
fn a_write_budget_below_the_start_packet_is_refused_up_front() {
    // 20 bytes: what Dart falls back to when the MTU read fails. The START
    // packet alone is header + protobuf, well past it; the save used to die on
    // that first write instead of saying why.
    let err = encode_stored_text(
        spec_yaml(),
        Some(20),
        16,
        8,
        vec![1; 16 * 8],
        "marquee".to_string(),
        905001,
        5,
        "left".to_string(),
        3,
        0,
    )
    .expect_err("a 20-byte budget cannot carry the START packet");
    let text = err.to_string();
    assert!(text.contains("START packet"), "{text}");
    assert!(text.contains("MTU"), "{text}");
    // A budget the START packet fits is the normal path.
    assert!(encode_stored_text(
        spec_yaml(),
        Some(100),
        16,
        8,
        vec![1; 16 * 8],
        "marquee".to_string(),
        905001,
        5,
        "left".to_string(),
        3,
        0,
    )
    .is_ok());
}
