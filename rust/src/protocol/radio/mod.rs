// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Radio programming protocols.
//!
//! # Where these facts come from
//!
//! The framing, the memory layout and the byte-substitution table below are
//! facts about Baofeng's hardware, established from CHIRP's publicly
//! published drivers (`chirp/drivers/baofeng_uv17Pro.py` and
//! `baofeng_common.py` for the newer family, `uv5r.py` for the older one). Facts are not copyrightable and are used freely;
//! CHIRP's implementation is GPL-3.0 and this crate is Apache-2.0, so
//! **nothing here is a copy or a line-by-line translation of that code** --
//! every routine is written from the format.
//!
//! # What is verified and what is not
//!
//! Nothing in this module has been run against a radio. The layout is
//! consistent with a widely-used driver, the codecs round-trip against
//! themselves, and the framing matches the documented shape -- but the first
//! read from real hardware is the thing that turns this from plausible into
//! true. The live-radio suite exists for exactly that.

pub mod codeplug;
pub mod models;
pub mod uv17pro;
pub mod uv5r;

/// The byte both families answer a good command with.
pub const ACK: u8 = 0x06;

/// A read's answer starts by echoing a four-byte header -- the opcode, the
/// address and the length -- in both families; the older one is where the
/// newer one's framing comes from.
pub const REPLY_HEADER_LEN: usize = 4;

/// How many bytes a read of `len` answers with, header included.
///
/// Dart needs it before the first byte arrives: an answer comes in pieces --
/// ~20-byte notifications over Bluetooth, whatever the bridge chip hands on
/// over a cable -- and knowing the total is how "still arriving" is told from
/// "done".
pub fn read_reply_len(len: u8) -> usize {
    REPLY_HEADER_LEN + len as usize
}

/// One block of a read or a write: where it lives on the radio, and where it
/// belongs in the flat image. The two differ -- neither family's image is
/// its address space -- and conflating them is how a codeplug ends up
/// shifted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Block {
    /// Address on the radio.
    pub addr: u16,
    pub len: u8,
    /// Offset into the flat image.
    pub image_offset: usize,
}
