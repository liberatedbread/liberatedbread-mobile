// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

pub mod daniao;
pub mod daniao_store;
pub mod daniao_upload;
pub mod dispatch;
pub mod generic;
pub mod http;
pub mod idotmatrix;
pub mod image_upload;
pub mod kasa;
pub mod lifx;
pub mod profiles;
pub mod rabbit_air;
pub mod rabbit_air_ble;
pub mod roomba;
pub mod soap;
pub mod stored_upload;
pub mod traits;
pub mod tuya;
pub mod wemo_setup;

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
/// `protocol_handler` resolves to. Each write names its own characteristic
/// (from the spec), and the GATT service those characteristics belong to is
/// resolved from the spec too, via [`service_for_characteristic`] — a handler
/// carries no UUIDs of its own, so pointing it at a sibling device is a spec
/// edit, not a code change.
pub struct ImageUploadHandler {
    pub name: &'static str,
    pub encode: FrameEncoder,
}

/// Every implemented image-upload handler. The single source of truth for
/// both the DTO's `encodable` flag and `encode_image_frame`'s dispatch, so a
/// handler cannot be half-registered (advertised but not encodable, or
/// encodable but hidden).
const IMAGE_UPLOAD_HANDLERS: &[ImageUploadHandler] = &[
    ImageUploadHandler {
        name: daniao::HANDLER_NAME,
        encode: daniao::encode_doodle_frame,
    },
    ImageUploadHandler {
        name: idotmatrix::HANDLER_NAME,
        encode: idotmatrix::encode_framed_upload,
    },
];

/// Look up the implemented handler for a spec's `protocol_handler` name.
pub fn image_upload_handler(name: &str) -> Option<&'static ImageUploadHandler> {
    IMAGE_UPLOAD_HANDLERS.iter().find(|h| h.name == name)
}

/// The UUID of the service that declares `char_uuid` — the GATT service a
/// caller must open to reach a write an encoder produced. Resolved from the
/// spec rather than pinned per handler: which service carries a
/// characteristic is the spec's fact, and a handler that hardcoded it could
/// not drive a sibling device on a different service without a code change.
pub fn service_for_characteristic(spec: &DeviceSpec, char_uuid: &str) -> Option<String> {
    for service in &spec.services {
        if service
            .characteristics
            .iter()
            .any(|c| c.uuid.eq_ignore_ascii_case(char_uuid))
        {
            return Some(service.uuid.clone());
        }
    }
    None
}

/// Whether this build can encode the persisted container a spec's
/// `stored_upload.container_format` names — the storage counterpart to
/// [`image_upload_handler`], read by the DTO's `encodable` flag and the encode
/// path alike so a format cannot be advertised without an encoder behind it.
pub fn stored_container_encodable(container_format: &str) -> bool {
    stored_upload::container_encoder(container_format).is_some()
}
