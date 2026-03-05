// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Device-specific protocol overrides.
//!
//! Most devices work fine with `GenericProtocol` driven by the YAML spec.
//! This module is for devices that need custom logic beyond what the spec
//! can express (e.g., checksums, encryption, multi-step handshakes).
//!
//! Add a module per device here as protocols are reverse-engineered.
