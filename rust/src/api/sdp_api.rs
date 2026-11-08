// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

#[flutter_rust_bridge::frb]
pub fn spp_sdp_request(transaction_id: u16) -> Vec<u8> {
    crate::protocol::sdp::spp_search_attribute_request(transaction_id)
}

#[flutter_rust_bridge::frb]
pub fn spp_rfcomm_channel_from_sdp_response(
    response: Vec<u8>,
) -> Result<Option<u8>, crate::error::ProtocolError> {
    crate::protocol::sdp::rfcomm_channel_from_sdp_response(&response)
}
