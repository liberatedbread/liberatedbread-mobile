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
//! `baofeng_common.py`). Facts are not copyrightable and are used freely;
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
