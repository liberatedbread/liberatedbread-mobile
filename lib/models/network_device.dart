// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../core/hex.dart';
import 'package:flutter/foundation.dart';

/// How a network device was found.
///
/// Kept on the device rather than inferred, because the two protocols answer
/// different questions and a device found by both is better evidence than one
/// found by either.
enum NetworkDiscoverySource {
  /// mDNS / DNS-SD (Bonjour). How every modern local-first device announces
  /// itself; the specs' `mdns_service_type` is matched against this.
  mdns,

  /// SSDP / UPnP. Older, and the only way to find some devices at all — Wemo
  /// and the pre-2020 Hue bridges have no mDNS presence worth the name.
  ssdp,
}

/// A device found on the local network.
///
/// The Wi-Fi counterpart of `IoTDevice`. Deliberately not the same class: a
/// network device has no RSSI and no connectable flag, and it has an address
/// that changes with DHCP rather than a hardware identity. Conflating them
/// would mean a pile of fields that are null for one half of the app.
@immutable
class NetworkDevice {
  /// IP address. Not an identity — DHCP reassigns it — but it is what a user
  /// recognises and what a client connects to.
  final String host;

  /// Service instance name (mDNS) or friendly name (SSDP), when advertised.
  final String name;

  /// Hostname the device claims, e.g. `Lutron-083e013d.local`. Often carries a
  /// serial number, which makes it a far better identity than the address.
  final String? hostname;

  /// TCP port the advertised service listens on.
  final int? port;

  /// mDNS service types this device advertises, e.g. `_hue._tcp.local`.
  final List<String> serviceTypes;

  /// SSDP search targets this device answered to, e.g.
  /// `urn:Belkin:device:controllee:1`.
  final List<String> ssdpTargets;

  /// SSDP `SERVER:` header — an OS/product string like
  /// `Unspecified, UPnP/1.0, Unspecified`. Free-form vendor text.
  final String? server;

  /// Key/value pairs from an mDNS TXT record. Devices publish model numbers,
  /// bridge ids and sometimes a MAC address here.
  final Map<String, String> txt;

  final Set<NetworkDiscoverySource> sources;
  final DateTime discoveredAt;

  const NetworkDevice({
    required this.host,
    required this.name,
    required this.sources,
    required this.discoveredAt,
    this.hostname,
    this.port,
    this.serviceTypes = const [],
    this.ssdpTargets = const [],
    this.server,
    this.txt = const {},
  });

  /// What to call this in a list: the advertised name, else the hostname with
  /// its `.local` suffix trimmed, else the bare address.
  String get displayName {
    if (name.isNotEmpty) return name;
    final host = hostname;
    if (host != null && host.isNotEmpty) return stripLocalSuffix(host);
    return this.host;
  }

  /// A MAC address the device published in its TXT record, if any.
  ///
  /// Worth looking for: it is the one thing on the network side that can be
  /// run through the IEEE registry, and unlike the IP it does not move.
  String? get advertisedMac {
    for (final key in const [
      'mac',
      'macaddr',
      'macaddress',
      'bridgeid',
      'id'
    ]) {
      final value = txt[key];
      if (value == null) continue;
      final hex = normalizeMacHex(value);
      if (hex == null) continue;
      if (hex.length == 12) return _colonize(hex);
      // A Hue bridge publishes `bridgeid` as an EUI-64: the 48-bit address with
      // FFFE spliced into the middle. Dropping those four digits recovers the
      // real address — truncating to the first twelve, which is the obvious
      // wrong move, yields FF:FE in the middle and resolves to nothing.
      if (hex.length == 16 && hex.substring(6, 10) == 'FFFE') {
        return _colonize(hex.substring(0, 6) + hex.substring(10));
      }
    }
    return null;
  }

  static String _colonize(String hex) => [
        for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)
      ].join(':');

  /// Merge another sighting of the same host, so a device answering on both
  /// mDNS and SSDP becomes one row carrying everything both said.
  NetworkDevice mergedWith(NetworkDevice other) => NetworkDevice(
        host: host,
        name: name.isNotEmpty ? name : other.name,
        hostname: hostname ?? other.hostname,
        port: port ?? other.port,
        serviceTypes: {...serviceTypes, ...other.serviceTypes}.toList(),
        ssdpTargets: {...ssdpTargets, ...other.ssdpTargets}.toList(),
        server: server ?? other.server,
        txt: {...other.txt, ...txt},
        sources: {...sources, ...other.sources},
        // The first sighting is when this device was discovered.
        discoveredAt: discoveredAt.isBefore(other.discoveredAt)
            ? discoveredAt
            : other.discoveredAt,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is NetworkDevice && host == other.host;

  @override
  int get hashCode => host.hashCode;

  /// Whether two sightings say the same thing about what the device is —
  /// everything matching reads, and nothing that merely changes with time.
  bool hasSameIdentity(NetworkDevice other) =>
      other.host == host &&
      other.name == name &&
      other.hostname == hostname &&
      other.port == port &&
      listEquals(other.serviceTypes, serviceTypes) &&
      listEquals(other.ssdpTargets, ssdpTargets) &&
      mapEquals(other.txt, txt);
}

final RegExp _localSuffix = RegExp(r'\.local\.?$');

/// Drop a DNS name's `.local`/`.local.` suffix for display. One rule shared by
/// [NetworkDevice.displayName] and the Wi-Fi screen's service-type labels — the
/// Rust matcher keeps its own `normalize_service_type` as the comparison-side
/// counterpart.
String stripLocalSuffix(String name) => name.replaceAll(_localSuffix, '');
