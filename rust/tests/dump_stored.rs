// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Dump exactly what the Rust core generates for a STORED picture and a STORED
//! animation (.eff), driven through the public FFI encoders. Run with:
//!   cargo test --test dump_stored -- --nocapture

use std::fs;
use std::path::PathBuf;

use liberated_bread_core::api::device_api::{
    encode_command, encode_set_playlist, encode_stored_animation, encode_stored_image,
};
use std::collections::HashMap;

const DDP_WRITE: &str = "01020074-1972-1925-3022-077119514e44";

fn spec_yaml() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate should have a parent repo dir")
        .join("vendor/protocol-specs/device-specs/devices/smartdawn-smart-lights.yaml");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join("")
}

/// Extract varint protobuf field 3 (the UploadRequest `size` field) from a
/// START packet body. The body follows the 8-byte transport header.
fn upload_request_size(start: &[u8]) -> Option<u64> {
    let body = &start[8..];
    let mut i = 0;
    while i < body.len() {
        let tag = body[i];
        i += 1;
        let field = tag >> 3;
        let wire = tag & 0x7;
        match wire {
            0 => {
                // varint value
                let mut val: u64 = 0;
                let mut shift = 0;
                loop {
                    let b = body[i];
                    i += 1;
                    val |= ((b & 0x7f) as u64) << shift;
                    if b & 0x80 == 0 {
                        break;
                    }
                    shift += 7;
                }
                if field == 3 {
                    return Some(val);
                }
            }
            2 => {
                let len = body[i] as usize;
                i += 1 + len;
            }
            _ => break,
        }
    }
    None
}

#[test]
fn dump_stored_picture_and_animation() {
    let yaml = spec_yaml();

    // ── Stored PICTURE: 2x2 solid red, cid 905000 ──
    let red_2x2: Vec<u8> = vec![255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0];
    let pic = encode_stored_image(
        yaml.clone(),
        2,
        2,
        red_2x2,
        "dumppic".to_string(),
        905000,
        5,
        "none".to_string(),
        0,
        0,
    )
    .expect("encode_stored_image should succeed");

    println!("\n===== STORED PICTURE (cid 905000) =====");
    println!("service_uuid: {}", pic.service_uuid);
    println!("cid: {}", pic.cid);
    println!("upload_writes count: {}", pic.upload_writes.len());
    println!(
        "container size (UploadRequest.size, field 3): {:?}",
        upload_request_size(&pic.upload_writes[0].bytes)
    );
    println!("START  (write 0) len={} hex={}", pic.upload_writes[0].bytes.len(), hex(&pic.upload_writes[0].bytes));
    if pic.upload_writes.len() > 1 {
        println!("DATA#1 (write 1) len={} hex={}", pic.upload_writes[1].bytes.len(), hex(&pic.upload_writes[1].bytes));
    }

    // ── Stored ANIMATION: 2x2 three frames red/green/blue, cid 905001, 500ms ──
    let red: Vec<u8> = vec![255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0];
    let green: Vec<u8> = vec![0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0];
    let blue: Vec<u8> = vec![0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255];
    let anim = encode_stored_animation(
        yaml.clone(),
        2,
        2,
        vec![red, green, blue],
        "dumpanim".to_string(),
        905001,
        500,
        0,
    )
    .expect("encode_stored_animation should succeed");

    println!("\n===== STORED ANIMATION (cid 905001, frameMs 500) =====");
    println!("service_uuid: {}", anim.service_uuid);
    println!("cid: {}", anim.cid);
    println!("upload_writes count: {}", anim.upload_writes.len());
    println!(
        "container size (UploadRequest.size, field 3): {:?}",
        upload_request_size(&anim.upload_writes[0].bytes)
    );
    println!("START  (write 0) len={} hex={}", anim.upload_writes[0].bytes.len(), hex(&anim.upload_writes[0].bytes));
    if anim.upload_writes.len() > 1 {
        println!("DATA#1 (write 1) len={} hex={}", anim.upload_writes[1].bytes.len(), hex(&anim.upload_writes[1].bytes));
    }

    // Reassemble the animation container from the DATA payloads (each DATA
    // packet after the 8-byte header is raw container bytes) to inspect the
    // DNMX header directly.
    let mut container = Vec::new();
    for w in anim.upload_writes.iter().skip(1) {
        container.extend_from_slice(&w.bytes[8..]);
    }
    println!("reassembled animation container len: {}", container.len());
    println!("container[0..64] hex: {}", hex(&container[0..64.min(container.len())]));
    println!("DNMX magic bytes[0..4]: {:?}", std::str::from_utf8(&container[0..4]));
    if container.len() >= 4096 + 4 {
        println!("block1 magic bytes[4096..4100]: {:?}", std::str::from_utf8(&container[4096..4100]));
    }
}

/// The DDP frame the encoder emits, minus the 4-byte fragment header. Layout of
/// the returned bytes: [frag:4][F0 04][sn:2][len:2][mt:2][ddp-header:12][pb...].
/// Returns (len_field, mt, ddp_header, payload_hex).
fn dissect(bytes: &[u8]) -> (u16, [u8; 2], Vec<u8>, String) {
    assert_eq!(bytes[4], 0xF0, "F0 04 marker after the 4-byte fragment header");
    assert_eq!(bytes[5], 0x04, "F0 04 marker after the 4-byte fragment header");
    let len = ((bytes[8] as u16) << 8) | bytes[9] as u16;
    let mt = [bytes[10], bytes[11]];
    let header = bytes[12..24].to_vec();
    let payload_hex = hex(&bytes[24..]);
    (len, mt, header, payload_hex)
}

/// GROUND-TRUTH DIFF against the four 2026-08 captures: the REAL vendored spec
/// must now put len=0 and a 12-byte all-zero DDP header on every command
/// (matching every vendor frame on handle 0x0013), and the set_playlist payload
/// must byte-match smartdawn_longer2.pcapng frame 5977.
#[test]
fn real_spec_matches_the_captures_byte_for_byte() {
    let yaml = spec_yaml();

    // --- set_playlist (M_BOOKMARK_SAVE): the 4-effect list from longer2 f.5977
    //     cids 14221..14218 at slots 8..5. ---
    let pl = encode_set_playlist(
        yaml.clone(),
        vec![14221, 14220, 14219, 14218],
        vec![8, 7, 6, 5],
        28,
    )
    .expect("encode_set_playlist");
    assert_eq!(pl.writes.len(), 1, "one M_BOOKMARK_SAVE write");
    let (len, mt, header, payload) = dissect(&pl.writes[0].bytes);
    assert_eq!(mt, [0x0A, 0x42], "mt = M_BOOKMARK_SAVE");
    assert_eq!(len, 0, "vendor sends len=0 (was packet_length)");
    assert_eq!(header, [0u8; 12], "vendor sends a 12-byte all-zero DDP header");
    assert_eq!(
        payload,
        "0800100422070800108d6f180822070800108c6f180722070800108b6f180622070800108a6f1805",
        "playlist payload byte-matches longer2 frame 5977"
    );

    // --- power_on (M_SET_POWERON): no-payload command, longer2 f.1516 wire is
    //     `...09 d2` + 12 zero bytes, len=0. ---
    let power = encode_command(
        Some(yaml.clone()),
        None,
        DDP_WRITE.to_string(),
        "power_on".to_string(),
        HashMap::from([("sn".to_string(), 26.0)]),
    )
    .expect("encode power_on");
    let (len, mt, header, payload) = dissect(&power);
    assert_eq!(mt, [0x09, 0xD2], "mt = M_SET_POWERON");
    assert_eq!(len, 0, "vendor sends len=0");
    assert_eq!(header, [0u8; 12], "all-zero DDP header");
    assert!(payload.is_empty(), "power_on carries no payload");

    // --- play_next (M_PLAY_NEXT): the loop kick, longer2 f.5995 all-zero. ---
    let pn = encode_command(
        Some(yaml),
        None,
        DDP_WRITE.to_string(),
        "play_next".to_string(),
        HashMap::from([("sn".to_string(), 29.0)]),
    )
    .expect("encode play_next");
    let (len, mt, header, payload) = dissect(&pn);
    assert_eq!(mt, [0x0A, 0x2C], "mt = M_PLAY_NEXT");
    assert_eq!(len, 0, "vendor sends len=0");
    assert_eq!(header, [0u8; 12], "all-zero DDP header");
    assert!(payload.is_empty(), "play_next carries no payload");
}
