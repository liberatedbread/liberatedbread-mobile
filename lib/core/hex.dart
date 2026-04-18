// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// Format bytes as space-separated lowercase hex (e.g. `[0x01, 0xaa] -> '01 aa'`).
String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

/// Lowercase a BLE UUID for case-insensitive comparison.
String normalizeUuid(String uuid) => uuid.toLowerCase();
