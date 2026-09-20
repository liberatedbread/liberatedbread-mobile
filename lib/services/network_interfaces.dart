// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import '../core/ha_url.dart' show isPrivateIpv4;

/// Enumerating and filtering the network interfaces discovery should use.
///
/// The default `NetworkInterface.list`, and package:multicast_dns's
/// `allInterfacesFactory`, hand back every interface the host has — loopback,
/// VPN tunnels (`utun*`), the cellular data interface (`pdp_ip*`),
/// point-to-point links (`ppp*`) and Apple's peer-to-peer radios
/// (`awdl*`/`llw*`). Two things go wrong when discovery treats them all as
/// equal:
///
///   * package:multicast_dns joins 224.0.0.251 on each one with no error
///     isolation. A join that the OS refuses (a link-local-only address, a
///     point-to-point tunnel) throws out of `start()`, taking the whole mDNS
///     transport down and leaking the already-bound :5353 socket (F-049).
///   * An unbound UDP socket's multicast/broadcast egress follows the primary
///     (default-route) interface. On an iPhone whose Wi-Fi has no internet
///     (an IoT VLAN, a captive SoftAP) iOS re-selects cellular as primary, so
///     every probe leaves over `pdp_ip0` and the LAN never hears it (F-014).
///
/// So discovery picks the Wi-Fi/LAN interface(s) itself. This lives apart from
/// the scan service, and takes an injectable [InterfaceLister], so the filter
/// is provable in host tests with fabricated interfaces rather than whatever
/// the test machine happens to have plugged in.

/// The shape of `NetworkInterface.list`, so a test can substitute a fake.
typedef InterfaceLister =
    Future<List<NetworkInterface>> Function({
      bool includeLoopback,
      bool includeLinkLocal,
      InternetAddressType type,
    });

/// Interface-name prefixes that are never a LAN: VPN tunnels, the cellular
/// data interface, point-to-point links and Apple's peer-to-peer radios.
/// Matched case-insensitively against the interface name.
const List<String> tunnelInterfacePrefixes = [
  'utun', // macOS/iOS VPN and personal-hotspot tunnels
  'pdp_ip', // iOS cellular data
  // Android cellular data, which carriers hand RFC1918 addresses — so
  // isPrivateIpv4 accepts them and primaryLanIpv4 would return one whenever
  // the OS enumerates it before wlan0. IP_MULTICAST_IF then pins every
  // multicast sender in the scan — the mDNS client and its raw source
  // capture, SSDP, the catalogue's UDP probes, Yeelight, KNX and Govee — to
  // the cellular interface, where no LAN device can hear them; without the
  // name filter the OS default route at least carried them over Wi-Fi.
  'rmnet', // rmnet_data0 and friends (Qualcomm)
  'v4-rmnet', // 464XLAT clat interface over rmnet
  'ccmni', // MediaTek cellular
  'wwan', // generic mobile broadband
  'clat', // 464XLAT translation interface
  'ppp', // point-to-point (legacy VPN, some cellular)
  'ipsec', // IPsec tunnels
  'tun', // OpenVPN/WireGuard on desktop
  'tap', // bridged VPN taps
  'awdl', // Apple Wireless Direct Link (AirDrop/AirPlay peer radio)
  'llw', // Apple low-latency WLAN peer radio
  'gif', // generic tunnel
  'stf', // 6to4 tunnel
];

bool _hasTunnelPrefix(String lowerName) =>
    tunnelInterfacePrefixes.any(lowerName.startsWith);

/// Whether [interface] is a plausible Wi-Fi/LAN interface for discovery.
///
/// Rejects the tunnel/cellular/peer-radio families outright by name, and
/// rejects anything left that carries no routable address (only loopback or
/// link-local) — a link-local-only interface is exactly the kind whose
/// multicast join Darwin refuses with EADDRNOTAVAIL. Loopback is kept only
/// when [includeLoopback] is set: joining the mDNS group on `lo0` is harmless
/// and, on a single-host test rig, is how the emulated responder's traffic
/// loops back, so the mDNS path keeps it; interface *egress* selection does
/// not.
bool isLanCandidate(
  NetworkInterface interface, {
  bool includeLoopback = false,
}) {
  final name = interface.name.toLowerCase();
  if (_hasTunnelPrefix(name)) return false;
  if (name.startsWith('lo')) return includeLoopback;
  return interface.addresses.any((a) => !a.isLoopback && !a.isLinkLocal);
}

/// The LAN interfaces of [type], tunnels and cellular filtered out.
///
/// Falls back to the unfiltered list when the filter would leave nothing —
/// better to join/send on a questionable interface than on none at all, which
/// would make discovery deaf. [includeLoopback] is passed through to both the
/// underlying enumeration and [isLanCandidate].
Future<List<NetworkInterface>> lanInterfaces(
  InternetAddressType type, {
  InterfaceLister lister = NetworkInterface.list,
  bool includeLoopback = false,
}) async {
  final all = await lister(
    includeLoopback: includeLoopback,
    includeLinkLocal: false,
    type: type,
  );
  final candidates = all
      .where((i) => isLanCandidate(i, includeLoopback: includeLoopback))
      .toList();
  return candidates.isEmpty ? all.toList() : candidates;
}

/// The address to send LAN discovery multicast/broadcast from: the first
/// routable IPv4 of the first LAN interface, or null when none can be found
/// (in which case the caller leaves the OS to pick, as it did before).
///
/// A private/RFC1918 address is preferred over any other routable one, so a
/// VPN interface that slipped through the name filter with a public address
/// does not win over the real LAN.
///
/// [lanInterfaces]' "yield to the unfiltered list rather than return nothing"
/// fallback is deliberately NOT honoured here, and the filter is re-applied to
/// whatever it hands back. That fallback exists so a multicast JOIN happens on
/// a questionable interface rather than on none; egress selection is the
/// opposite case — pinning IP_MULTICAST_IF to `rmnet_data0` or `utun0` is
/// worse than not pinning at all, because it overrides the OS default route
/// with the one interface the name filter exists to exclude. Null is the
/// answer this doc promises for "none can be found", and it restores exactly
/// the pre-F-014 behaviour: the OS picks.
Future<InternetAddress?> primaryLanIpv4({
  InterfaceLister lister = NetworkInterface.list,
}) async {
  final interfaces = (await lanInterfaces(
    InternetAddressType.IPv4,
    lister: lister,
  )).where((i) => isLanCandidate(i)).toList();
  InternetAddress? firstRoutable;
  for (final interface in interfaces) {
    for (final addr in interface.addresses) {
      if (addr.type != InternetAddressType.IPv4) continue;
      if (addr.isLoopback || addr.isLinkLocal) continue;
      firstRoutable ??= addr;
      if (isPrivateIpv4(addr.address)) return addr;
    }
  }
  return firstRoutable;
}
