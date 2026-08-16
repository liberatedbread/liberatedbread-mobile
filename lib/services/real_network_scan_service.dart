// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../core/stop_signal.dart';
import '../models/network_device.dart';
import 'datagram_bind.dart';
import 'multicast_lock.dart';
import 'network_scan_service.dart';
import 'spec_codec.dart';

/// The DNS-SD meta-query that enumerates every service type on the link.
/// Asking this instead of a fixed list is what lets the scan find a device
/// whose spec we have not written yet.
const _serviceEnumerationQuery = '_services._dns-sd._udp.local';

const _ssdpAddress = '239.255.255.250';
const _ssdpPort = 1900;

/// LIFX LAN-protocol discovery. LIFX devices answer a broadcast `GetService`
/// (message type 2) with a `StateService` (type 3) whose header carries the
/// device MAC. This is the only reliable way to find LIFX hardware — a shared
/// `_hap._tcp` mDNS sighting ranks only "possible", and Matter-firmware units
/// drop `_hap._tcp` entirely — and a LIFX-shaped answer is a strong, non-shared
/// identity. The synthetic search target below is what a matched device is keyed
/// on, mirrored by the spec's `identification.ssdp_search_targets`.
const _lifxPort = 56700;
const _lifxBroadcast = '255.255.255.255';
const _lifxSearchTarget = 'lifx:udp';

/// mDNS multicast group and port, for the raw source-capture listener that
/// backstops [MDnsClient] on devices whose SRV/A records do not resolve.
const _mdnsMulticast = '224.0.0.251';
const _mdnsPort = 5353;

/// Ubiquiti device discovery: a broadcast probe to UDP 10001 that every UniFi
/// device (cameras, APs, switches, gateways) answers with a TLV record. The
/// lan-protocol token the emitted device is tagged with, matched by the spec's
/// `identification.lan_protocols`.
const _ubiquitiPort = 10001;
const _ubiquitiProbe = [0x01, 0x00, 0x00, 0x00];
const _ubiquitiLanProtocol = 'ubiquiti-discovery';

/// MikroTik Neighbor Discovery (MNDP): RouterOS devices beacon a TLV record on
/// UDP 5678, and answer a 4-byte-zero solicitation by BROADCASTING it back to
/// :5678 (not unicast) — so the listener must BIND :5678, not send from an
/// ephemeral port. Tagged with the lan-protocol the spec declares.
const _mikrotikPort = 5678;
const _mikrotikProbe = [0x00, 0x00, 0x00, 0x00];
const _mikrotikLanProtocol = 'mikrotik-mndp';

/// The tagged-broadcast `GetService` probe (sequence 0). Byte-for-byte the
/// packet `crate::protocol::lifx::get_service(0)` builds. Discovery reads only a
/// reply's message type and 6-byte MAC, so it builds the probe and parses those
/// fields here in Dart rather than crossing the FFI for every datagram — exactly
/// as the SSDP and mDNS transports parse their own replies. A unit test pins the
/// bytes so the Dart and Rust builders cannot drift.
Uint8List lifxGetServiceProbe() {
  final packet = Uint8List(36);
  packet[0] = 36; // size (u16 LE): header only, no payload
  packet[2] = 0x00; // protocol | addressable | tagged = 0x3400 (u16 LE)
  packet[3] = 0x34;
  // source = "LBRG" (0x4C425247) little-endian, echoed in replies so a device's
  // answer can be told from another controller's traffic on the segment.
  packet[4] = 0x47;
  packet[5] = 0x52;
  packet[6] = 0x42;
  packet[7] = 0x4C;
  packet[22] = 0x01; // res_required
  packet[32] = 2; // message type: GetService
  return packet;
}

/// The device MAC from a `StateService` (type 3) reply, or null for any other
/// datagram. LIFX packs the 6-byte MAC into the header's target field at
/// offset 8.
String? lifxStateServiceMac(List<int> data) {
  if (data.length < 36) return null;
  final type = data[32] | (data[33] << 8);
  if (type != 3) return null;
  return data
      .sublist(8, 14)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(':');
}

/// TP-Link Kasa discovery: a directed broadcast of the XOR-encoded
/// get_sysinfo to UDP 9999, which only devices speaking the tplink-smarthome
/// protocol answer. The protocol token the answer identifies the device by.
const _kasaBroadcast = '255.255.255.255';
const _kasaPort = 9999;
const _kasaProbeJson = '{"system":{"get_sysinfo":null}}';
const _kasaProtocol = 'tplink-smarthome';

/// Parse an SSDP response into its headers, lowercased keys.
///
/// Tolerant on purpose: SSDP implementations in shipped hardware are famously
/// sloppy about line endings, header casing and trailing whitespace, and a
/// strict parser here would silently drop real devices.
Map<String, String> parseSsdpHeaders(String payload) {
  final headers = <String, String>{};
  for (final rawLine in payload.split(RegExp(r'\r\n|\n|\r'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    // The HTTP status line has no colon before its first space.
    final colon = line.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    if (key.isNotEmpty && value.isNotEmpty) headers[key] = value;
  }
  return headers;
}

/// Pull the host, port and path out of an SSDP `LOCATION` URL.
///
/// Returns null for anything unparseable — a device that advertises a
/// malformed location is not one we can do anything with. The path matters
/// as much as the address: it is where the UPnP device description lives,
/// and not every device calls it setup.xml (a Panasonic Viera answers with
/// /nrc/ddd.xml).
({String host, int? port, String path})? parseSsdpLocation(String? location) {
  if (location == null || location.isEmpty) return null;
  final uri = Uri.tryParse(location);
  if (uri == null || uri.host.isEmpty) return null;
  // `http://host/desc.xml` with no explicit port advertises the scheme
  // default, and `Uri.port` resolves it (80 for http, 443 for https);
  // it returns 0 only when the scheme has no default. Reporting null for
  // an implicit :80 made the control path refuse a device that stated
  // its port fine.
  return (
    host: uri.host,
    port: uri.port == 0 ? null : uri.port,
    path: uri.path.isEmpty ? '/' : uri.path,
  );
}

/// Turn an mDNS TXT record's entries into a map, lowercasing keys.
///
/// TXT entries are `key=value` strings; a bare key with no `=` is a flag, kept
/// with an empty value rather than dropped, because its presence is the signal.
Map<String, String> parseTxtRecord(Iterable<String> entries) {
  final txt = <String, String>{};
  for (final entry in entries) {
    final equals = entry.indexOf('=');
    if (equals < 0) {
      if (entry.isNotEmpty) txt[entry.toLowerCase()] = '';
      continue;
    }
    final key = entry.substring(0, equals).trim().toLowerCase();
    if (key.isNotEmpty) txt[key] = entry.substring(equals + 1);
  }
  return txt;
}

/// Strip the DNS-SD instance name off a full service instance, leaving the
/// service type: `Hue Bridge._hue._tcp.local` -> `_hue._tcp.local`.
String serviceTypeOf(String instance) {
  final match = RegExp(r'(_[^.]+\._(?:tcp|udp)\..+)$').firstMatch(instance);
  return match?.group(1) ?? instance;
}

/// The instance's own label: `Hue Bridge._hue._tcp.local` -> `Hue Bridge`.
String instanceNameOf(String instance) {
  final type = serviceTypeOf(instance);
  if (type == instance || !instance.endsWith(type)) return '';
  final name = instance.substring(0, instance.length - type.length);
  return name.endsWith('.') ? name.substring(0, name.length - 1) : name;
}

/// Normalize a spec's declared mDNS service type into the form a direct PTR
/// query wants, or null when it is not a usable DNS-SD service type.
///
/// Specs write the type with a trailing dot (`_snapmaker._tcp.local.`); the
/// meta-query's own records and the `resolving` dedup set carry it without one
/// (`_snapmaker._tcp.local`), so the trailing dot is stripped here to keep a
/// direct query from re-resolving a type the enumeration already found. A value
/// that is not shaped like a service type (`_label._tcp.` / `_label._udp.`) is
/// dropped rather than sent, so a malformed catalogue entry cannot turn into a
/// junk query.
String? normalizeMdnsServiceType(String raw) {
  var value = raw.trim();
  if (value.endsWith('.')) value = value.substring(0, value.length - 1);
  if (!RegExp(r'^_[^.]+\._(?:tcp|udp)\.').hasMatch(value)) return null;
  return value;
}

/// Build a raw mDNS PTR query datagram for a service type (`_snapmaker._tcp
/// .local`), used by the source-capture listener to prompt the responders.
List<int> mdnsPtrQuery(String serviceType) {
  final b = BytesBuilder();
  // Header: id 0, flags 0, qdcount 1, an/ns/ar 0.
  b.add(const [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final label in serviceType.split('.')) {
    if (label.isEmpty) continue;
    final bytes = utf8.encode(label);
    b.addByte(bytes.length);
    b.add(bytes);
  }
  b.addByte(0); // root label
  b.add(const [0, 12, 0, 1]); // QTYPE PTR, QCLASS IN
  return b.toBytes();
}

/// The first label of a service type as it appears on the wire (`_snapmaker`),
/// for a cheap substring test against a response datagram. Null when it is too
/// short to be a safe discriminator.
List<int>? mdnsFirstLabelBytes(String serviceType) {
  final first = serviceType.split('.').first;
  return first.length >= 3 ? utf8.encode(first) : null;
}

/// A per-device pictogram token worked out from the mDNS service types a device
/// advertises, for a category the shared spec match misses.
///
/// A printer that speaks only the legacy `_printer._tcp` (LPD) and
/// `_pdl-datastream._tcp` (JetDirect) types — an older Brother/HP laser with no
/// AirPrint — never matches the IPP spec, whose identification keys on
/// `_ipp._tcp`, so it would fall back to the router glyph. Keying the printer
/// pictogram off the service type instead draws it correctly regardless of the
/// match, the same way the Kasa/Ubiquiti transports set a device's glyph from
/// what it told us. Compared on the trimmed stem (no trailing dot, no `.local`)
/// so `_printer._tcp.local.` and `_printer._tcp` are the same entry.
String? mdnsPictogram(Iterable<String> serviceTypes) {
  const printerTypes = {
    '_ipp._tcp',
    '_ipps._tcp',
    '_printer._tcp',
    '_pdl-datastream._tcp',
  };
  for (final raw in serviceTypes) {
    var t = raw.trim().toLowerCase();
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    if (t.endsWith('.local')) t = t.substring(0, t.length - '.local'.length);
    if (printerTypes.contains(t)) return 'printer';
  }
  return null;
}

/// Parse a Ubiquiti discovery reply (UDP 10001) into hostname / MAC / platform.
///
/// Header: version(1) command(1) length(2 BE); then TLVs, each type(1)
/// length(2 BE) value. Known types: 0x01 = MAC (6 bytes), 0x0b = hostname,
/// 0x0c = platform/model string ("UVC G4 Pro", "ES-10X", "UFP-UAP-B…"). Only a
/// v1 (`0x01`) reply is parsed; anything else yields nothing.
({String? hostname, String? mac, String? platform}) parseUbiquitiDiscovery(
    List<int> data) {
  String? hostname, mac, platform;
  if (data.length < 4 || data[0] != 0x01) {
    return (hostname: null, mac: null, platform: null);
  }
  var i = 4;
  while (i + 3 <= data.length) {
    final type = data[i];
    final len = (data[i + 1] << 8) | data[i + 2];
    i += 3;
    if (i + len > data.length) break;
    final value = data.sublist(i, i + len);
    switch (type) {
      case 0x01:
        if (len == 6) {
          mac = value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
        }
      case 0x0b:
        final h = String.fromCharCodes(value).trim();
        if (h.isNotEmpty) hostname = h;
      case 0x0c:
        final p = String.fromCharCodes(value).trim();
        if (p.isNotEmpty) platform = p;
    }
    i += len;
  }
  return (hostname: hostname, mac: mac, platform: platform);
}

/// A pictogram token for a Ubiquiti device from its platform string (the 0x0c
/// TLV): a camera, an NVR, a switch, an AP, a gateway, etc. Null for an unknown
/// platform, so the device falls back to the generic UniFi spec's glyph. The
/// spec itself documents this platform->pictogram map; it lives here because
/// the platform is only known at discovery, from the wire.
String? ubiquitiPictogram(String? platform) {
  if (platform == null) return null;
  final p = platform.toUpperCase();
  if (p.startsWith('UVC') || p.contains('CAMERA')) {
    return p.contains('DOORBELL') ? 'video-doorbell' : 'ip-camera';
  }
  if (p.startsWith('UNVR')) return 'nvr';
  if (p.startsWith('UNAS')) return 'nas';
  if (p.startsWith('USW') || p.startsWith('US-') || p.startsWith('ES')) {
    return 'network-switch';
  }
  if (p.startsWith('UXG') || p.startsWith('UGW') || p.startsWith('UDR')) {
    return 'router';
  }
  if (p.startsWith('UDM') || p.startsWith('UCK')) return 'cloud-key';
  if (p.contains('UAP') || p.startsWith('U6') || p.startsWith('U7')) {
    return 'wifi-ap';
  }
  return null;
}

/// Parse a MikroTik MNDP datagram (UDP 5678) into identity / MAC / board /
/// version. A 4-byte header, then TLVs each type(2 BE) length(2 BE) value.
/// Wireshark's dissector: 0x0001 = MAC (6B), 0x0005 = Identity, 0x0007 =
/// Version, 0x000c = Board (model, e.g. CRS328, RB4011).
({String? identity, String? mac, String? board, String? version}) parseMndp(
    List<int> data) {
  String? identity, mac, board, version;
  if (data.length < 8) {
    return (identity: null, mac: null, board: null, version: null);
  }
  var i = 4;
  while (i + 4 <= data.length) {
    final type = (data[i] << 8) | data[i + 1];
    final len = (data[i + 2] << 8) | data[i + 3];
    i += 4;
    if (i + len > data.length) break;
    final value = data.sublist(i, i + len);
    switch (type) {
      case 0x0001:
        if (len == 6) {
          mac = value.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
        }
      case 0x0005:
        final s = String.fromCharCodes(value).trim();
        if (s.isNotEmpty) identity = s;
      case 0x0007:
        final s = String.fromCharCodes(value).trim();
        if (s.isNotEmpty) version = s;
      case 0x000c:
        final s = String.fromCharCodes(value).trim();
        if (s.isNotEmpty) board = s;
    }
    i += len;
  }
  return (identity: identity, mac: mac, board: board, version: version);
}

/// A pictogram token for a MikroTik device: RouterOS runs on routers and
/// switches alike, so a switch board (CRS/CSS/CSW) or a "switch"-named unit
/// gets `network-switch`; everything else defaults to `router`.
String mikrotikPictogram({String? board, String? identity}) {
  final s = '${board ?? ''} ${identity ?? ''}'.toUpperCase();
  if (s.contains('SWITCH') ||
      s.contains('CRS') ||
      s.contains('CSS') ||
      s.contains('CSW')) {
    return 'network-switch';
  }
  return 'router';
}

/// Whether [haystack] contains the contiguous byte sequence [needle].
bool containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// What one discovery transport managed to do in a scan window.
///
/// Three states rather than a bool because "the socket opened" and "anything
/// came back" are different facts, and only the second one tells a quiet
/// network apart from a blocked one.
enum TransportOutcome {
  /// Never got off the ground: the client or socket failed to start.
  failed,

  /// Started, and nothing at all arrived — not a device, not a stray packet.
  silent,

  /// Started and heard something, whether or not it became a device. A reply
  /// we could not parse still proves traffic reaches us.
  heard,
}

/// Decide what a finished scan means, or null when it means nothing is wrong.
///
/// Pure, so the rule can be tested without sockets, a network, or a platform.
///
/// The distinction that matters is between a network with nothing on it and a
/// network whose replies are dropped before they reach us. On iOS and macOS a
/// denied local-network permission is invisible from in here: the sockets bind,
/// the queries go out, and the answers are filtered silently. So silence on
/// those platforms earns a message that names that possibility and points at
/// Settings. Silence anywhere else is just an empty network and gets the
/// ordinary empty state — Android's multicast filtering is handled by holding a
/// multicast lock, not by guessing after the fact.
///
/// Deliberately not keyed off how many devices were found: a network can carry
/// plenty of mDNS traffic and no device we have a spec for, and calling that a
/// permission problem would be a confident lie in the other direction.
UserFacingException? scanFailureFor({
  required List<TransportOutcome> outcomes,
  required bool isApplePlatform,
}) {
  if (outcomes.every((o) => o == TransportOutcome.failed)) {
    // Neither transport started: a real, platform-independent failure — no
    // interface, no multicast route, no network.
    return const NetworkUnavailableException();
  }
  if (outcomes.any((o) => o == TransportOutcome.heard)) return null;
  return isApplePlatform ? const LocalNetworkDeniedException() : null;
}

/// Coalesces sightings so a device answering on several service types, or on
/// both mDNS and SSDP, is one row rather than four.
///
/// Mirrors `ScanResultCoalescer` on the BLE side, including its contract:
/// returns the merged device when something about it changed, and null when
/// this sighting added nothing.
class NetworkScanCoalescer {
  final Map<String, NetworkDevice> _seen = {};

  int get deviceCount => _seen.length;

  NetworkDevice? next(NetworkDevice sighting) {
    final previous = _seen[sighting.host];
    final merged = previous == null ? sighting : previous.mergedWith(sighting);
    // Store first, always. `hasSameIdentity` decides whether the ROW needs
    // redrawing; it deliberately ignores `sources` and `server`, which are not
    // identity. Returning early without storing threw those away permanently:
    // a host already known over mDNS that then answered SSDP kept showing
    // "mDNS" forever, because the merge carrying the second source was
    // discarded rather than remembered.
    final unchanged = previous != null && previous.hasSameIdentity(merged);
    _seen[sighting.host] = merged;
    return unchanged ? null : merged;
  }
}

/// Real local-network discovery: DNS-SD over mDNS, plus SSDP.
///
/// Both are run because they do not overlap. Modern local-first hardware
/// announces itself over mDNS and nothing else; Wemo and older Hue bridges are
/// SSDP-only. Running one would silently miss half the catalogue.
class RealNetworkScanService implements NetworkScanService {
  /// Held for the duration of a scan so Android's Wi-Fi driver stops filtering
  /// the multicast replies both transports depend on. Injectable so a test can
  /// assert the scan takes it and gives it back.
  final MulticastLock multicastLock;

  /// The spec codec, used only for the Kasa XOR cipher on the discovery
  /// datagram. Optional: without it the Kasa broadcast transport is skipped
  /// (mDNS and SSDP are unaffected), which is what the socket-level tests that
  /// construct this service directly rely on. Production wires the real codec
  /// through `networkScanServiceProvider`.
  final SpecCodec? codec;

  RealNetworkScanService({MulticastLock? multicastLock, this.codec})
      : multicastLock = multicastLock ?? MulticastLock();

  /// The scan currently entitled to the lock, or null between scans.
  ///
  /// Only ever compared by identity — a finishing scan checks whether it is
  /// still this one before releasing anything shared.
  _ScanSession? _session;

  @override
  Stream<NetworkDevice> scan({
    Duration timeout = const Duration(seconds: 8),
    List<String> extraSearchTargets = const [],
    List<String> extraMdnsServiceTypes = const [],
  }) {
    final controller = StreamController<NetworkDevice>();
    final coalescer = NetworkScanCoalescer();
    // Everything a scan has to be able to stop lives on the session, not on
    // the service. It used to live here, and one instance is shared through
    // `networkScanServiceProvider`: cancel a scan and start another, and the
    // first is still parked in _runMdns's post-enumeration delay (four seconds
    // at the default timeout). When it comes back its `finally` tore down
    // whatever it found on the fields — the *second* scan's mDNS client and
    // SSDP socket, its stopped flag, and the multicast lock it had just taken.
    // That scan then reported silent/silent, which on iOS and macOS is
    // rendered as "Local Network access is off" to a user whose permission was
    // never the problem.
    final session = _ScanSession();
    _session = session;

    void emit(NetworkDevice device) {
      if (controller.isClosed) return;
      final changed = coalescer.next(device);
      if (changed != null) controller.add(changed);
    }

    () async {
      try {
        // Before either transport starts, and released in the finally below:
        // without it Android delivers neither mDNS nor SSDP replies, so taking
        // it after the queries go out would be too late for the answers.
        await multicastLock.acquire();
        // Both halves run concurrently and are allowed to fail independently:
        // a platform that blocks one (iOS multicast entitlements, a network
        // with IGMP snooping) should still return what the other found.
        final codec = this.codec;
        final outcomes = await Future.wait([
          _runMdns(session, emit, timeout, extraMdnsServiceTypes)
              .catchError((Object e) {
            Log.net.warning('mDNS discovery failed', error: e);
            return TransportOutcome.failed;
          }),
          // A raw-socket backstop for devices that advertise a catalogue mDNS
          // type but publish no resolvable SRV/A (a Snapmaker U1): emits them at
          // the response's source IP. Best-effort — a bind clash returns silent.
          _runMdnsSourceCapture(session, emit, timeout, extraMdnsServiceTypes)
              .catchError((Object e) {
            Log.net.debug('mDNS source-capture failed: $e');
            return TransportOutcome.silent;
          }),
          _runSsdp(session, emit, timeout, extraSearchTargets)
              .catchError((Object e) {
            Log.net.warning('SSDP discovery failed', error: e);
            return TransportOutcome.failed;
          }),
          _runLifx(session, emit, timeout).catchError((Object e) {
            Log.net.warning('LIFX discovery failed', error: e);
            return TransportOutcome.failed;
          }),
          // Ubiquiti/UniFi devices answer only their own UDP 10001 probe — no
          // mDNS, no SSDP — so a whole fleet of cameras/APs/switches is silent
          // without this.
          _runUbiquiti(session, emit, timeout).catchError((Object e) {
            Log.net.warning('Ubiquiti discovery failed', error: e);
            return TransportOutcome.failed;
          }),
          // MikroTik RouterOS answers only MNDP on UDP 5678 (no mDNS/SSDP).
          _runMikrotik(session, emit, timeout).catchError((Object e) {
            Log.net.warning('MikroTik discovery failed', error: e);
            return TransportOutcome.failed;
          }),
          // The Kasa transport, when a codec is wired to run the cipher. Its
          // outcome joins the others, so a granted local-network permission
          // heard over broadcast counts the same as one heard over multicast.
          if (codec != null)
            _runKasa(session, emit, timeout, codec).catchError((Object e) {
              Log.net.warning('Kasa discovery failed', error: e);
              return TransportOutcome.failed;
            }),
        ]);

        final failure = scanFailureFor(
          outcomes: outcomes,
          isApplePlatform: Platform.isIOS || Platform.isMacOS,
        );
        if (failure != null) controller.addError(failure);
        Log.net.info('network scan finished: '
            '${coalescer.deviceCount} device(s)');
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        await _end(session);
        if (!controller.isClosed) await controller.close();
      }
    }();

    controller.onCancel = () => _end(session);
    return controller.stream;
  }

  /// Enumerate service types, then resolve each instance.
  ///
  /// Reports [TransportOutcome.heard] as soon as one record arrives, from
  /// either the enumeration or any resolution — the question the caller is
  /// asking is whether multicast reaches this app at all, and one record
  /// answers it. Records that resolve to nothing usable still count.
  Future<TransportOutcome> _runMdns(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
    List<String> extraServiceTypes,
  ) async {
    // The default factory is `RawDatagramSocket.bind`, which start() calls with
    // `reusePort: true` — a bind Android's bionic libc rejects with a
    // SocketException, so the whole mDNS half used to throw there and be lost
    // while SSDP/LIFX/Kasa (no reusePort) kept working. bindDatagramSocket tries
    // reusePort and falls back without it, so mDNS binds on Android too; the
    // multicast group join start() does after the bind is unchanged.
    final client = MDnsClient(rawDatagramSocketFactory: bindDatagramSocket);
    await client.start();
    session.mdns = client;
    var heard = false;
    // A direct-query resolution can be the only thing that hears anything (its
    // service type is deaf to the meta-query), so it has to be able to flip
    // `heard` too — otherwise a scan that found a device only that way would
    // still report `silent`, and on Apple that silence is rendered as a
    // local-network permission denial next to a device that was, in fact,
    // found.
    void markHeard() => heard = true;
    final resolving = <String>{};
    // `timeout` is the budget for the whole mDNS half, split between its two
    // phases: enumerate the link's service types, then resolve the instances
    // behind them. Both used to be given the full `timeout` and run back to
    // back, so an 8-second scan took twelve — the enumeration ran its window
    // out (it only closes early if every responder falls silent), and the
    // grace period for the resolutions was added on top of it.
    final phase = timeout ~/ 2;
    // `Stream.timeout` is an INACTIVITY timeout: every event resets it. On a
    // link where responders keep answering the meta-query inside the window —
    // which is what a busy network looks like — it never fires, the enumeration
    // never closes, `Future.wait` below never completes, and the scan stream
    // stays open forever with the spinner up and the button disabled. The
    // SSDP half has always had an absolute deadline for this reason; this one
    // did not, and the phase comment above claimed a budget it was not
    // keeping. Keep both: inactivity ends a quiet scan early, the deadline
    // bounds a chatty one.
    final deadline = DateTime.now().add(phase);
    try {
      // Ask for the catalogue's known service types by name, not only through
      // the `_services._dns-sd._udp.local` meta-query below. The meta-query
      // only surfaces a type whose responder answers that enumeration; a device
      // that answers a direct PTR for its own `_vendor._tcp` but is deaf to the
      // meta-query — or whose meta-query answer is lost, or lands after this
      // half's budget — is otherwise never resolved even though its exact type
      // is in a spec we hold. This is the mDNS twin of the SSDP extra search
      // targets (a Roku is deaf to `ssdp:all` and answers only its own ST); a
      // Snapmaker U1 is the case that motivated it, advertising `_snapmaker._tcp`
      // from an embedded responder the meta-query never drew out. Fired off
      // alongside the enumeration and deduped against it by `resolving`.
      for (final raw in extraServiceTypes) {
        final serviceType = normalizeMdnsServiceType(raw);
        if (serviceType == null || !resolving.add(serviceType)) continue;
        unawaited(_resolveServiceType(session, client, serviceType, emit, phase,
                onHeard: markHeard)
            .catchError((Object e) {
          Log.net.debug('mDNS direct resolve failed for $serviceType: $e');
        }));
      }
      await for (final PtrResourceRecord type in client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(_serviceEnumerationQuery),
              // lookup() has its own internal 5 s default that closes the
              // stream regardless of the .timeout below; pass the real
              // budget or a long scan is silently capped at 5 s.
              timeout: phase)
          .timeout(phase, onTimeout: (sink) => sink.close())) {
        heard = true;
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        // Once per type, not once per announcement. The meta-query is answered
        // by every responder on the link, so a common type like _http._tcp
        // arrives once per device; without this each arrival started another
        // full resolution of the same type, and multicast_dns fans every
        // incoming record to every pending lookup — so D duplicates cost D
        // queries and D^2 record deliveries.
        if (!resolving.add(type.domainName)) continue;
        // Fire the per-type resolution off rather than awaiting it: a slow or
        // unanswered service type must not hold up every other one.
        unawaited(_resolveServiceType(
                session, client, type.domainName, emit, phase,
                onHeard: markHeard)
            .catchError((Object e) {
          Log.net.debug('mDNS resolve failed for ${type.domainName}: $e');
        }));
      }
      // Give the fired-off resolutions the other half of the window — but wake
      // early if the scan is stopped.
      //
      // Unconditionally sleeping here made `stopScan()` a lie: the transports
      // shut down at once, but this half stayed parked, so `Future.wait` below
      // did not complete and the app-facing stream did not CLOSE for up to half
      // the scan window (thirty seconds at a one-minute timeout). A caller that
      // waits for the stream to end before re-enabling its button — which is
      // what "stop scanning" looks like from the UI — waits that long for a
      // scan that already stopped.
      await session.sleepUnlessStopped(phase);
      // No separate "heard during resolve" state: a resolution only ever
      // starts after the enumeration loop has already received a record, so
      // `heard` is necessarily true by then.
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      client.stop();
      session.mdns = null;
    }
  }

  /// Emit a device at the SOURCE address of any mDNS RESPONSE advertising a
  /// catalogue service type. Backstops [_runMdns]: a device can advertise its
  /// service type yet publish no resolvable SRV/A record — a Snapmaker U1
  /// answers no A query for its own hostname, so PTR->SRV->A never yields an
  /// address, yet the response came FROM the device and that source IS the
  /// address. The coalescer merges by host and [NetworkDevice.mergedWith]
  /// prefers a resolved row's name and SRV port, so this never degrades a
  /// normally-resolved device; it only rescues the ones the normal path drops.
  ///
  /// Binds :5353 with reusePort ONLY (no exclusive fallback): on a host that
  /// lacks reusePort (Android) it skips cleanly rather than stealing the port
  /// from [MDnsClient], whose bind must win. So this is a Linux/desktop/iOS
  /// backstop; where it cannot co-bind, the normal path still runs.
  Future<TransportOutcome> _runMdnsSourceCapture(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
    List<String> serviceTypes,
  ) async {
    // First label per type, for the substring test, keyed by the normalized
    // type we tag the emitted device with so it matches the spec.
    final labels = <String, List<int>>{};
    for (final raw in serviceTypes) {
      final type = normalizeMdnsServiceType(raw);
      final label = type == null ? null : mdnsFirstLabelBytes(type);
      if (type != null && label != null) labels[type] = label;
    }
    if (labels.isEmpty) return TransportOutcome.silent;

    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _mdnsPort,
          reuseAddress: true, reusePort: true);
    } catch (e) {
      // reusePort unsupported, or :5353 exclusively held — skip; the normal
      // mDNS path still runs. Not a failure the user should hear about.
      Log.net.debug('mDNS source-capture unavailable: $e');
      return TransportOutcome.silent;
    }
    session.mdnsCaptureSocket = socket;
    try {
      socket.joinMulticast(InternetAddress(_mdnsMulticast));
    } catch (_) {
      // The group is already joined by another socket on this host; membership
      // is shared, so this is safe to ignore.
    }

    var heard = false;
    final seen = <String>{};
    try {
      final target = InternetAddress(_mdnsMulticast);
      for (final raw in serviceTypes) {
        socket.send(mdnsPtrQuery(raw), target, _mdnsPort);
      }
      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null || datagram.data.length < 12) continue;
        // Responses only (QR bit in the DNS flags): a query — ours or another
        // host's — must not be minted into a device.
        if (datagram.data[2] & 0x80 == 0) continue;
        final host = datagram.address.address;
        for (final entry in labels.entries) {
          if (!containsBytes(datagram.data, entry.value)) continue;
          heard = true;
          // Once per (host, type) per scan — a device answers repeatedly.
          if (!seen.add('$host|${entry.key}')) continue;
          emit(NetworkDevice(
            host: host,
            name: '',
            serviceTypes: [entry.key],
            pictogram: mdnsPictogram([entry.key]),
            sources: const {NetworkDiscoverySource.mdns},
            discoveredAt: DateTime.now(),
          ));
        }
      }
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      socket.close();
      session.mdnsCaptureSocket = null;
    }
  }

  /// Broadcast the Ubiquiti discovery probe (UDP 10001) and collect the TLV
  /// replies. Every UniFi device — cameras, APs, switches, gateways — answers
  /// it, which is the only signal much of that gear gives on the LAN (no mDNS,
  /// no SSDP). Each reply becomes a device at its source IP, named by its
  /// hostname and tagged with [_ubiquitiLanProtocol] so the Ubiquiti spec (which
  /// declares the matching `lan_protocols`) claims it.
  Future<TransportOutcome> _runUbiquiti(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
  ) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
        reuseAddress: true);
    session.ubiquitiSocket = socket;
    socket.broadcastEnabled = true;
    var heard = false;
    final seen = <String>{};
    try {
      final target = InternetAddress(_lifxBroadcast);
      // Twice: UDP is lossy and a dropped probe means a camera never heard from.
      for (var attempt = 0; attempt < 2; attempt++) {
        socket.send(_ubiquitiProbe, target, _ubiquitiPort);
        if (await session
            .sleepUnlessStopped(const Duration(milliseconds: 250))) {
          break;
        }
      }
      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null) continue;
        final parsed = parseUbiquitiDiscovery(datagram.data);
        // A datagram that parsed nothing identifying is noise, not a device —
        // the same rule the SSDP transport applies. Logged so a device dropped
        // for an unrecognized reply shape is visible, not silent.
        if (parsed.mac == null && parsed.hostname == null) {
          Log.net.debug('rejected Ubiquiti :$_ubiquitiPort datagram from '
              '${datagram.address.address} (${datagram.data.length}B, '
              'no id parsed)');
          continue;
        }
        heard = true;
        final host = datagram.address.address;
        if (!seen.add(host)) continue;
        emit(NetworkDevice(
          host: host,
          name: parsed.hostname ?? '',
          answeredLanProtocols: const [_ubiquitiLanProtocol],
          pictogram: ubiquitiPictogram(parsed.platform),
          txt: {
            if (parsed.mac != null) 'mac': parsed.mac!,
            if (parsed.platform != null) 'platform': parsed.platform!,
          },
          sources: const {NetworkDiscoverySource.lanProbe},
          discoveredAt: DateTime.now(),
        ));
      }
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      socket.close();
      session.ubiquitiSocket = null;
    }
  }

  /// Discover MikroTik RouterOS devices over MNDP (UDP 5678). Must BIND :5678:
  /// a solicited device broadcasts its TLV beacon back to :5678, not to the
  /// sender's port, so a listener on an ephemeral port hears nothing. Each
  /// beacon becomes a device at its source IP, named by its Identity and tagged
  /// with [_mikrotikLanProtocol] so the RouterOS spec claims it.
  Future<TransportOutcome> _runMikrotik(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
  ) async {
    final RawDatagramSocket socket;
    try {
      socket = await bindDatagramSocket(InternetAddress.anyIPv4, _mikrotikPort,
          reuseAddress: true, reusePort: true);
    } catch (e) {
      // :5678 exclusively held, or the bind is otherwise refused — skip.
      Log.net.debug('MikroTik MNDP bind failed: $e');
      return TransportOutcome.silent;
    }
    session.mikrotikSocket = socket;
    socket.broadcastEnabled = true;
    var heard = false;
    final seen = <String>{};
    try {
      final target = InternetAddress(_lifxBroadcast);
      for (var attempt = 0; attempt < 2; attempt++) {
        socket.send(_mikrotikProbe, target, _mikrotikPort);
        if (await session
            .sleepUnlessStopped(const Duration(milliseconds: 250))) {
          break;
        }
      }
      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null) continue;
        final parsed = parseMndp(datagram.data);
        // Our own 4-byte solicitation echoes back; a real beacon carries an
        // identity or MAC. Logged (skipping our own 4-byte echo) so a genuine
        // beacon we failed to parse is visible.
        if (parsed.identity == null && parsed.mac == null) {
          if (datagram.data.length > 4) {
            Log.net.debug('rejected MikroTik MNDP datagram from '
                '${datagram.address.address} (${datagram.data.length}B, '
                'no id parsed)');
          }
          continue;
        }
        heard = true;
        final host = datagram.address.address;
        if (!seen.add(host)) continue;
        emit(NetworkDevice(
          host: host,
          name: parsed.identity ?? '',
          answeredLanProtocols: const [_mikrotikLanProtocol],
          pictogram: mikrotikPictogram(
              board: parsed.board, identity: parsed.identity),
          txt: {
            if (parsed.mac != null) 'mac': parsed.mac!,
            if (parsed.board != null) 'board': parsed.board!,
            if (parsed.version != null) 'version': parsed.version!,
          },
          sources: const {NetworkDiscoverySource.lanProbe},
          discoveredAt: DateTime.now(),
        ));
      }
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      socket.close();
      session.mikrotikSocket = null;
    }
  }

  Future<void> _resolveServiceType(
    _ScanSession session,
    MDnsClient client,
    String serviceType,
    void Function(NetworkDevice) emit,
    Duration timeout, {
    required void Function() onHeard,
  }) async {
    // Whether [client] can still be asked anything. These chains are fired off
    // and not awaited, and each stage carries its own inactivity timeout, so a
    // chain that began near the end of the enumeration phase is routinely
    // still mid-flight when _runMdns's finally stops the client. Asking a
    // stopped MDnsClient throws a StateError; a chain that has outlived its
    // client has nothing left to contribute and should just end.
    bool clientLive() => !session.stopped && identical(session.mdns, client);
    if (!clientLive()) return;
    await for (final PtrResourceRecord instance in client
        .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(serviceType),
            timeout: timeout)
        .timeout(timeout, onTimeout: (sink) => sink.close())) {
      if (!clientLive()) return;
      // A PTR answer for this type means a device answered — enough to settle
      // the "did anything reach us" question even before it resolves to a row,
      // and the only signal a direct-queried type deaf to the meta-query gives.
      onHeard();
      // TXT and SRV are independent queries; run them together. A device that
      // publishes no TXT record leaves that stream open until its timeout, and
      // awaiting it before even asking for SRV used to spend the whole
      // resolution window on the absent half. Emission still waits for both,
      // so a device is emitted once, with everything it said.
      final txt = <String, String>{};
      final srvRecords = <SrvResourceRecord>[];
      await Future.wait([
        () async {
          if (!clientLive()) return;
          await for (final TxtResourceRecord record in client
              .lookup<TxtResourceRecord>(
                  ResourceRecordQuery.text(instance.domainName),
                  timeout: timeout)
              .timeout(timeout, onTimeout: (sink) => sink.close())) {
            txt.addAll(parseTxtRecord(record.text.split(RegExp(r'[\r\n]+'))));
          }
        }(),
        () async {
          if (!clientLive()) return;
          await for (final SrvResourceRecord srv in client
              .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(instance.domainName),
                  timeout: timeout)
              .timeout(timeout, onTimeout: (sink) => sink.close())) {
            if (session.stopped) return;
            srvRecords.add(srv);
          }
        }(),
      ]);

      for (final srv in srvRecords) {
        if (!clientLive()) return;
        await for (final IPAddressResourceRecord address in client
            .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
                timeout: timeout)
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          emit(NetworkDevice(
            host: address.address.address,
            name: instanceNameOf(instance.domainName),
            hostname: srv.target,
            port: srv.port,
            serviceTypes: [serviceTypeOf(instance.domainName)],
            pictogram: mdnsPictogram([serviceTypeOf(instance.domainName)]),
            txt: txt,
            sources: const {NetworkDiscoverySource.mdns},
            discoveredAt: DateTime.now(),
          ));
        }
      }
    }
  }

  /// Multicast an M-SEARCH and collect the unicast replies.
  ///
  /// Any datagram counts as [TransportOutcome.heard], including one whose
  /// headers we cannot use: the caller is asking whether replies reach this app
  /// at all, and an unparseable reply still answers that yes.
  Future<TransportOutcome> _runSsdp(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
    List<String> extraSearchTargets,
  ) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
        reuseAddress: true);
    session.ssdpSocket = socket;
    socket.broadcastEnabled = true;
    var heard = false;
    try {
      // `ssdp:all` first — the standard question every conforming UPnP stack
      // answers — then each vendor target the catalogue declares. The extras
      // are not redundant politeness: a Roku answers only an M-SEARCH whose
      // ST is exactly `roku:ecp` and is deaf to `ssdp:all`, so without its
      // own question it does not exist. Conforming devices answer both and
      // are coalesced by host, so the duplicates cost packets, not rows.
      final targets = <String>{'ssdp:all', ...extraSearchTargets};
      final target = InternetAddress(_ssdpAddress);
      // Sent more than once: SSDP rides on UDP, and a dropped M-SEARCH means a
      // device that is simply never heard from.
      for (var attempt = 0; attempt < 2; attempt++) {
        for (final searchTarget in targets) {
          // MX is the maximum random delay a device waits before replying; it
          // spreads responses out to avoid a storm, so the listen window has
          // to be at least MX seconds or slow-answering devices are missed.
          final request = 'M-SEARCH * HTTP/1.1\r\n'
              'HOST: $_ssdpAddress:$_ssdpPort\r\n'
              'MAN: "ssdp:discover"\r\n'
              'MX: 3\r\n'
              'ST: $searchTarget\r\n'
              '\r\n';
          socket.send(request.codeUnits, target, _ssdpPort);
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null) continue;
        heard = true;
        final headers = parseSsdpHeaders(String.fromCharCodes(datagram.data));
        final location = parseSsdpLocation(headers['location']);
        final searchTarget = headers['st'] ?? headers['nt'];
        // A datagram none of whose headers parsed still counts as "heard"
        // (the port is live) but is not a device: emitting a row per
        // arbitrary packet lets one hostile responder mint an unbounded
        // device list out of noise.
        if (location == null &&
            searchTarget == null &&
            headers['server'] == null) {
          Log.net.debug('rejected SSDP datagram from '
              '${datagram.address.address} (no LOCATION/ST/SERVER)');
          continue;
        }
        // Prefer the LOCATION host: a device behind a proxy or on a second
        // interface answers from an address its own service does not live on.
        final host = location?.host ?? datagram.address.address;
        emit(NetworkDevice(
          host: host,
          name: '',
          port: location?.port,
          ssdpPort: location?.port,
          ssdpDescriptionPath: location?.path,
          ssdpTargets: [if (searchTarget != null) searchTarget],
          server: headers['server'],
          sources: const {NetworkDiscoverySource.ssdp},
          discoveredAt: DateTime.now(),
        ));
      }
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      socket.close();
      session.ssdpSocket = null;
    }
  }

  /// Broadcast a LIFX `GetService` and collect the `StateService` replies.
  ///
  /// The third discovery transport, alongside mDNS and SSDP. A LIFX-shaped
  /// answer identifies a device far more confidently than the shared
  /// `_hap._tcp` mDNS type it also advertises, and it is the only signal a
  /// Matter-firmware unit gives at all. Any datagram counts as
  /// [TransportOutcome.heard] — the question is whether replies reach this app —
  /// but only a `StateService` becomes a device row.
  Future<TransportOutcome> _runLifx(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
  ) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
        reuseAddress: true);
    session.lifxSocket = socket;
    socket.broadcastEnabled = true;
    var heard = false;
    try {
      final probe = lifxGetServiceProbe();
      final target = InternetAddress(_lifxBroadcast);
      // Sent more than once: UDP is lossy, and a dropped probe means a strip
      // that is simply never heard from.
      for (var attempt = 0; attempt < 2; attempt++) {
        socket.send(probe, target, _lifxPort);
        if (await session
            .sleepUnlessStopped(const Duration(milliseconds: 250))) {
          break;
        }
      }

      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null) continue;
        heard = true;
        final mac = lifxStateServiceMac(datagram.data);
        if (mac == null) continue;
        emit(NetworkDevice(
          host: datagram.address.address,
          name: '',
          port: _lifxPort,
          ssdpTargets: const [_lifxSearchTarget],
          txt: {'mac': mac},
          sources: const {NetworkDiscoverySource.ssdp},
          discoveredAt: DateTime.now(),
        ));
      }
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      socket.close();
      session.lifxSocket = null;
    }
  }

  /// Find TP-Link Kasa plugs by the protocol they answer.
  ///
  /// A directed broadcast of the XOR-encoded get_sysinfo to 255.255.255.255:9999
  /// — only a tplink-smarthome device replies, and the reply carries its full
  /// sysinfo. Structurally the SSDP half's twin (bind, broadcast, listen with an
  /// absolute deadline), but the cipher and the reply's JSON are the codec's and
  /// dart:convert's rather than SSDP's plaintext headers.
  Future<TransportOutcome> _runKasa(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
    SpecCodec codec,
  ) async {
    final probe = await codec.kasaEncryptDatagram(json: _kasaProbeJson);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
        reuseAddress: true);
    session.kasaSocket = socket;
    socket.broadcastEnabled = true;
    var heard = false;
    try {
      final target = InternetAddress(_kasaBroadcast);
      // Sent more than once: UDP, and a dropped probe is a plug never heard.
      for (var attempt = 0; attempt < 2; attempt++) {
        socket.send(probe, target, _kasaPort);
        if (await session
            .sleepUnlessStopped(const Duration(milliseconds: 250))) {
          break;
        }
      }

      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null) continue;
        // A reply on our ephemeral port means the broadcast reached a device
        // that answered — the permission question is settled whether or not
        // this particular datagram decodes.
        heard = true;
        final device = await _kasaDeviceFrom(datagram, codec);
        if (device != null) {
          emit(device);
        } else {
          // A reply reached us but did not decode to a Kasa get_sysinfo — a
          // non-Kasa service on :9999, or a shape we don't read. Logged so it
          // is not a silent drop.
          Log.net.debug('rejected Kasa :$_kasaPort datagram from '
              '${datagram.address.address} (${datagram.data.length}B, '
              'not a get_sysinfo reply)');
        }
      }
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      socket.close();
      session.kasaSocket = null;
    }
  }

  /// Build a device from a Kasa reply datagram, or null when it does not decode
  /// to a get_sysinfo answer (stray UDP noise on the port).
  Future<NetworkDevice?> _kasaDeviceFrom(
      Datagram datagram, SpecCodec codec) async {
    final String json;
    try {
      json = await codec.kasaDecodeDatagram(datagram: datagram.data);
    } catch (_) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final system = decoded['system'];
    final sysinfo = system is Map ? system['get_sysinfo'] : null;
    if (sysinfo is! Map) return null;

    String? str(String key) {
      final value = sysinfo[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final alias = str('alias');
    final model = str('model');
    final mac = str('mac') ?? str('mic_mac');
    final deviceId = str('deviceId');
    // A finer glyph than the shared spec's `switch` category: a Kasa bulb
    // reports mic_type IOT.SMARTBULB, a power strip a `children` array.
    final micType = str('mic_type') ?? str('type');
    final children = sysinfo['children'];
    final String? pictogram;
    if (micType != null && micType.toUpperCase().contains('SMARTBULB')) {
      pictogram = 'light';
    } else if (children is List && children.isNotEmpty) {
      pictogram = 'power-strip';
    } else {
      pictogram = null;
    }
    return NetworkDevice(
      host: datagram.address.address,
      // The user's own name for the plug, falling back to the model.
      name: alias ?? model ?? '',
      port: _kasaPort,
      answeredLanProtocols: const [_kasaProtocol],
      pictogram: pictogram,
      txt: {
        if (model != null) 'model': model,
        if (mac != null) 'mac': mac,
        if (deviceId != null) 'deviceId': deviceId,
      },
      sources: const {NetworkDiscoverySource.lanProbe},
      discoveredAt: DateTime.now(),
    );
  }

  /// End [session]: stop its transports, and give the multicast lock back if
  /// it is still the session holding it.
  ///
  /// Every path out of a scan runs this — normal finish, cancel, error, and
  /// [stopScan] — which is what keeps the lock from outliving the scan that
  /// took it. Holding it costs battery for the whole device, not just this app.
  ///
  /// The identity check is what stops a late finisher from disarming a live
  /// scan: the lock is a single platform-wide flag with no reference counting,
  /// so releasing one an overlapping scan is relying on silences it outright.
  /// Whichever session is current took the lock last and will release it when
  /// its own turn comes.
  Future<void> _end(_ScanSession session) async {
    session.stop();
    if (!identical(_session, session)) return;
    _session = null;
    await multicastLock.release();
  }

  @override
  Future<void> stopScan() async {
    final session = _session;
    if (session != null) await _end(session);
  }
}

/// One scan's disposable state.
///
/// Exists so that stopping a scan stops *that* scan. These were fields on the
/// service, and `networkScanServiceProvider` hands out a single shared
/// instance, so an overlapping pair fought over them.
class _ScanSession {
  MDnsClient? mdns;
  RawDatagramSocket? ssdpSocket;
  RawDatagramSocket? lifxSocket;
  RawDatagramSocket? kasaSocket;
  RawDatagramSocket? mdnsCaptureSocket;
  RawDatagramSocket? ubiquitiSocket;
  RawDatagramSocket? mikrotikSocket;

  /// The interruptible-wait mechanism, shared with the mock service: a wait
  /// races [whenStopped] rather than only checking a flag at its ends — a
  /// transport parked in a delay never looks at a flag.
  final StopSignal _stop = StopSignal();

  bool get stopped => _stop.stopped;

  /// Completes when [stop] is called, so a wait can be cut short.
  Future<void> get whenStopped => _stop.whenStopped;

  /// Waits [duration], or until [stop] is called. True when stopped.
  Future<bool> sleepUnlessStopped(Duration duration) => _stop.sleep(duration);

  void stop() {
    // Idempotent (StopSignal guards the complete): every path out of a scan
    // calls this, and cancel-then-finish calls it twice.
    _stop.stop();
    mdns?.stop();
    mdns = null;
    ssdpSocket?.close();
    ssdpSocket = null;
    lifxSocket?.close();
    lifxSocket = null;
    kasaSocket?.close();
    kasaSocket = null;
    mdnsCaptureSocket?.close();
    mdnsCaptureSocket = null;
    ubiquitiSocket?.close();
    ubiquitiSocket = null;
    mikrotikSocket?.close();
    mikrotikSocket = null;
  }
}
