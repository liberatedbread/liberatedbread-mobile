// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

pub use crate::protocol::enphase::{EnphaseProofDto, XBeeFrameDto};

#[flutter_rust_bridge::frb]
pub fn enphase_client_ephemeral(
    private_key: Vec<u8>,
) -> Result<Vec<u8>, crate::error::ProtocolError> {
    crate::protocol::enphase::enphase_client_ephemeral(private_key)
}

#[flutter_rust_bridge::frb]
pub fn enphase_process_challenge(
    private_key: Vec<u8>,
    public_a: Vec<u8>,
    salt: Vec<u8>,
    public_b: Vec<u8>,
    username: String,
    password: String,
) -> Result<EnphaseProofDto, crate::error::ProtocolError> {
    crate::protocol::enphase::enphase_process_challenge(
        private_key,
        public_a,
        salt,
        public_b,
        username,
        password,
    )
}

#[flutter_rust_bridge::frb]
pub fn xbee_encode_frame(frame_type: u8, step: u8, payload: Vec<u8>) -> Vec<u8> {
    crate::protocol::enphase::xbee_encode_frame(frame_type, step, payload)
}

#[flutter_rust_bridge::frb]
pub fn xbee_decode_frame(bytes: Vec<u8>) -> Result<XBeeFrameDto, crate::error::ProtocolError> {
    crate::protocol::enphase::xbee_decode_frame(bytes)
}

#[flutter_rust_bridge::frb]
pub fn enphase_apply_cipher(
    key: Vec<u8>,
    nonce: Vec<u8>,
    offset: u64,
    data: Vec<u8>,
) -> Result<Vec<u8>, crate::error::ProtocolError> {
    crate::protocol::enphase::enphase_apply_cipher(key, nonce, offset, data)
}
