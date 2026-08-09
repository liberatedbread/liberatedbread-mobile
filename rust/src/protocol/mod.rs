// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

pub mod daniao;
pub mod daniao_upload;
pub mod dispatch;
pub mod generic;
pub mod profiles;
pub mod traits;

use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;

/// One ordered BLE write of an encoded frame: the payload and the
/// characteristic it targets. Per-write targets exist because a protocol can
/// span channels — Daniao's doodle flow opens the session on the command
/// characteristic and streams pixels on the bulk one.
#[derive(Debug)]
pub struct EncodedWrite {
    pub characteristic_uuid: String,
    pub bytes: Vec<u8>,
}

/// One image frame encoded for the wire, plus how many logical packets — and
/// therefore sequence numbers — it consumed. Callers advance their frame
/// index by [`Self::packets`], not by 1: a frame that splits into P packets
/// uses P serials, and advancing by less would make the next frame reuse
/// them, corrupting fragment reassembly on the device.
#[derive(Debug)]
pub struct EncodedFrame {
    pub writes: Vec<EncodedWrite>,
    pub packets: u32,
}

/// Signature every image-frame encoder implements:
/// `(spec, rgb, width, height, frame_index, max_payload_per_write)`. The spec
/// is passed so the encoder resolves message types, framing, and target
/// characteristics from the YAML rather than hardcoding them — see
/// [`daniao::encode_doodle_frame`] for the contract.
pub type FrameEncoder =
    fn(&DeviceSpec, &[u8], u32, u32, u32, usize) -> Result<EncodedFrame, ProtocolError>;

/// A named image-upload encoder — the registry entry a spec's
/// `protocol_handler` resolves to. The GATT service is fixed platform
/// identity; each write names its own characteristic (from the spec).
pub struct ImageUploadHandler {
    pub name: &'static str,
    pub service_uuid: &'static str,
    pub encode: FrameEncoder,
}

/// Every implemented image-upload handler. The single source of truth for
/// both the DTO's `encodable` flag and `encode_image_frame`'s dispatch, so a
/// handler cannot be half-registered (advertised but not encodable, or
/// encodable but hidden).
const IMAGE_UPLOAD_HANDLERS: &[ImageUploadHandler] = &[ImageUploadHandler {
    name: daniao::HANDLER_NAME,
    service_uuid: daniao::SERVICE_UUID,
    encode: daniao::encode_doodle_frame,
}];

/// Look up the implemented handler for a spec's `protocol_handler` name.
pub fn image_upload_handler(name: &str) -> Option<&'static ImageUploadHandler> {
    IMAGE_UPLOAD_HANDLERS.iter().find(|h| h.name == name)
}
