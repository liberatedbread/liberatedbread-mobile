// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! What each radio in the UV-17Pro family looks like in memory.

use super::uv17pro::{HandshakeExchange, HANDSHAKE_UV17PRO, HANDSHAKE_UV17PRO_GPS};

/// One radio's programming parameters.
///
/// Every number here is a claim about hardware. They come from CHIRP's
/// driver, which is used by a great many people against these radios, but
/// none has been read off a radio by this project -- see the module doc.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RadioModel {
    /// Stable id, matching the Dart profile id so the two tables line up.
    pub id: &'static str,

    pub display_name: &'static str,

    /// The 16-byte ASCII strings that put this radio into programming mode,
    /// in the order to try them.
    ///
    /// A list because one model can answer different strings on different
    /// firmware: a UV-5G Mini on v0.05 ignores the v0.01 string entirely, so
    /// a single magic left it unprogrammable (CHIRP `UV5GMini._idents`).
    pub idents: &'static [&'static [u8]],

    /// The exchanges after the ident is acknowledged. Per model because the
    /// `M` reply is 15 bytes on some and 7 on others.
    pub handshake: &'static [HandshakeExchange],

    /// Contiguous stretches of radio memory, as (start address, length).
    /// Concatenated in order, they are the flat codeplug image.
    pub regions: &'static [(u16, u16)],

    /// Total image size -- the sum of the region lengths, kept alongside as
    /// the thing a read can be checked against.
    pub image_len: u32,

    /// How many memory channels the image holds, from the start of the
    /// image.
    pub channel_count: u16,
}

/// 32 bytes per channel record, for every model in this family.
pub const CHANNEL_RECORD_LEN: u32 = 32;

/// The longest channel name a record holds, for every model in this family.
pub const NAME_LEN: usize = 12;

/// UV-5R Mini: the radio this build programs over its own Bluetooth.
pub const UV5R_MINI: RadioModel = RadioModel {
    id: "uv-5r-mini",
    display_name: "Baofeng UV-5R Mini",
    idents: &[b"PROGRAMCOLORPROU"],
    handshake: HANDSHAKE_UV17PRO,
    regions: &[(0x0000, 0x8040), (0x9000, 0x0040), (0xA000, 0x01C0)],
    image_len: 0x8240,
    channel_count: 999,
};

/// UV-5G Mini / Mini 5: the GMRS Mini, same protocol and same layout.
pub const UV5G_MINI: RadioModel = RadioModel {
    id: "uv-5g-mini",
    display_name: "Baofeng Mini 5 / UV-5G Mini",
    // CHIRP's order: firmware v0.05 (the units shipping since late 2025)
    // answers only the GMRS string, v0.01 only the UV-5R Mini's. The newer
    // one goes first so most radios ack on the first try.
    idents: &[b"PROGRAMGMRS5RMIU", b"PROGRAMCOLORPROU"],
    ..UV5R_MINI
};

/// UV-32. Same family by every public account; nobody has posted a capture,
/// and this project has not read one either.
///
/// CHIRP's UV32 subclasses UV17ProGPS, which subclasses UV17Pro: it takes the
/// GPS branch's 7-byte `M` reply and the UV-17Pro's 1000-slot memory table
/// (999 is the Mini's figure; with it slot 1000 was never read, written or
/// cleared). Both, like every number here, are CHIRP's and unread off a radio.
/// Its Bluetooth write size and 0x80 padding follow the Minis, not CHIRP
/// (CHIRP's UV17ProGPS has no BLE upload branch), and need a capture to confirm.
pub const UV32: RadioModel = RadioModel {
    id: "uv-32",
    display_name: "Baofeng UV-32",
    idents: &[b"PROGRAMCOLORPROU"],
    handshake: HANDSHAKE_UV17PRO_GPS,
    regions: &[
        (0x0000, 0x8040),
        (0x9000, 0x0040),
        (0xA000, 0x02C0),
        (0xD000, 0x0040),
    ],
    image_len: 0x8380,
    channel_count: 1000,
};

/// UV-17R Plus. No transport in this build -- it needs a cable -- but the
/// codec is the same one, so it is described here rather than discovered
/// again later.
pub const UV17R_PLUS: RadioModel = RadioModel {
    id: "uv-17r-plus",
    display_name: "Baofeng UV-17R Plus",
    idents: &[b"PROGRAMBFNORMALU"],
    handshake: HANDSHAKE_UV17PRO,
    regions: &[
        (0x0000, 0x8040),
        (0x9000, 0x0040),
        (0xA000, 0x02C0),
        (0xD000, 0x0040),
    ],
    image_len: 0x8380,
    channel_count: 1000,
};

/// Every model this codec knows.
pub const MODELS: &[RadioModel] = &[UV5R_MINI, UV5G_MINI, UV32, UV17R_PLUS];

/// Look a model up by the id the Dart profile carries.
pub fn model_by_id(id: &str) -> Option<&'static RadioModel> {
    MODELS.iter().find(|model| model.id == id)
}

impl RadioModel {
    /// Byte range of channel `index` (0-based) in the flat image.
    pub fn channel_range(&self, index: u16) -> Option<(usize, usize)> {
        if index >= self.channel_count {
            return None;
        }
        let start = u32::from(index) * CHANNEL_RECORD_LEN;
        let end = start + CHANNEL_RECORD_LEN;
        if end > self.image_len {
            return None;
        }
        Some((start as usize, end as usize))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_model_describes_an_image_its_regions_add_up_to() {
        // A mistyped region table is otherwise found by a radio, which reads
        // the wrong number of blocks and hands back a shifted codeplug.
        for model in MODELS {
            let regions_len: u32 = model.regions.iter().map(|&(_, size)| u32::from(size)).sum();
            assert_eq!(
                regions_len, model.image_len,
                "{} regions sum to 0x{:X}, not 0x{:X}",
                model.id, regions_len, model.image_len
            );
        }
    }

    #[test]
    fn every_model_has_sixteen_byte_ident_magics() {
        for model in MODELS {
            assert!(!model.idents.is_empty(), "{}", model.id);
            for ident in model.idents {
                assert_eq!(ident.len(), 16, "{}", model.id);
                assert!(ident.starts_with(b"PROGRAM"), "{}", model.id);
            }
        }
    }

    #[test]
    fn the_uv5g_mini_tries_the_v005_gmrs_string_first() {
        // A v0.05 UV-5G Mini ignores PROGRAMCOLORPROU, so with only that
        // string it could never be put into programming mode.
        assert_eq!(UV5G_MINI.idents[0], b"PROGRAMGMRS5RMIU");
        assert!(UV5G_MINI.idents.contains(&UV5R_MINI.idents[0]));
        assert_eq!(UV5R_MINI.idents, &[b"PROGRAMCOLORPROU" as &[u8]]);
    }

    #[test]
    fn the_m_reply_is_seven_bytes_on_the_uv32_and_fifteen_elsewhere() {
        // CHIRP: UV32 inherits UV17ProGPS._magics (M -> 7); the Minis and the
        // UV-17R Plus keep UV17Pro's (M -> 15). Waiting for 15 from a UV-32
        // stalled every session at the step timeout.
        let m_len = |model: &RadioModel| {
            let step = model
                .handshake
                .iter()
                .find(|s| s.request == [0x4D])
                .expect(model.id);
            step.expected_reply_len
        };
        assert_eq!(m_len(&UV32), 7);
        for model in [&UV5R_MINI, &UV5G_MINI, &UV17R_PLUS] {
            assert_eq!(m_len(model), 15, "{}", model.id);
        }
    }

    #[test]
    fn the_uv32_has_the_uv17pro_memory_table() {
        // CHIRP's UV32 overrides only its name and power levels, so its
        // image is the UV-17Pro's, 1000 slots and all.
        assert_eq!(UV32.channel_count, 1000);
        assert_eq!(UV32.channel_count, UV17R_PLUS.channel_count);
        assert_eq!(UV32.regions, UV17R_PLUS.regions);
        assert_eq!(UV32.image_len, UV17R_PLUS.image_len);
    }

    #[test]
    fn ids_are_unique() {
        for (i, model) in MODELS.iter().enumerate() {
            for other in &MODELS[i + 1..] {
                assert_ne!(model.id, other.id);
            }
        }
    }

    #[test]
    fn lookup_finds_every_model_and_nothing_else() {
        for model in MODELS {
            assert_eq!(model_by_id(model.id).map(|m| m.id), Some(model.id));
        }
        assert!(model_by_id("nokia-3310").is_none());
        assert!(model_by_id("").is_none());
    }

    #[test]
    fn the_channel_block_fits_inside_the_image() {
        for model in MODELS {
            let last = model.channel_count - 1;
            let (_, end) = model.channel_range(last).expect(model.id);
            assert!(
                end as u32 <= model.image_len,
                "{} channel {} ends past its image",
                model.id,
                last
            );
        }
    }

    #[test]
    fn channel_ranges_are_contiguous_and_thirty_two_bytes_each() {
        let model = &UV5R_MINI;
        let (first_start, first_end) = model.channel_range(0).unwrap();
        let (second_start, _) = model.channel_range(1).unwrap();
        assert_eq!(first_end - first_start, CHANNEL_RECORD_LEN as usize);
        assert_eq!(second_start, first_end);
    }

    #[test]
    fn a_slot_past_the_end_has_no_range() {
        assert!(UV5R_MINI.channel_range(UV5R_MINI.channel_count).is_none());
    }

    #[test]
    fn the_two_minis_share_a_layout_and_a_handshake() {
        // The GMRS Mini is the same radio with a different channel plan, and
        // its codeplug is byte-for-byte the same shape.
        assert_eq!(UV5G_MINI.regions, UV5R_MINI.regions);
        assert_eq!(UV5G_MINI.image_len, UV5R_MINI.image_len);
        assert_eq!(UV5G_MINI.handshake, UV5R_MINI.handshake);
        assert_eq!(UV5G_MINI.channel_count, UV5R_MINI.channel_count);
        assert_ne!(UV5G_MINI.id, UV5R_MINI.id);
    }
}
