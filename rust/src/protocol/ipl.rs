// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use anyhow::{bail, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ForeoStatus {
    pub locked: bool,
    /// `None` when the firmware has no 0A30 wake-up characteristic, as on the
    /// captured new-dialect PEACH2: there is nothing to enable there.
    pub wakeup_enabled: Option<bool>,
}

/// The wake-up enable written to 0A30, on firmware that exposes it.
pub const FOREO_WAKEUP_WRITE: [u8; 1] = [0x01];

/// The first removal-mode byte (0BD0 read-back) that means Pro.
const FOREO_PRO_MODE_MIN: u8 = 0x06;

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

pub fn decode_foreo_status(activation: &[u8], wakeup: Option<&[u8]>) -> Result<ForeoStatus> {
    let Some(activation) = activation.first() else {
        bail!("activation status was empty");
    };
    let wakeup_enabled = match wakeup {
        None => None,
        Some(wakeup) => match wakeup.first() {
            Some(byte) => Some(*byte == 1),
            None => bail!("wake-up status was empty"),
        },
    };
    Ok(ForeoStatus {
        locked: *activation == 0,
        wakeup_enabled,
    })
}

/// Whether the stock app offers the Basic/Pro switch for this unit, from its
/// SW revision string (2A28), per the spec's `protocol_details.paywall`:
/// always on Peach 2 go and Pro MAX, on a plain Peach 2 only when the
/// revision does not end in a–g, never on Duo. Anything unrecognised is
/// `false`: the 0AD0 write is only confirmed on the new dialect, and an
/// unknown model is not one to guess a dialect for.
pub fn foreo_pro_mode_supported(sw_revision: &str) -> bool {
    let revision = sw_revision.trim_matches(|c: char| c == '\0' || c.is_whitespace());
    let Some((model, _)) = revision.split_once(char::is_whitespace) else {
        return false;
    };
    match model.to_ascii_uppercase().as_str() {
        "PEACH2GO" | "PEACH2PROMAX" => true,
        "PEACH2" => revision.chars().last().is_some_and(|c| {
            c.is_ascii_alphabetic() && !('a'..='g').contains(&c.to_ascii_lowercase())
        }),
        _ => false,
    }
}

/// An FFF1 read-back of nothing but FF bytes (or nothing at all) means the
/// device was busy; the stock app retries up to five times.
pub fn foreo_reply_busy(reply: &[u8]) -> bool {
    reply.iter().all(|byte| *byte == 0xFF)
}

/// Whether an FFF1 read-back acknowledges a settings write: every accepted
/// write in the capture and the replay read back a leading 01.
pub fn foreo_write_acknowledged(reply: &[u8]) -> bool {
    !foreo_reply_busy(reply) && reply.first() == Some(&0x01)
}

/// Decode the 0BD0 removal-mode read-back: `true` for Pro (>= 06), `false`
/// for Basic (01 on hardware).
pub fn decode_foreo_removal_mode(reply: &[u8]) -> Result<bool> {
    if foreo_reply_busy(reply) {
        bail!("removal mode read-back was busy or empty");
    }
    Ok(reply[0] >= FOREO_PRO_MODE_MIN)
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
            decode_foreo_status(&[0], Some(&[0])).unwrap(),
            ForeoStatus {
                locked: true,
                wakeup_enabled: Some(false),
            }
        );
        assert_eq!(
            decode_foreo_status(&[1], Some(&[1])).unwrap(),
            ForeoStatus {
                locked: false,
                wakeup_enabled: Some(true),
            }
        );
        assert!(decode_foreo_status(&[], Some(&[1])).is_err());
        assert!(decode_foreo_status(&[1], Some(&[])).is_err());
    }

    #[test]
    fn a_unit_without_0a30_has_no_wakeup_to_enable() {
        // The replay's F.REV.K unit: 0A20 reads 01 plus unit bytes, no 0A30.
        let status = decode_foreo_status(&[1, 0x12, 0x34], None).unwrap();
        assert!(!status.locked);
        assert_eq!(status.wakeup_enabled, None);
    }

    #[test]
    fn pro_switch_follows_the_stock_app_visibility_rule() {
        for supported in [
            "PEACH2 F.REV.K",
            "PEACH2 F.REV.H",
            "PEACH2 F.REV.L\0\0",
            "PEACH2GO F.REV.B",
            "PEACH2ProMAX F.REV.A",
        ] {
            assert!(foreo_pro_mode_supported(supported), "{supported}");
        }
        for hidden in [
            "PEACH2 F.REV.C",
            "PEACH2 F.REV.G",
            "PEACH2 F.REV.d",
            "PEACH2Duo F.REV.K",
            "UNKNOWN F.REV.K",
            "PEACH2",
            "",
        ] {
            assert!(!foreo_pro_mode_supported(hidden), "{hidden:?}");
        }
    }

    #[test]
    fn decodes_removal_mode_and_acknowledgements_as_captured() {
        // 18-byte read-backs as on hardware: value, then zero padding.
        let mut basic = vec![0x01];
        basic.resize(18, 0);
        let mut pro = vec![0x06];
        pro.resize(18, 0);
        assert!(!decode_foreo_removal_mode(&basic).unwrap());
        assert!(decode_foreo_removal_mode(&pro).unwrap());
        assert!(decode_foreo_removal_mode(&[0xFF; 18]).is_err());
        assert!(decode_foreo_removal_mode(&[]).is_err());

        assert!(foreo_write_acknowledged(&basic));
        assert!(!foreo_write_acknowledged(&pro));
        assert!(!foreo_write_acknowledged(&[0xFF; 18]));
        assert!(foreo_reply_busy(&[0xFF; 18]));
        assert!(!foreo_reply_busy(&basic));
    }
}
