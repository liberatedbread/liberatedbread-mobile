// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Protocol middleware — placeholder for byte-level transforms applied
//! between the BLE transport and the `DeviceProtocol` encode/decode layer.
//!
//! Intended to host:
//!
//! - **Encryption**: apply/strip the cipher configured by
//!   `spec::types::EncryptionConfig` (algorithm, key derivation, static key).
//! - **Framing**: length-prefix handling and chunk reassembly as described
//!   by `spec::types::FramingConfig` (length prefix, max chunk size).
//! - **Checksum**: append on write and verify on read per the `checksum`
//!   field of `FramingConfig`.
//!
//! The configuration shapes already live in `crate::spec::types`; concrete
//! middleware implementations will be added as device protocols that
//! require them are reverse-engineered.
