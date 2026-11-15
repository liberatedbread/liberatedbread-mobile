// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use anyhow::Result;

use crate::protocol::ipl;

#[derive(Debug, Clone)]
pub struct ForeoActivationDto {
    pub security_access: Vec<u8>,
    pub activation_write: Vec<u8>,
    /// Written to 0A30 on firmware that exposes it.
    pub wakeup_write: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct ForeoStatusDto {
    pub locked: bool,
    /// `None` when the unit has no 0A30 wake-up characteristic.
    pub wakeup_enabled: Option<bool>,
}

pub fn foreo_activation(device_address: String) -> Result<ForeoActivationDto> {
    let mac = ipl::parse_ble_mac(&device_address)?;
    Ok(ForeoActivationDto {
        security_access: ipl::security_access(&mac),
        activation_write: ipl::activation_write(&mac),
        wakeup_write: ipl::FOREO_WAKEUP_WRITE.to_vec(),
    })
}

/// `wakeup` is `None` when the unit exposes no 0A30 characteristic.
pub fn decode_foreo_status(activation: Vec<u8>, wakeup: Option<Vec<u8>>) -> Result<ForeoStatusDto> {
    let status = ipl::decode_foreo_status(&activation, wakeup.as_deref())?;
    Ok(ForeoStatusDto {
        locked: status.locked,
        wakeup_enabled: status.wakeup_enabled,
    })
}

/// Whether this unit gets the Basic/Pro switch, from its 2A28 SW revision.
#[flutter_rust_bridge::frb(sync)]
pub fn foreo_pro_mode_supported(sw_revision: String) -> bool {
    ipl::foreo_pro_mode_supported(&sw_revision)
}

/// An all-FF (or empty) FFF1 read-back: the device was busy, retry.
#[flutter_rust_bridge::frb(sync)]
pub fn foreo_reply_busy(reply: Vec<u8>) -> bool {
    ipl::foreo_reply_busy(&reply)
}

/// An FFF1 read-back acknowledging a settings write (leading 01).
#[flutter_rust_bridge::frb(sync)]
pub fn foreo_write_acknowledged(reply: Vec<u8>) -> bool {
    ipl::foreo_write_acknowledged(&reply)
}

/// The 0BD0 read-back as Pro (`true`) or Basic (`false`).
pub fn decode_foreo_removal_mode(reply: Vec<u8>) -> Result<bool> {
    ipl::decode_foreo_removal_mode(&reply)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_the_documented_activation_bytes() {
        let activation = foreo_activation("AA:BB:CC:DD:EE:FF".to_string()).unwrap();
        assert_eq!(activation.security_access, [0x01, 0xA1, 0xDD, 0xEE, 0xFF]);
        assert_eq!(
            activation.activation_write,
            [0x01, 0x02, 0xAD, 0xEC, 0x4A, 0x44, 0xCD, 0x2E, 0xCF, 0xFB]
        );
    }

    #[test]
    fn maps_the_status_and_rejects_platform_uuid_identifiers() {
        let status = decode_foreo_status(vec![0], Some(vec![1])).unwrap();
        assert!(status.locked);
        assert_eq!(status.wakeup_enabled, Some(true));
        assert_eq!(
            decode_foreo_status(vec![1], None).unwrap().wakeup_enabled,
            None
        );
        assert!(foreo_activation("123e4567-e89b-12d3-a456-426614174000".to_string()).is_err());
    }
}
