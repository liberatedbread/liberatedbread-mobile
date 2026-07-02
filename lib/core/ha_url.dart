// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Classification of Home Assistant base URLs, used by the setup screen to
// decide which remote-access hint to show (e.g. suggest Tailscale for
// LAN-only addresses).

/// Where a Home Assistant URL is reachable from.
enum HaUrlKind {
  /// Not parseable as an http/https URL with a host.
  invalid,

  /// A Tailscale address: `*.ts.net` MagicDNS name or a 100.64.0.0/10
  /// (CGNAT) tailnet IP. Reachable from anywhere on the tailnet.
  tailscale,

  /// A private/loopback/link-local IPv4 address - only works on the home LAN.
  privateLan,

  /// An mDNS `.local` name - only works on the home LAN.
  mdnsLocal,

  /// A public name over plain HTTP - works remotely but unencrypted.
  publicHttp,

  /// A public name over HTTPS.
  publicHttps,
}

/// Classify a user-entered Home Assistant base URL.
HaUrlKind classifyHaUrl(String input) {
  // Uri.tryParse tolerates embedded whitespace; a real URL never has any.
  if (input.trim().contains(RegExp(r'\s'))) return HaUrlKind.invalid;
  final uri = Uri.tryParse(normalizeHaBaseUrl(input));
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return HaUrlKind.invalid;
  }
  final host = uri.host.toLowerCase();
  if (host.endsWith('.ts.net') || _isTailnetIpv4(host)) {
    return HaUrlKind.tailscale;
  }
  if (host.endsWith('.local')) return HaUrlKind.mdnsLocal;
  if (isPrivateIpv4(host) || host == 'localhost') return HaUrlKind.privateLan;
  return uri.scheme == 'https' ? HaUrlKind.publicHttps : HaUrlKind.publicHttp;
}

/// Trim whitespace, default to `http://` when no scheme is given, and strip
/// any trailing slashes so webhook paths can be appended directly.
String normalizeHaBaseUrl(String input) {
  var url = input.trim();
  if (url.isEmpty) return url;
  if (!url.contains('://')) url = 'http://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// True for RFC1918, loopback, and link-local IPv4 literals.
bool isPrivateIpv4(String host) {
  final octets = _ipv4Octets(host);
  if (octets == null) return false;
  final (a, b) = (octets[0], octets[1]);
  if (a == 10 || a == 127) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  if (a == 169 && b == 254) return true;
  return false;
}

/// True for the 100.64.0.0/10 CGNAT range Tailscale assigns tailnet IPs from.
bool _isTailnetIpv4(String host) {
  final octets = _ipv4Octets(host);
  if (octets == null) return false;
  return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
}

List<int>? _ipv4Octets(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    octets.add(value);
  }
  return octets;
}
