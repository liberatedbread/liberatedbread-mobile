// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end test of the Rabbit Air BLE transport through the same FFI the
//! app calls: payload framing and chunking, reply length announcement,
//! cleartext setup envelopes, and user-key generation. The sibling of
//! `rabbit_air_control.rs` for the BLE provisioning path — the payload a UDP
//! datagram would carry, re-framed for the GATT command characteristic.

use liberated_bread_core::api::device_api::{
    rabbit_air_ble_command_characteristic_uuid, rabbit_air_ble_expected_payload_len,
    rabbit_air_ble_frame, rabbit_air_ble_mtu, rabbit_air_ble_service_uuid,
    rabbit_air_decrypt_datagram, rabbit_air_encrypt_datagram, rabbit_air_generate_user_key,
    render_rabbit_air_setup_envelope,
};
use liberated_bread_core::protocol::rabbit_air_ble::{
    CHUNK_OVERHEAD, DEFAULT_CHUNK_SIZE, NEGOTIATED_CHUNK_SIZE,
};

/// The vendored spec, read the way `roomba_control.rs` reads its own: the
/// numbers below are the spec's, not this file's, so a spec correction shows
/// up here as a failure instead of drifting silently past a literal.
const SPEC: &str = include_str!("specs/rabbit-air-purifier.yaml");

/// The `ble_provisioning` setup method's block — where the spec records the
/// GATT identity and timings this transport is built from.
fn ble_provisioning() -> serde_yaml::Value {
    let spec: serde_yaml::Value = serde_yaml::from_str(SPEC).expect("the fixture parses");
    spec["device"]["setup"]["methods"]
        .as_sequence()
        .expect("the spec declares setup methods")
        .iter()
        .find(|m| m["type"].as_str() == Some("ble_provisioning"))
        .expect("the spec declares the BLE provisioning method")
        .clone()
}

/// The chunk size the spec's own timing block prescribes, used everywhere
/// below in place of a bare 510.
fn spec_chunk_size() -> u32 {
    ble_provisioning()["timing"]["chunk_size"]
        .as_u64()
        .expect("the spec states a chunk size") as u32
}

/// The example key from the spec's exchange documentation (a documentation
/// value, not a real device credential).
const KEY_HEX: &str = "0123456789abcdeffedcba9876543210";

/// Reassemble a reply as the Dart accumulator will: the expected length from
/// the first chunk's prefix, then bodies with only that prefix skipped.
fn reassemble(chunks: &[Vec<u8>]) -> Vec<u8> {
    let expected = rabbit_air_ble_expected_payload_len(chunks[0].clone())
        .expect("first chunk announces") as usize;
    let mut buffered = Vec::new();
    for (i, chunk) in chunks.iter().enumerate() {
        buffered.extend_from_slice(if i == 0 { &chunk[2..] } else { chunk });
    }
    assert_eq!(buffered.len(), expected, "the prefix counted the payload");
    buffered
}

/// The transport's constants are the SPEC's, and this is what says so.
///
/// Asserting the literals here proved nothing — the same two strings written
/// twice, so a spec correction (a mistranscribed UUID, an MTU the next
/// firmware moves) would land upstream and leave the crate quietly speaking
/// the old protocol with a green suite. Read them out of the fixture instead,
/// the way `roomba_control.rs` reads its example bodies.
#[test]
fn the_gatt_constants_are_the_ones_the_spec_declares() {
    let method = ble_provisioning();
    let ble = &method["ble"];
    assert_eq!(
        rabbit_air_ble_service_uuid(),
        ble["service_uuid"].as_str().expect("a service uuid")
    );
    // One characteristic serves both legs — write requests out, indications
    // back — which is why the crate keeps a single constant for it.
    let write = ble["write_characteristic"].as_str().expect("a write char");
    let read = ble["read_characteristic"].as_str().expect("a read char");
    assert_eq!(write, read, "the spec's single command characteristic");
    assert_eq!(rabbit_air_ble_command_characteristic_uuid(), write);

    let timing = &method["timing"];
    assert_eq!(
        u64::from(rabbit_air_ble_mtu()),
        timing["mtu"].as_u64().expect("a negotiated MTU")
    );
    // The chunk size is not an independent number: the spec states both the
    // answer and the rule that produces it, so pinning the answer against the
    // spec and the rule against the answer pins `CHUNK_OVERHEAD` too — 515 -
    // 510 leaves it no room to be anything but 5.
    assert_eq!(
        NEGOTIATED_CHUNK_SIZE as u64,
        timing["chunk_size"].as_u64().expect("a chunk size")
    );
    assert_eq!(
        NEGOTIATED_CHUNK_SIZE,
        rabbit_air_ble_mtu() as usize - CHUNK_OVERHEAD
    );
    // The pre-negotiation default lives only in the rule's prose.
    let rule = timing["chunk_size_rule"]
        .as_str()
        .expect("the rule in prose");
    assert!(
        rule.contains(&DEFAULT_CHUNK_SIZE.to_string()),
        "the pre-negotiation default must be the spec's: {rule}"
    );
}

#[test]
fn a_short_message_is_a_single_prefixed_chunk() {
    let payload = b"{\"id\":0,\"cmd\":0}";
    let chunks = rabbit_air_ble_frame(payload.to_vec(), spec_chunk_size()).expect("frames");
    assert_eq!(chunks.len(), 1);
    assert_eq!(chunks[0][0], payload.len() as u8, "little-endian LSB");
    assert_eq!(chunks[0][1], 0, "little-endian MSB");
    assert_eq!(
        &chunks[0][2..],
        payload,
        "the prefix counts the payload only"
    );
    assert_eq!(reassemble(&chunks), payload);
}

#[test]
fn a_multi_chunk_message_crossing_the_negotiated_boundary_round_trips() {
    let chunk = spec_chunk_size() as usize;
    // Long enough to need three chunks at the spec's size, whatever it is.
    let payload: Vec<u8> = (0..(2 * chunk + 1) as u32)
        .map(|i| (i % 251) as u8)
        .collect();
    let framed = payload.len() + 2;
    let chunks = rabbit_air_ble_frame(payload.clone(), chunk as u32).expect("frames");
    assert_eq!(
        chunks.len(),
        3,
        "{framed} framed bytes at {chunk}-byte chunks"
    );
    assert_eq!(chunks[0].len(), chunk);
    assert_eq!(chunks[1].len(), chunk);
    assert_eq!(chunks[2].len(), framed - 2 * chunk);
    assert_eq!(reassemble(&chunks), payload);
}

#[test]
fn the_expected_length_ignores_sub_prefix_notifications() {
    assert_eq!(rabbit_air_ble_expected_payload_len(vec![]), None);
    assert_eq!(rabbit_air_ble_expected_payload_len(vec![0x2C]), None);
    assert_eq!(
        rabbit_air_ble_expected_payload_len(vec![0x2C, 0x01]),
        Some(300)
    );
    assert_eq!(
        rabbit_air_ble_expected_payload_len(vec![0x2C, 0x01, 0xAA, 0xBB]),
        Some(300),
        "only the prefix counts"
    );
}

#[test]
fn a_too_small_chunk_size_is_an_error_not_a_panic() {
    for size in [0, 1, 2] {
        assert!(
            rabbit_air_ble_frame(vec![1, 2], size).is_err(),
            "chunk_size {size}"
        );
    }
}

#[test]
fn setup_envelopes_render_cleartext_without_a_ts() {
    assert_eq!(
        render_rabbit_air_setup_envelope(0, 0, None).expect("read_network_settings"),
        r#"{"id":0,"cmd":0}"#
    );
    assert_eq!(
        render_rabbit_air_setup_envelope(1, 7, None).expect("get_current_mode"),
        r#"{"id":1,"cmd":7}"#
    );
    let join = render_rabbit_air_setup_envelope(
        2,
        1,
        Some(r#"{"ssid":"Cottage","passphrase":"hunter2","security":3}"#.to_string()),
    )
    .expect("join_network");
    assert_eq!(
        join,
        r#"{"id":2,"cmd":1,"data":{"ssid":"Cottage","passphrase":"hunter2","security":3}}"#
    );
    assert!(!join.contains("\"ts\""), "setup envelopes carry no ts");
    // Non-object data is rejected at the edge.
    assert!(render_rabbit_air_setup_envelope(3, 5, Some("[1]".to_string())).is_err());
    assert!(render_rabbit_air_setup_envelope(3, 5, Some("nope".to_string())).is_err());
}

#[test]
fn a_generated_user_key_feeds_the_datagram_crypto() {
    let key = rabbit_air_generate_user_key();
    assert_eq!(key.len(), 32);
    assert!(
        key.chars()
            .all(|c| c.is_ascii_digit() || ('A'..='F').contains(&c)),
        "32 uppercase hex chars: {key}"
    );
    assert_ne!(
        rabbit_air_generate_user_key(),
        key,
        "fresh randomness each call"
    );

    // The pushed key encrypts exactly as the documented one does: a framed
    // encrypted envelope reassembles and decrypts back to its plaintext.
    let plaintext = r#"{"id":1234568,"cmd":4,"ts":1700000123}"#;
    for key in [key, KEY_HEX.to_string()] {
        let datagram = rabbit_air_encrypt_datagram(key.clone(), plaintext.to_string())
            .expect("encrypts under the key");
        let chunks = rabbit_air_ble_frame(datagram, spec_chunk_size()).expect("frames");
        let reassembled = reassemble(&chunks);
        assert_eq!(
            rabbit_air_decrypt_datagram(key, reassembled).expect("decrypts"),
            plaintext
        );
    }
}
