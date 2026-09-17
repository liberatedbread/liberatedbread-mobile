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

use liberated_bread_core::api::device_api::{encode_stored_image, encode_stored_text};
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
