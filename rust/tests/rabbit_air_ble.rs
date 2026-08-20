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

#[test]
fn the_gatt_constants_are_the_vendor_apps() {
    assert_eq!(
        rabbit_air_ble_service_uuid(),
        "366048ae-9f36-43cf-8004-010c0c9fa52e"
    );
    assert_eq!(
        rabbit_air_ble_command_characteristic_uuid(),
        "53ef7d7d-c244-42bd-9064-a1569a521ca9"
    );
    assert_eq!(rabbit_air_ble_mtu(), 515);
}

#[test]
fn a_short_message_is_a_single_prefixed_chunk() {
    let payload = b"{\"id\":0,\"cmd\":0}";
    let chunks = rabbit_air_ble_frame(payload.to_vec(), 510).expect("frames");
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
    let payload: Vec<u8> = (0..1200u32).map(|i| (i % 251) as u8).collect();
    let chunks = rabbit_air_ble_frame(payload.clone(), 510).expect("frames");
    assert_eq!(chunks.len(), 3, "1202 framed bytes at 510-byte chunks");
    assert_eq!(chunks[0].len(), 510);
    assert_eq!(chunks[1].len(), 510);
    assert_eq!(chunks[2].len(), 1202 - 2 * 510);
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
        let chunks = rabbit_air_ble_frame(datagram, 510).expect("frames");
        let reassembled = reassemble(&chunks);
        assert_eq!(
            rabbit_air_decrypt_datagram(key, reassembled).expect("decrypts"),
            plaintext
        );
    }
}
