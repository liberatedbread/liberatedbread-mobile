// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

pub mod daniao;
pub mod dispatch;
pub mod generic;
pub mod profiles;
pub mod traits;

use crate::error::ProtocolError;

/// One image frame encoded for the wire, plus how many logical packets — and
/// therefore sequence numbers — it consumed. Callers advance their frame
/// index by [`Self::packets`], not by 1: a frame that splits into P packets
/// uses P serials, and advancing by less would make the next frame reuse
/// them, corrupting fragment reassembly on the device.
#[derive(Debug)]
pub struct EncodedFrame {
    pub writes: Vec<Vec<u8>>,
    pub packets: u32,
}

/// Signature every image-frame encoder implements:
/// `(rgb, width, height, frame_index, max_payload_per_write)` — see
/// [`daniao::encode_display_frame`] for the contract.
pub type FrameEncoder = fn(&[u8], u32, u32, u32, usize) -> Result<EncodedFrame, ProtocolError>;

/// A named image-upload encoder — the registry entry a spec's
/// `protocol_handler` resolves to.
pub struct ImageUploadHandler {
    pub name: &'static str,
    /// GATT service/characteristic the encoded writes target.
    pub service_uuid: &'static str,
    pub characteristic_uuid: &'static str,
    pub encode: FrameEncoder,
}

/// Every implemented image-upload handler. The single source of truth for
/// both the DTO's `encodable` flag and `encode_image_frame`'s dispatch, so a
/// handler cannot be half-registered (advertised but not encodable, or
/// encodable but hidden).
const IMAGE_UPLOAD_HANDLERS: &[ImageUploadHandler] = &[ImageUploadHandler {
    name: daniao::HANDLER_NAME,
    service_uuid: daniao::SERVICE_UUID,
    characteristic_uuid: daniao::DDP_WRITE_UUID,
    encode: daniao::encode_display_frame,
}];

/// Look up the implemented handler for a spec's `protocol_handler` name.
pub fn image_upload_handler(name: &str) -> Option<&'static ImageUploadHandler> {
    IMAGE_UPLOAD_HANDLERS.iter().find(|h| h.name == name)
}
