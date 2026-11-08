// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use anyhow::Result;

use crate::protocol::ipl;

#[derive(Debug, Clone)]
pub struct ForeoActivationDto {
    pub security_access: Vec<u8>,
    pub activation_write: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct ForeoStatusDto {
    pub locked: bool,
    pub wakeup_enabled: bool,
}

pub fn foreo_activation(device_address: String) -> Result<ForeoActivationDto> {
    let mac = ipl::parse_ble_mac(&device_address)?;
    Ok(ForeoActivationDto {
        security_access: ipl::security_access(&mac),
        activation_write: ipl::activation_write(&mac),
    })
}

pub fn decode_foreo_status(activation: Vec<u8>, wakeup: Vec<u8>) -> Result<ForeoStatusDto> {
    let status = ipl::decode_foreo_status(&activation, &wakeup)?;
    Ok(ForeoStatusDto {
        locked: status.locked,
        wakeup_enabled: status.wakeup_enabled,
    })
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
        let status = decode_foreo_status(vec![0], vec![1]).unwrap();
        assert!(status.locked);
        assert!(status.wakeup_enabled);
        assert!(foreo_activation("123e4567-e89b-12d3-a456-426614174000".to_string()).is_err());
    }
}
