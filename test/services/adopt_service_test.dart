// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The adoption orchestration, end to end against canned transports. The Wemo
// half uses the real Rust FFI (so the encryption and ApList parse are real) and
// the real Wemo spec, faking only the HTTP a device would answer. The LIFX half
// reuses the app's own LIFX primitives (the crate's SoftAP datagrams, exercised
// by lifx_control.rs) and fakes the UDP client, so this pins the CONVERSATION —
// a Wemo join walks GetMetaInfo → GetApList → ConnectHomeNetwork → poll →
// CloseSetup; an open network skips the encryption; a LIFX device is probed,
// scanned and provisioned with one SetAccessPoint.

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/adopt_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_lifx_control_client.dart';
import '../fakes/fake_spec_codec.dart';
import '../helpers/host_rust_lib.dart';

const _setupXml = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:Belkin:device:controllee:1</deviceType>
    <friendlyName>WeMo Setup</friendlyName>
    <serialNumber>229999K9999999</serialNumber>
    <UDN>uuid:Socket-1_0-229999K9999999</UDN>
    <serviceList>
      <service>
        <serviceType>urn:Belkin:service:basicevent:1</serviceType>
        <controlURL>/upnp/control/basicevent1</controlURL>
      </service>
      <service>
        <serviceType>urn:Belkin:service:metainfo:1</serviceType>
        <controlURL>/upnp/control/metainfo1</controlURL>
      </service>
      <service>
        <serviceType>urn:Belkin:service:WiFiSetup:1</serviceType>
        <controlURL>/upnp/control/WiFiSetup1</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

const _notSetupXml = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Already Provisioned</friendlyName>
    <serviceList>
      <service>
        <serviceType>urn:Belkin:service:basicevent:1</serviceType>
        <controlURL>/upnp/control/basicevent1</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

String _soapResponse(String action, String inner) => '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<u:${action}Response xmlns:u="urn:Belkin:service:x:1">
$inner
</u:${action}Response>
</s:Body>
</s:Envelope>''';

/// A stateful Wemo AP: answers setup.xml and each setup action, recording the
/// ConnectHomeNetwork bodies the test inspects.
class _WemoAp {
  final List<String> connectBodies = [];
  String apList = '3\n'
      'HomeNet|6|WPA2PSK|blah|WPA2PSK/AES,\n'
      'OpenGuest|1|OPEN|blah|OPEN/NONE,\n'
      'NewFangled|1|SAE|blah|Unknown,\n';
  String networkStatus = '1';

  http.Client get client => MockClient((request) async {
        if (request.url.path == '/setup.xml') {
          return http.Response(_setupXml, 200);
        }
        final action = (request.headers['soapaction'] ?? '').toLowerCase();
        if (action.contains('getmetainfo')) {
          return http.Response(
              _soapResponse('GetMetaInfo',
                  '<MetaInfo>00005E00530A|229999K9999999|Wemo_WW|WeMo_US_2.00.11408|Wemo.Mini.4A2|Socket</MetaInfo>'),
              200);
        }
        if (action.contains('getaplist')) {
          return http.Response(
              _soapResponse('GetApList', '<ApList>$apList</ApList>'), 200);
        }
        if (action.contains('connecthomenetwork')) {
          connectBodies.add(request.body);
          return http.Response(
              _soapResponse('ConnectHomeNetwork',
                  '<PairingStatus>Connecting</PairingStatus>'),
              200);
        }
        if (action.contains('getnetworkstatus')) {
          return http.Response(
              _soapResponse('GetNetworkStatus',
                  '<NetworkStatus>$networkStatus</NetworkStatus>'),
              200);
        }
        if (action.contains('closesetup') ||
            action.contains('setsetupdonestatus')) {
          return http.Response(
              _soapResponse('CloseSetup', '<status>success</status>'), 200);
        }
        return http.Response('unexpected', 500);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final String wemoYaml;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    wemoYaml = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/wemo-devices.yaml');
  });

  bool skipUnlessRust() {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return true;
    }
    return false;
  }

  group('Wemo (real FFI)', () {
    test('connect returns null when the AP has no WiFiSetup service', () async {
      if (skipUnlessRust()) return;
      final service = AdoptService(
        codec: const RealSpecCodec(),
        soap: SoapControlClient(
          httpClient: MockClient((r) async => http.Response(_notSetupXml, 200)),
        ),
        lifx: FakeLifxControlClient(),
        wemoPorts: const [49153],
      );
      final session =
          await service.connect(family: AdoptFamily.wemo, specYaml: wemoYaml);
      expect(session, isNull,
          reason: 'no WiFiSetup service means this is not a setup AP');
    });

    test('lists the networks the device reports, flagging the WPA3 one',
        () async {
      if (skipUnlessRust()) return;
      final ap = _WemoAp();
      final service = AdoptService(
        codec: const RealSpecCodec(),
        soap: SoapControlClient(httpClient: ap.client),
        lifx: FakeLifxControlClient(),
        wemoPorts: const [49153],
      );
      final session =
          await service.connect(family: AdoptFamily.wemo, specYaml: wemoYaml);
      final networks = await service.listNetworks(session!);

      final home = networks.firstWhere((n) => n.ssid == 'HomeNet');
      expect(home.auth, 'WPA2PSK');
      expect(home.encrypt, 'AES');
      expect(home.channel, '6');
      expect(home.joinable, isTrue);
      expect(networks.firstWhere((n) => n.ssid == 'OpenGuest').isOpen, isTrue);
      expect(
          networks.firstWhere((n) => n.ssid == 'NewFangled').joinable, isFalse,
          reason: 'the device said Unknown — it cannot join it');
    });

    test('provisioning a secured network encrypts and reports joined',
        () async {
      if (skipUnlessRust()) return;
      final ap = _WemoAp();
      final service = AdoptService(
        codec: const RealSpecCodec(),
        soap: SoapControlClient(httpClient: ap.client),
        lifx: FakeLifxControlClient(),
        wemoPorts: const [49153],
      );
      final session =
          await service.connect(family: AdoptFamily.wemo, specYaml: wemoYaml);
      final networks = await service.listNetworks(session!);
      final home = networks.firstWhere((n) => n.ssid == 'HomeNet');

      final outcome = await service.provision(
          session, home, 'correct horse battery staple');
      expect(outcome.status, AdoptStatus.joined);
      expect(ap.connectBodies.length, 2, reason: 'sent twice, ~100ms apart');
      final body = ap.connectBodies.first;
      expect(body, contains('<ssid>HomeNet</ssid>'));
      expect(body, contains('<auth>WPA2PSK</auth>'));
      expect(body, contains('<channel>6</channel>'));
      expect(body, isNot(contains('correct horse battery staple')));
      expect(body, contains('<password>'));
    });

    test('an open network is provisioned with no encryption', () async {
      if (skipUnlessRust()) return;
      final ap = _WemoAp();
      final service = AdoptService(
        codec: const RealSpecCodec(),
        soap: SoapControlClient(httpClient: ap.client),
        lifx: FakeLifxControlClient(),
        wemoPorts: const [49153],
      );
      final session =
          await service.connect(family: AdoptFamily.wemo, specYaml: wemoYaml);
      final networks = await service.listNetworks(session!);
      final open = networks.firstWhere((n) => n.isOpen);

      final outcome = await service.provision(session, open, '');
      expect(outcome.status, AdoptStatus.joined);
      final body = ap.connectBodies.first;
      expect(body, contains('<auth>OPEN</auth>'));
      expect(body, contains('<encrypt>NONE</encrypt>'));
      expect(body, contains('<password></password>'));
    });

    test('network status 2 is a terminal rejection, not a retry', () async {
      if (skipUnlessRust()) return;
      final ap = _WemoAp()..networkStatus = '2';
      final service = AdoptService(
        codec: const RealSpecCodec(),
        soap: SoapControlClient(httpClient: ap.client),
        lifx: FakeLifxControlClient(),
        wemoPorts: const [49153],
      );
      final session =
          await service.connect(family: AdoptFamily.wemo, specYaml: wemoYaml);
      final networks = await service.listNetworks(session!);
      final home = networks.firstWhere((n) => n.ssid == 'HomeNet');

      final outcome =
          await service.provision(session, home, 'password-long-enough');
      expect(outcome.status, AdoptStatus.rejected);
      expect(ap.connectBodies.length, 2, reason: 'one candidate, sent twice');
    });
  });

  group('LIFX (fake client + codec)', () {
    test('connect answers when a StateService-shaped reply arrives', () async {
      final service = AdoptService(
        codec: FakeSpecCodec(),
        lifx: FakeLifxControlClient(),
      );
      final session =
          await service.connect(family: AdoptFamily.lifx, specYaml: '');
      expect(session, isNotNull);
      expect(session!.family, AdoptFamily.lifx);
    });

    test('connect gives up when nothing answers', () async {
      final service = AdoptService(
        codec: FakeSpecCodec(),
        lifx: FakeLifxControlClient()..collectReplies = const [],
      );
      final session =
          await service.connect(family: AdoptFamily.lifx, specYaml: '');
      expect(session, isNull);
    });

    test('lists access points, de-duplicating a network seen twice', () async {
      final codec = FakeSpecCodec()
        ..lifxAccessPoint = const LifxAccessPointDto(
            ssid: 'HomeNet', security: 5, strength: -40, channel: 11);
      final client = FakeLifxControlClient()
        // Three replies, all decode (via the fake) to the same SSID.
        ..collectReplies = [Uint8List(41), Uint8List(41), Uint8List(41)];
      final service = AdoptService(codec: codec, lifx: client);
      final session =
          await service.connect(family: AdoptFamily.lifx, specYaml: '');
      final networks = await service.listNetworks(session!);
      expect(networks, hasLength(1), reason: 'one row per SSID');
      expect(networks.single.ssid, 'HomeNet');
      expect(networks.single.securityByte, 5);
    });

    test('provision sends one SetAccessPoint and reports it unconfirmed',
        () async {
      final codec = FakeSpecCodec();
      final client = FakeLifxControlClient();
      final service = AdoptService(codec: codec, lifx: client);
      final session =
          await service.connect(family: AdoptFamily.lifx, specYaml: '');
      final outcome = await service.provision(
        session!,
        const SetupNetwork(
            ssid: 'HomeNet', joinable: true, isOpen: false, securityByte: 5),
        'hunter22',
      );
      expect(outcome.status, AdoptStatus.sentUnconfirmed);
      // One credential send went out, to the setup broadcast.
      expect(client.sent, hasLength(1));
      expect(client.sent.single.host, AdoptService.lifxSetupBroadcast);
      // The codec recorded the SSID/password/security it was asked to encode.
      expect(codec.setAccessPointCalls.single.ssid, 'HomeNet');
      expect(codec.setAccessPointCalls.single.security, 5);
    });
  });
}
