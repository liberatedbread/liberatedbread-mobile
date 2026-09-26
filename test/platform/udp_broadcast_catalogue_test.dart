// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Cross-checks the UDP probes the scan actually sends against the
// `discovery.methods[].udp_broadcast` blocks the bundled catalogue declares.
//
// Both directions, because both have a silent failure:
//
//   * A spec declaring a method nothing performs is a device that simply never
//     appears. Nothing logs it — the scan finishes, reports what it heard, and
//     the device was never asked. That is how a Mi-Light bridge and a Synology
//     NAS have been undiscoverable while their specs described exactly how to
//     find them.
//   * A probe with no spec behind it is a datagram this app puts on somebody's
//     LAN for a device the catalogue cannot describe, control or name. Not
//     harmful, but it is a fact about this app that should be written down
//     somewhere, and here is somewhere.
//
// Coverage is keyed on (port, response_format) and not on the port alone,
// which is the whole reason the Synology gap was invisible: its TLV beacon
// arrives on :9999, the port the Kasa probe already uses for an unrelated
// request/response protocol, so a port-level check reads as covered while
// nothing can hear the NAS.
//
// Same shape as ios_bonjour_catalogue_test — a closed table in code facing an
// open declaration in the schema, checked by reading the catalogue rather than
// by remembering. The block is machine-readable (port, probe bytes, whether
// the device beacons unprompted, what shape the reply takes) and until this
// test existed nothing read it at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _devicesDir = 'vendor/protocol-specs/device-specs/devices';

/// The transport that actually sends these datagrams, and the source of truth
/// for which ports it sends them on.
const String _scanService = 'lib/services/real_network_scan_service.dart';

/// One `udp_broadcast` method as the catalogue declares it.
class _Declared {
  final String spec;
  final int port;

  /// `tlv`, `json`, `json_xor`, `json_aes`, … or null where the spec states
  /// none — a Mi-Light bridge answers a comma-separated ASCII line the schema
  /// has no name for.
  final String? responseFormat;
  final bool passiveOk;

  const _Declared(this.spec, this.port, this.responseFormat, this.passiveOk);

  /// What a listener has to be able to do: bind this port and read THIS shape.
  String get exchange => '$port/${responseFormat ?? 'unspecified'}';

  @override
  String toString() =>
      '$spec: :$port ${responseFormat ?? '(no format)'}'
      '${passiveOk ? ' passive' : ''}';
}

/// The UDP exchanges `RealNetworkScanService` actually performs, as
/// `port/format` — the same key a declared method reduces to.
///
/// Kept beside the transports it describes: a new `_runX` that puts a datagram
/// on the wire belongs here the same day.
const Map<String, String> _performed = {
  '10001/tlv': 'Ubiquiti device discovery (_runUbiquiti)',
  '5678/tlv': 'MikroTik MNDP (_runMikrotik)',
  '5678/json': 'iRobot, on the port MNDP shares (_runRoomba, _runMikrotik)',
  '9999/json_xor': 'TP-Link Kasa (_runKasa)',
  '6666/json': 'Tuya plaintext beacon (_runTuya)',
  '6667/json_aes': 'Tuya AES beacon (_runTuya)',
  '1982/http':
      'Yeelight `wifi_bulb` M-SEARCH to the :1982 multicast group '
      '(_runYeelight)',
  '4001/json':
      'Govee LAN `scan` to the :4001 multicast group, answered on :4002 '
      '(_runGovee)',
};

/// Probes with no `udp_broadcast` block behind them, keyed by port, each for a
/// stated reason. These are exchanges this app performs that the catalogue
/// does not describe as one.
const Map<int, String> _undeclared = {
  38899:
      'wiz-wifi-light.yaml declares only `mdns` on this port. WiZ bulbs are '
      'not mDNS-discoverable in practice; the working route is the UDP '
      'getSystemConfig broadcast this app sends. The spec is incomplete, not '
      'this transport.',
  4002:
      'The Govee reply port. govee-rgbic-light.yaml declares it — as the '
      '`listen_port` of its :4001 probe — but nothing is sent TO it, so it '
      'is not a probe port of its own.',
  3671: 'No KNX spec exists in the catalogue at all.',
  56700:
      'lifx-z.yaml describes the binary LAN protocol, but its discovery is '
      'a `lan_protocols` tag rather than a udp_broadcast block — a LIFX probe '
      'is a binary frame, not a datagram this block could describe.',
};

/// The port constants in the scan service that are NOT a probe of this app's
/// own, and why — the only hand-maintained half of [_portsProbed].
///
/// Everything else the service declares is a port it puts a datagram on, so it
/// has to be explained by a spec or by [_undeclared].
const Map<String, String> _notAProbe = {
  '_ssdpPort':
      'The standard SSDP port. An M-SEARCH to 239.255.255.250:1900 is the '
      'ssdp discovery method, declared by specs as `ssdp` — not a '
      'udp_broadcast exchange, and covered by ios_bonjour/ssdp checks '
      'elsewhere.',
  '_mdnsPort':
      'The standard mDNS port. Same argument: `mdns` methods, not '
      'udp_broadcast ones.',
  '_roombaControlPort':
      'The robot MQTT control port, reached AFTER discovery with credentials '
      'in hand. Nothing is broadcast to it.',
};

/// Every port this app broadcasts on, whether or not a spec declares it, read
/// out of the transport that broadcasts on it.
///
/// Derived, not retyped. This was a hand-copied list of eleven integers beside
/// a file that declares them — so a new `_fooPort` and the `_runFoo` that
/// sends to it were a datagram on somebody's LAN that this check would have
/// called explained, because the list it compared against did not know the
/// port existed. Now adding a port constant to the service adds it here, and
/// the test below is what makes the reader's failure loud rather than empty.
Set<int> _portsProbed() {
  final source = File(_scanService).readAsStringSync();
  final constant = RegExp(
    r'''^const\s+(_\w*[Pp]ort\w*)\s*=\s*(\d+)\s*;''',
    multiLine: true,
  );
  final found = <String, int>{};
  for (final match in constant.allMatches(source)) {
    found[match.group(1)!] = int.parse(match.group(2)!);
  }
  expect(
    found,
    hasLength(greaterThanOrEqualTo(12)),
    reason:
        '$_scanService should declare its UDP ports as `const _fooPort = N;` '
        'at the top level. Finding almost none means this reader has stopped '
        'matching and every check below it is vacuous.',
  );
  for (final name in _notAProbe.keys) {
    expect(
      found,
      contains(name),
      reason:
          '$name is excused from the probe list and $_scanService no longer '
          'declares it — delete the _notAProbe entry',
    );
  }
  return {
    for (final entry in found.entries)
      if (!_notAProbe.containsKey(entry.key)) entry.value,
  };
}

/// Declared exchanges no transport performs, each with what it would take.
///
/// A backlog, not an exemption list: every entry is a device whose spec says
/// how to find it and which this app therefore cannot find. Delete a line by
/// writing the transport.
const Map<String, String> _notPerformed = {
  '48899/unspecified':
      'limitlessled-milight-bridge.yaml. WRITEABLE TODAY: the spec carries '
      'both probe strings ("HF-A11ASSISTHREAD", "Link_Wi-Fi"), the reply '
      'shape (`ip,mac,module`, verified live) and the field positions. It '
      'needs a transport, and the spec needs a `lan_protocols` token for '
      'the found bridge to be matched to it — without one a discovered '
      'bridge appears as an unidentified host. The schema also has no '
      '`response_format` value for ASCII CSV, which is why this key reads '
      '`unspecified`.',
  '9999/tlv':
      'synology-diskstation.yaml. NOT writeable from the spec as it stands: it '
      'says `response_format: tlv` and names `tlv:mac`, `tlv:serial`, '
      '`tlv:hostname`, but never gives the framing or the field numbers, '
      'so a parser would be guessing the wire format. Needs a capture '
      'upstream first. (It would also need a listener BOUND to 9999 — not '
      'the ephemeral socket the Kasa probe sends from — dispatching by '
      'reply shape the way :5678 already does.)',
  '6666/json_aes':
      'tuya-wifi-gas-sensor.yaml declares 6666 as AES where '
      'tuya-generic-device.yaml declares it plaintext. The transport '
      'decodes 6666 as plaintext and 6667 as AES, per the generic spec and '
      'every published client. One of the two specs is wrong; until that is '
      'settled upstream, a gas sensor beaconing AES on 6666 is dropped.',
  '9090/binary':
      'led-space.yaml. Reachable only on the panel\'s own setup network (its '
      '"YS…" access point, gateway 192.168.4.1), so this is an adoption-time '
      'exchange rather than a LAN scan. The probe is a TLV '
      '`{"cmd":{"get":"dev_info"}}` frame whose sequence number and checksum '
      'change per send, which the spec gives as a builder in '
      '`protocol_details` rather than fixed `probe_hex` — a transport needs '
      'that builder, and the adopt flow needs to know the panel.',
  '10008/unspecified':
      'aqara-hub.yaml. A multicast "whois"/"iam" exchange: send plaintext JSON '
      'to the group 230.0.0.1:10008 carrying this host\'s IP and a listen '
      'port, then read the plaintext-JSON "iam" array the hub unicasts '
      'back. Needs a transport this app does not have — a multicast SEND to '
      'a group (not the subnet broadcast the other probes use) plus a bound '
      'listen socket for the reply — and the spec declares no '
      '`response_format` (the schema has no value for a bare JSON array), '
      'so this key reads `unspecified`. The hub\'s mDNS method '
      '(also declared) is the discovery path that works today.',
};

/// Ports carrying more than one protocol, and how the listener tells them
/// apart. A port that gains a second reply format without gaining a
/// dispatcher decodes one of them wrong — and a beacon that fails to decode is
/// dropped in silence.
const Map<int, String> _sharedPorts = {
  5678:
      'MNDP (binary TLV) and iRobot (JSON) share this port. _runMikrotik '
      'binds it and dispatches by reply SHAPE: parseMndp first, then '
      'parseIrobotReply, and an unrecognised datagram is logged rather than '
      'guessed at.',
  9999:
      'Kasa (XOR-ciphered JSON, request/response) and Synology (TLV beacon). '
      'NOT yet dispatched — see the 9999/tlv entry in _notPerformed. The Kasa '
      'probe sends from an ephemeral socket, so a broadcast beacon to :9999 '
      'reaches nothing here rather than being misread.',
  6666:
      'Two specs disagree about this one rather than two protocols sharing '
      'it — see the 6666/json_aes entry in _notPerformed.',
};

List<_Declared> _declaredMethods() {
  final directory = Directory(_devicesDir);
  expect(
    directory.existsSync(),
    isTrue,
    reason: '$_devicesDir should be a vendored subtree of protocol-specs',
  );

  // The `device:` block only, for the reason the Bonjour test gives: a port
  // under `evidence:` or `protocol_details:` is a record of what a capture
  // once saw, not an instruction to go looking.
  final deviceBlock = RegExp(r'^device:\n(?:[ \t].*\n|\n)*', multiLine: true);
  // The body is the `udp_broadcast:` mapping and nothing after it, so the
  // capture stops at the first line indented no further than the key itself.
  // It used to accept any line indented two-plus spaces, which swallowed the
  // rest of the `device:` block — 312 lines on irobot-roomba — so `allMatches`
  // found at most ONE method per file. Two specs declare two each, and the
  // one that went missing was tuya-generic-device's `6666/json`: precisely the
  // entry that reveals port 6666 carrying two reply formats, which is the
  // conflict this file's own backlog documents.
  final method = RegExp(
    r'''^(\s*)-?\s*type:\s*["']?udp_broadcast["']?\s*\n'''
    r'''\s*udp_broadcast:\s*\n((?:\1\s+\S.*\n|[ \t]*\n)*)''',
    multiLine: true,
  );
  final port = RegExp(r'''^\s*port:\s*(\d+)''', multiLine: true);
  final format = RegExp(
    r'''^\s*response_format:\s*["']?(\w+)''',
    multiLine: true,
  );
  final passive = RegExp(
    r'''^\s*passive_ok:\s*(true|false)''',
    multiLine: true,
  );

  final out = <_Declared>[];
  for (final entity in directory.listSync()) {
    if (entity is! File || !entity.path.endsWith('.yaml')) continue;
    final name = entity.uri.pathSegments.last;
    final device = deviceBlock.firstMatch(entity.readAsStringSync())?.group(0);
    if (device == null) continue;
    for (final match in method.allMatches(device)) {
      final body = match.group(2)!;
      final declaredPort = port.firstMatch(body)?.group(1);
      if (declaredPort == null) continue;
      out.add(
        _Declared(
          name,
          int.parse(declaredPort),
          format.firstMatch(body)?.group(1),
          passive.firstMatch(body)?.group(1) == 'true',
        ),
      );
    }
  }
  return out;
}

void main() {
  test('the catalogue still declares udp_broadcast methods to check', () {
    // A regex that silently stops matching would make every assertion below
    // vacuously true — the failure mode a derived allow-list has to be
    // defended against.
    final declared = _declaredMethods();
    // The real count, not a floor that happens to sit at what a broken
    // derivation returned: the regex under-counted to exactly 9 while this
    // said `>= 9`, so the guard agreed with the bug. Two specs declare two
    // methods each.
    expect(
      declared,
      hasLength(greaterThanOrEqualTo(11)),
      reason: 'the catalogue declares 11 udp_broadcast methods',
    );
    expect(
      declared.where((d) => d.spec == 'tuya-generic-device.yaml'),
      hasLength(2),
      reason: 'a spec declaring two methods must yield two',
    );
    expect(
      declared.map((d) => d.port).toSet(),
      containsAll(<int>[10001, 5678, 9999, 6666, 6667]),
    );
  });

  test(
    'every declared udp_broadcast method is performed or listed as backlog',
    () {
      final unreachable = <String>[];
      for (final declared in _declaredMethods()) {
        if (_performed.containsKey(declared.exchange)) continue;
        if (_notPerformed.containsKey(declared.exchange)) continue;
        unreachable.add('${declared.exchange} — $declared');
      }
      expect(
        unreachable,
        isEmpty,
        reason:
            'these specs say how to find the device and nothing asks. Either '
            'add the transport to RealNetworkScanService and its exchange to '
            '_performed, or record why not in _notPerformed:\n'
            '  ${unreachable.join('\n  ')}',
      );
    },
  );

  test('the probe ports are still readable out of the scan service', () {
    // The reader, before anything leans on it: a regex that stops matching
    // makes both checks below pass over an empty set.
    final probed = _portsProbed();
    expect(
      probed,
      containsAll(<int>[10001, 5678, 9999, 6666, 6667, 38899, 1982, 56700]),
      reason:
          'these are the ports $_scanService broadcasts on; a reader that '
          'cannot find them is not checking anything',
    );
    expect(
      probed,
      isNot(contains(1900)),
      reason: 'SSDP :1900 is an `ssdp` method, not a udp_broadcast probe',
    );
    expect(
      probed,
      isNot(contains(5353)),
      reason: 'mDNS :5353 is an `mdns` method, not a udp_broadcast probe',
    );
  });

  test('every UDP probe this app sends is declared somewhere', () {
    final declaredPorts = {for (final d in _declaredMethods()) d.port};
    final unexplained = <String>[];
    for (final port in _portsProbed()) {
      if (declaredPorts.contains(port)) continue;
      if (_undeclared.containsKey(port)) continue;
      unexplained.add(':$port');
    }
    expect(
      unexplained,
      isEmpty,
      reason:
          'this app broadcasts on these ports and no spec says why. Write '
          'the spec, or record the reason in _undeclared:\n'
          '  ${unexplained.join('\n  ')}',
    );
  });

  test('a port carrying two protocols says how they are told apart', () {
    final formats = <int, Set<String>>{};
    for (final declared in _declaredMethods()) {
      formats
          .putIfAbsent(declared.port, () => {})
          .add(declared.responseFormat ?? 'unspecified');
    }
    final undispatched = <String>[];
    formats.forEach((port, shapes) {
      if (shapes.length < 2) return;
      if (_sharedPorts.containsKey(port)) return;
      undispatched.add(':$port carries $shapes');
    });
    expect(
      undispatched,
      isEmpty,
      reason:
          'a listener bound to one of these decodes the other wrong, and '
          'a beacon that fails to decode is dropped in silence. Say how the '
          'transport tells them apart in _sharedPorts:\n'
          '  ${undispatched.join('\n  ')}',
    );
  });

  test('every backlog and exception entry still describes a real gap', () {
    // So a line does not outlive what it describes.
    final declared = _declaredMethods();
    final exchanges = {for (final d in declared) d.exchange};
    final ports = {for (final d in declared) d.port};

    for (final exchange in _notPerformed.keys) {
      expect(
        exchanges,
        contains(exchange),
        reason:
            '$exchange is listed as an unperformed udp_broadcast '
            'exchange and the catalogue no longer declares it — delete the '
            'entry',
      );
      expect(
        _performed,
        isNot(contains(exchange)),
        reason:
            '$exchange is both performed and listed as backlog — delete '
            'the _notPerformed entry',
      );
    }
    final probed = _portsProbed();
    for (final port in _undeclared.keys) {
      expect(
        probed,
        contains(port),
        reason:
            ':$port is explained as undeclared and nothing probes it — '
            'delete the entry',
      );
      expect(
        ports,
        isNot(contains(port)),
        reason:
            ':$port is declared by a spec now — delete its _undeclared '
            'entry',
      );
    }
    for (final port in _sharedPorts.keys) {
      expect(
        ports,
        contains(port),
        reason:
            ':$port is described as shared and no spec declares it — '
            'delete the entry',
      );
    }
  });
}
