// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use anyhow::{bail, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ForeoStatus {
    pub locked: bool,
    pub wakeup_enabled: bool,
}

pub fn parse_ble_mac(address: &str) -> Result<[u8; 6]> {
    let normalized = address.trim().replace('-', ":");
    let parts = normalized.split(':').collect::<Vec<_>>();
    if parts.len() != 6
        || parts
            .iter()
            .any(|part| part.len() != 2 || !part.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        bail!("a six-byte BLE MAC address is required");
    }
    let mut mac = [0_u8; 6];
    for (index, part) in parts.iter().enumerate() {
        mac[index] = u8::from_str_radix(part, 16)?;
    }
    if mac == [0; 6] || mac == [0xFF; 6] || mac[0] & 1 != 0 {
        bail!("a unicast device BLE MAC address is required");
    }
    Ok(mac)
}

pub fn security_access(mac: &[u8; 6]) -> Vec<u8> {
    vec![0x01, 0xA1, mac[3], mac[4], mac[5]]
}

pub fn activation_write(mac: &[u8; 6]) -> Vec<u8> {
    let b = [mac[5], mac[4], mac[3], 0, 0, mac[2], mac[1], mac[0]];
    let chip_id = [
        (b[2] & 0x0F) | (b[7] & 0xF0),
        (b[5] & 0x0F) | (b[1] & 0xF0),
        (b[7] & 0x0F).wrapping_add(0xF0_u8.wrapping_sub(b[6] & 0xF0)),
        0xFF_u8.wrapping_sub(b[6]),
        b[5].wrapping_add(1),
        (b[1] & 0x0F).wrapping_add(0xF0_u8.wrapping_sub(b[2] & 0xF0)),
        (b[0] & 0x0F) | (b[5] & 0xF0),
        (b[6] & 0x0F) | (b[0] & 0xF0),
    ];
    [&[0x01, 0x02], chip_id.as_slice()].concat()
}

pub fn decode_foreo_status(activation: &[u8], wakeup: &[u8]) -> Result<ForeoStatus> {
    let Some(activation) = activation.first() else {
        bail!("activation status was empty");
    };
    let Some(wakeup) = wakeup.first() else {
        bail!("wake-up status was empty");
    };
    Ok(ForeoStatus {
        locked: *activation == 0,
        wakeup_enabled: *wakeup == 1,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activation_matches_the_documented_vector() {
        let mac = parse_ble_mac("AA:BB:CC:DD:EE:FF").unwrap();
        assert_eq!(security_access(&mac), [0x01, 0xA1, 0xDD, 0xEE, 0xFF]);
        assert_eq!(
            activation_write(&mac),
            [0x01, 0x02, 0xAD, 0xEC, 0x4A, 0x44, 0xCD, 0x2E, 0xCF, 0xFB]
        );
    }

    #[test]
    fn accepts_lowercase_and_hyphenated_addresses() {
        let mac = parse_ble_mac("aa-bb-cc-dd-ee-ff").unwrap();
        assert_eq!(mac, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
    }

    #[test]
    fn rejects_non_mac_and_non_unicast_identifiers() {
        for invalid in [
            "not-a-mac",
            "123e4567-e89b-12d3-a456-426614174000",
            "00:00:00:00:00:00",
            "ff:ff:ff:ff:ff:ff",
            "01:11:22:33:44:55",
            "aa:bb:cc:dd:ee",
        ] {
            assert!(parse_ble_mac(invalid).is_err(), "accepted {invalid}");
        }
    }

    #[test]
    fn decodes_lock_and_wakeup_without_guessing_empty_values() {
        assert_eq!(
            decode_foreo_status(&[0], &[0]).unwrap(),
            ForeoStatus {
                locked: true,
                wakeup_enabled: false,
            }
        );
        assert_eq!(
            decode_foreo_status(&[1], &[1]).unwrap(),
            ForeoStatus {
                locked: false,
                wakeup_enabled: true,
            }
        );
        assert!(decode_foreo_status(&[], &[1]).is_err());
        assert!(decode_foreo_status(&[1], &[]).is_err());
    }
}
