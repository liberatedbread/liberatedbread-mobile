// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// The Hue bridgeid a discovery record's `txt['bridgeid']` names, uppercased,
/// or null when it is absent or not the 16-character id a bridge advertises.
///
/// One rule for every path that keys `HubCredentialStore` from a sighting —
/// the hub screen's own forget and the Saved screen's Remove — so the two
/// cannot drift into clearing different keys (Remove used to clear none,
/// leaving the whitelist username and TLS pin behind while it said
/// "Removed").
String? advertisedHueBridgeId(String? advertised) {
  if (advertised == null || advertised.length != 16) return null;
  return advertised.toUpperCase();
}
