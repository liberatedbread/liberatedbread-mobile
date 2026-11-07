// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What a device exposes that its matched spec does not describe.
//
// A spec is written from one unit, one firmware, one region. The next unit off
// the line may carry an OTA service the author never saw, or announce a second
// mDNS type for a feature the spec has no entity for yet. Those are exactly the
// gaps a spec author wants to hear about, and the app is the only thing that
// ever sees them — so it notices, and asks the user whether to tell us.
//
// Pure functions, no I/O: the screens hand in what they discovered and what
// the spec declared, and get back the difference minus the noise.

import 'hex.dart';

/// GATT services that every peripheral carries and no spec needs to declare:
/// Generic Access (0x1800), Generic Attribute (0x1801) and Device Information
/// (0x180A). Reporting them would put a banner on every device in the
/// catalogue. In [normalizeUuid] form.
const Set<String> ubiquitousGattServices = {'1800', '1801', '180a'};

/// mDNS service types that say nothing about what a device IS: a web admin
/// page, an SSH daemon, Apple's device-info record, a printer's sharing stack
/// riding on a general-purpose box. Real devices announce these alongside the
/// one that identifies them, and a spec that does not list them is not wrong.
/// In [normalizeServiceType] form.
const Set<String> genericMdnsTypes = {
  '_http._tcp',
  '_https._tcp',
  '_device-info._tcp',
  '_workstation._tcp',
  '_ssh._tcp',
  '_sftp-ssh._tcp',
  '_smb._tcp',
  '_afpovertcp._tcp',
  '_services._dns-sd._udp',
};

/// The UPnP search targets every UPnP device answers to, whatever it is.
bool _isGenericSsdpTarget(String target) =>
    target == 'upnp:rootdevice' ||
    target == 'ssdp:all' ||
    target.startsWith('uuid:');

/// An mDNS type in comparison form: lowercase, no trailing dot, no `.local`
/// domain. `_Hue._tcp.local.` and `_hue._tcp` are the same announcement.
String normalizeServiceType(String type) {
  var t = type.trim().toLowerCase();
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  if (t.endsWith('.local')) t = t.substring(0, t.length - '.local'.length);
  return t;
}

/// Discovered GATT service UUIDs the spec does not declare, in [normalizeUuid]
/// form, sorted and de-duplicated. Empty when the spec covers everything
/// worth mentioning.
List<String> unexpectedGattServices({
  required Iterable<String> declared,
  required Iterable<String> discovered,
}) {
  final known = {for (final u in declared) normalizeUuid(u)};
  return {
    for (final u in discovered)
      if (!known.contains(normalizeUuid(u)) &&
          !ubiquitousGattServices.contains(normalizeUuid(u)))
        normalizeUuid(u),
  }.toList()..sort();
}

/// Announced mDNS types the spec does not declare, in [normalizeServiceType]
/// form, sorted and de-duplicated.
List<String> unexpectedMdnsTypes({
  required Iterable<String> declared,
  required Iterable<String> announced,
}) {
  final known = {for (final t in declared) normalizeServiceType(t)};
  return {
    for (final t in announced)
      if (!known.contains(normalizeServiceType(t)) &&
          !genericMdnsTypes.contains(normalizeServiceType(t)))
        normalizeServiceType(t),
  }.toList()..sort();
}

/// Answered SSDP search targets the spec does not declare, lowercased, sorted
/// and de-duplicated. `upnp:rootdevice` and per-unit `uuid:` targets are
/// never reported: one is universal, the other is a serial number.
List<String> unexpectedSsdpTargets({
  required Iterable<String> declared,
  required Iterable<String> answered,
}) {
  final known = {for (final t in declared) t.trim().toLowerCase()};
  return {
    for (final t in answered.map((t) => t.trim().toLowerCase()))
      if (!known.contains(t) && !_isGenericSsdpTarget(t)) t,
  }.toList()..sort();
}
