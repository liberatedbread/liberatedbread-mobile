// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The interface-selection filter discovery uses to keep its multicast joins
// and probes off the cellular/VPN/peer-radio interfaces (F-014, F-049).
//
// Worth testing at this level because the failure it prevents is invisible on
// a laptop and only shows on a phone: an iPhone whose Wi-Fi has no internet
// makes cellular primary, and every probe leaves over pdp_ip0. There is no way
// to reproduce that on a CI host, so the filter is fed fabricated interfaces
// here and checked directly, rather than against whatever the machine has.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/network_interfaces.dart';

class _FakeInterface implements NetworkInterface {
  @override
  final String name;
  @override
  final List<InternetAddress> addresses;
  @override
  final int index;

  _FakeInterface(this.name, List<String> addresses, {this.index = 0})
    : addresses = addresses.map(InternetAddress.new).toList();
}

/// An [InterfaceLister] over [all] that mimics `NetworkInterface.list`: it
/// applies the loopback / link-local / type filters and, like the real one,
/// returns only interfaces left with at least one matching address.
InterfaceLister _listerOf(List<NetworkInterface> all) =>
    ({
      bool includeLoopback = false,
      bool includeLinkLocal = false,
      InternetAddressType type = InternetAddressType.any,
    }) async {
      final out = <NetworkInterface>[];
      for (final iface in all) {
        final addrs = iface.addresses.where((a) {
          if (!includeLoopback && a.isLoopback) return false;
          if (!includeLinkLocal && a.isLinkLocal) return false;
          if (type != InternetAddressType.any && a.type != type) return false;
          return true;
        }).toList();
        if (addrs.isEmpty) continue;
        out.add(
          _FakeInterface(
            iface.name,
            addrs.map((a) => a.address).toList(),
            index: iface.index,
          ),
        );
      }
      return out;
    };

void main() {
  group('isLanCandidate', () {
    test('drops the tunnel/cellular/peer-radio families by name', () {
      for (final name in [
        'utun0',
        'utun3',
        'pdp_ip0',
        // Android cellular. Carriers hand these RFC1918 addresses, so
        // isPrivateIpv4 accepts them and only the name keeps them out.
        'rmnet_data0',
        'v4-rmnet_data0',
        'ccmni0',
        'wwan0',
        'clat4',
        'ppp0',
        'ipsec0',
        'tun0',
        'tap0',
        'awdl0',
        'llw0',
      ]) {
        expect(
          isLanCandidate(_FakeInterface(name, ['10.0.0.5'])),
          isFalse,
          reason: '$name is never a LAN interface',
        );
      }
    });

    test('keeps a normal LAN interface with a routable address', () {
      expect(isLanCandidate(_FakeInterface('en0', ['192.168.1.5'])), isTrue);
      expect(isLanCandidate(_FakeInterface('eth0', ['10.0.0.5'])), isTrue);
    });

    test('drops an interface whose only address is link-local', () {
      expect(isLanCandidate(_FakeInterface('en5', ['169.254.10.10'])), isFalse);
    });

    test('loopback is kept only when asked for', () {
      final lo = _FakeInterface('lo0', ['127.0.0.1']);
      expect(isLanCandidate(lo), isFalse);
      expect(isLanCandidate(lo, includeLoopback: true), isTrue);
    });
  });

  group('lanInterfaces', () {
    test('drops utun*/pdp_ip*/lo0/link-local-only, keeps en0', () async {
      final lister = _listerOf([
        _FakeInterface('lo0', ['127.0.0.1']),
        _FakeInterface('en0', ['192.168.1.5']),
        _FakeInterface('utun2', ['10.8.0.2']), // VPN
        _FakeInterface('pdp_ip0', ['10.20.30.40']), // cellular
        _FakeInterface('awdl0', ['169.254.5.5']), // peer radio, link-local
      ]);

      final result = await lanInterfaces(
        InternetAddressType.IPv4,
        lister: lister,
      );
      expect(result.map((i) => i.name), ['en0']);
    });

    test('keeps loopback when asked (the mDNS test-rig path)', () async {
      final lister = _listerOf([
        _FakeInterface('lo0', ['127.0.0.1']),
        _FakeInterface('en0', ['192.168.1.5']),
        _FakeInterface('utun2', ['10.8.0.2']),
      ]);

      final result = await lanInterfaces(
        InternetAddressType.IPv4,
        lister: lister,
        includeLoopback: true,
      );
      expect(result.map((i) => i.name), containsAll(['lo0', 'en0']));
      expect(result.map((i) => i.name), isNot(contains('utun2')));
    });

    test('falls back to the unfiltered list when nothing qualifies', () async {
      // A host with only a VPN default route: joining/sending on it beats
      // being deaf, so the filter yields to it rather than returning nothing.
      final lister = _listerOf([
        _FakeInterface('utun2', ['10.8.0.2']),
      ]);

      final result = await lanInterfaces(
        InternetAddressType.IPv4,
        lister: lister,
      );
      expect(result.map((i) => i.name), ['utun2']);
    });
  });

  group('primaryLanIpv4', () {
    test('is the routable IPv4 of the chosen LAN interface', () async {
      final lister = _listerOf([
        _FakeInterface('lo0', ['127.0.0.1']),
        _FakeInterface('en0', ['192.168.1.5']),
        _FakeInterface('pdp_ip0', ['10.20.30.40']),
      ]);

      final addr = await primaryLanIpv4(lister: lister);
      expect(addr?.address, '192.168.1.5');
    });

    test('prefers a private address over a public one', () async {
      // A VPN with a public address that slipped the name filter must not win
      // over the real LAN.
      final lister = _listerOf([
        _FakeInterface('en5', ['203.0.113.7']), // public
        _FakeInterface('en0', ['192.168.1.5']), // private LAN
      ]);

      final addr = await primaryLanIpv4(lister: lister);
      expect(addr?.address, '192.168.1.5');
    });

    test('is null when there is no interface at all', () async {
      final addr = await primaryLanIpv4(lister: _listerOf([]));
      expect(addr, isNull);
    });

    test(
      'is not the Android cellular address, even enumerated first',
      () async {
        // The ordering is the point: a carrier's rmnet address is private, so
        // isPrivateIpv4 accepts it, and whichever interface the OS lists first
        // wins. Android enumerating cellular ahead of wlan0 would otherwise
        // pin IP_MULTICAST_IF — and with it the mDNS client, the mDNS source
        // capture, SSDP, the catalogue UDP probes, Yeelight, KNX and Govee —
        // to a radio no LAN device can hear.
        //
        // Every name in [tunnelInterfacePrefixes]' Android group, so a prefix
        // that only ever reaches the isLanCandidate test above cannot pass
        // there and still win the egress pick here.
        for (final cellular in [
          'rmnet_data0',
          'v4-rmnet_data0',
          'ccmni0',
          'wwan0',
          'clat4',
        ]) {
          final addr = await primaryLanIpv4(
            lister: _listerOf([
              _FakeInterface(cellular, ['10.171.4.9']),
              _FakeInterface('wlan0', ['192.168.1.5']),
            ]),
          );
          expect(addr?.address, '192.168.1.5', reason: '$cellular must lose');
        }
      },
    );

    test(
      'is null on a multi-homed host: two LAN interfaces is no answer',
      () async {
        // A Mac on Wi-Fi with a USB-Ethernet lab switch: both private, both
        // LAN. Pinning every multicast query to whichever the OS enumerated
        // first made mDNS stop finding devices it used to find through the
        // default route, and enumeration order is not a signal about where the
        // devices are. The OS routes, as it did before F-014.
        final addr = await primaryLanIpv4(
          lister: _listerOf([
            _FakeInterface('en0', ['192.168.1.5']),
            _FakeInterface('en7', ['10.0.0.9']),
          ]),
        );
        expect(addr, isNull);
      },
    );

    test(
      'a public-only second interface does not unpin the private one',
      () async {
        // The pin is about private LANs. One private interface beside a
        // public-addressed one (a VPN that slipped the name filter) is still
        // one answer.
        final addr = await primaryLanIpv4(
          lister: _listerOf([
            _FakeInterface('en0', ['192.168.1.5']),
            _FakeInterface('en5', ['203.0.113.7']),
          ]),
        );
        expect(addr?.address, '192.168.1.5');
      },
    );

    test('is null when only cellular/tunnel interfaces are up', () async {
      // [lanInterfaces] yields to the unfiltered list rather than return
      // nothing, so a multicast JOIN still happens somewhere. The egress pick
      // must NOT inherit that: answering with the cellular address pins
      // IP_MULTICAST_IF to the one radio no LAN device can hear, which is
      // strictly worse than leaving the OS to pick as it did before F-014.
      for (final only in ['rmnet_data0', 'pdp_ip0', 'utun0']) {
        final addr = await primaryLanIpv4(
          lister: _listerOf([
            _FakeInterface(only, ['10.171.4.9']),
          ]),
        );
        expect(addr, isNull, reason: '$only is not an egress LAN interface');
      }
    });
  });
}
