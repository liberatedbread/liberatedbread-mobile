// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! What each radio in the UV-17Pro family looks like in memory.

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

    /// The 16-byte ASCII string that puts this radio into programming mode.
    pub ident_magic: &'static [u8],

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
    ident_magic: b"PROGRAMCOLORPROU",
    regions: &[(0x0000, 0x8040), (0x9000, 0x0040), (0xA000, 0x01C0)],
    image_len: 0x8240,
    channel_count: 999,
};

/// UV-5G Mini / Mini 5: the GMRS Mini, same protocol and same layout.
pub const UV5G_MINI: RadioModel = RadioModel {
    id: "uv-5g-mini",
    display_name: "Baofeng Mini 5 / UV-5G Mini",
    ..UV5R_MINI
};

/// UV-32. Same family by every public account; nobody has posted a capture,
/// and this project has not read one either.
pub const UV32: RadioModel = RadioModel {
    id: "uv-32",
    display_name: "Baofeng UV-32",
    ident_magic: b"PROGRAMCOLORPROU",
    regions: &[
        (0x0000, 0x8040),
        (0x9000, 0x0040),
        (0xA000, 0x02C0),
        (0xD000, 0x0040),
    ],
    image_len: 0x8380,
    channel_count: 999,
};

/// UV-17R Plus. No transport in this build -- it needs a cable -- but the
/// codec is the same one, so it is described here rather than discovered
/// again later.
pub const UV17R_PLUS: RadioModel = RadioModel {
    id: "uv-17r-plus",
    display_name: "Baofeng UV-17R Plus",
    ident_magic: b"PROGRAMBFNORMALU",
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
    fn every_model_has_a_sixteen_byte_ident_magic() {
        for model in MODELS {
            assert_eq!(model.ident_magic.len(), 16, "{}", model.id);
            assert!(model.ident_magic.starts_with(b"PROGRAM"), "{}", model.id);
        }
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
    fn the_two_minis_share_a_layout_and_differ_only_in_name() {
        // The GMRS Mini is the same radio with a different channel plan, and
        // its codeplug is byte-for-byte the same shape.
        assert_eq!(UV5G_MINI.regions, UV5R_MINI.regions);
        assert_eq!(UV5G_MINI.image_len, UV5R_MINI.image_len);
        assert_eq!(UV5G_MINI.ident_magic, UV5R_MINI.ident_magic);
        assert_ne!(UV5G_MINI.id, UV5R_MINI.id);
    }
}
