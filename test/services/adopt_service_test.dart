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
import 'package:liberated_bread_mobile/core/log.dart';
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

String _soapResponse(String action, String inner) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<u:${action}Response xmlns:u="urn:Belkin:service:x:1">
$inner
</u:${action}Response>
</s:Body>
</s:Envelope>''';

const _faultResponse = '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<s:Fault><faultcode>s:Client</faultcode><detail>UPnPError 401</detail></s:Fault>
</s:Body>
</s:Envelope>''';

/// A stateful Wemo AP: answers setup.xml and each setup action, recording the
/// ConnectHomeNetwork bodies the test inspects.
class _WemoAp {
  final List<String> connectBodies = [];

  /// Every action asked of this AP, in order — how the spec's step sequence is
  /// pinned (metadata before the AP list) and how a retry is counted.
  final List<String> actions = [];

  /// GetApList / GetMetaInfo error this many times before answering, standing
  /// in for the firmware that simply does not answer the first ask.
  int apListFailuresBeforeOk = 0;
  int metaFailuresBeforeOk = 0;
  int _apListCalls = 0;
  int _metaCalls = 0;

  /// When true, GetApList answers with a SOAP Fault: the device understood and
  /// refused, which is not a flaky answer and must not be retried.
  bool faultOnApList = false;
  String apList =
      '3\n'
      'HomeNet|6|WPA2PSK|blah|WPA2PSK/AES,\n'
      'OpenGuest|1|OPEN|blah|OPEN/NONE,\n'
      'NewFangled|1|SAE|blah|Unknown,\n';
  String networkStatus = '1';

  /// When set, the AP answers only on this port; every other port errors, as a
  /// device whose setup server came up somewhere other than the first guess.
  int? onlyPort;

  /// When true, every ConnectHomeNetwork errors — the setup AP dropping right
  /// as the device starts hopping to join.
  bool failConnect = false;

  /// GetNetworkStatus errors this many times before it starts answering — a
  /// transient drop mid-poll that must not read as total failure.
  int statusFailuresBeforeOk = 0;
  int _statusCalls = 0;

  /// The setup.xml this AP serves — overridable so a test can add the rtos/iot
  /// markers that steer the credential layout.
  String setupXml = _setupXml;

  http.Client get client => MockClient((request) async {
    if (onlyPort != null && request.url.port != onlyPort) {
      return http.Response('wrong port', 500);
    }
    if (request.url.path == '/setup.xml') {
      actions.add('setup.xml');
      return http.Response(setupXml, 200);
    }
    final rawAction = request.headers['soapaction'] ?? '';
    final action = rawAction.toLowerCase();
    // Recorded from the header as the device sees it, so an assertion on
    // the sequence reads like the spec's step list.
    actions.add(rawAction.split('#').last.replaceAll('"', ''));
    if (action.contains('getmetainfo')) {
      if (_metaCalls++ < metaFailuresBeforeOk) {
        return http.Response('busy', 500);
      }
      return http.Response(
        _soapResponse(
          'GetMetaInfo',
          '<MetaInfo>00005E00530A|229999K9999999|Wemo_WW|WeMo_US_2.00.11408|Wemo.Mini.4A2|Socket</MetaInfo>',
        ),
        200,
      );
    }
    if (action.contains('getaplist')) {
      if (faultOnApList) {
        return http.Response(_faultResponse, 500);
      }
      if (_apListCalls++ < apListFailuresBeforeOk) {
        return http.Response('busy', 500);
      }
      return http.Response(
        _soapResponse('GetApList', '<ApList>$apList</ApList>'),
        200,
      );
    }
    if (action.contains('connecthomenetwork')) {
      if (failConnect) return http.Response('setup AP gone', 500);
      connectBodies.add(request.body);
      return http.Response(
        _soapResponse(
          'ConnectHomeNetwork',
          '<PairingStatus>Connecting</PairingStatus>',
        ),
        200,
      );
    }
    if (action.contains('getnetworkstatus')) {
      if (_statusCalls++ < statusFailuresBeforeOk) {
        return http.Response('poll dropped', 500);
      }
      return http.Response(
        _soapResponse(
          'GetNetworkStatus',
          '<NetworkStatus>$networkStatus</NetworkStatus>',
        ),
        200,
      );
    }
    if (action.contains('closesetup') ||
        action.contains('setsetupdonestatus')) {
      return http.Response(
        _soapResponse('CloseSetup', '<status>success</status>'),
        200,
      );
    }
    return http.Response('unexpected', 500);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final String wemoYaml;

  // Adoption is the flow people debug from a console, so every step logs.
  // Capturing keeps that out of the test output AND makes the transcript
  // assertable — the diagnostics below are as much a deliverable as the
  // conversation itself.
  late List<LogRecord> logs;
  setUp(() => logs = Log.captureRecords());
  tearDown(Log.reset);

  Iterable<String> linesAt(LogLevel level) => logs
      .where((r) => r.level == level && r.category == 'adopt')
      .map((r) => r.message);

  setUpAll(() async {
    rustReady = await initHostRustLib();
    wemoYaml = await rootBundle.loadString(
      'vendor/protocol-specs/device-specs/devices/wemo-devices.yaml',
    );
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
      final session = await service.connect(
        family: AdoptFamily.wemo,
        specYaml: wemoYaml,
      );
      expect(
        session,
        isNull,
        reason: 'no WiFiSetup service means this is not a setup AP',
      );

      // A host answered — so "couldn't reach the device", the message this
      // outcome shows, is the wrong diagnosis and the log must not repeat it.
      // The device's own name and service list are what say why.
      expect(
        linesAt(LogLevel.warning).join('\n'),
        allOf(
          contains('lists no WiFiSetup service'),
          contains('Already Provisioned'),
          contains('basicevent:1'),
        ),
      );
    });

    test(
      'the confirmed setup AP is logged with what selects the encryption',
      () async {
        if (skipUnlessRust()) return;
        final ap = _WemoAp();
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
        );
        await service.connect(family: AdoptFamily.wemo, specYaml: wemoYaml);

        final info = linesAt(LogLevel.info).join('\n');
        // The probe plan first — it is the flow's longest silence, and a reader
        // needs to know whether 10 seconds of nothing is normal.
        expect(info, contains('wemo connect: probing 10.22.22.1'));
        // Then what answered: the port (it moves across firmware), the service
        // list, and the rtos/iot markers that pick which password layout is
        // tried first. Chasing a failed join without those is guesswork.
        expect(
          info,
          allOf(
            contains('setup AP confirmed at 10.22.22.1:49153'),
            contains('WiFiSetup:1'),
            contains('rtos='),
            contains('iot='),
          ),
        );
      },
    );

    test(
      'connect reads the metadata first, in the spec\'s step order',
      () async {
        if (skipUnlessRust()) return;
        final ap = _WemoAp();
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        await service.listNetworks(session!);

        // The spec's steps: fetch the description, read the metadata that keys
        // the passphrase encryption, THEN ask for a radio scan. Reading the
        // metadata after the scan (and after the user has typed a password) is
        // how a device that never answers metainfo used to cost a whole flow.
        expect(ap.actions, ['setup.xml', 'GetMetaInfo', 'GetApList']);
        expect(
          session.metaInfo,
          startsWith('00005E00530A|'),
          reason: 'the session carries it so provision need not ask again',
        );
      },
    );

    test(
      'provision reuses the metadata the connect step already read',
      () async {
        if (skipUnlessRust()) return;
        final ap = _WemoAp();
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        final networks = await service.listNetworks(session!);
        await service.provision(
          session,
          networks.firstWhere((n) => n.ssid == 'HomeNet'),
          'a good passphrase',
        );

        expect(
          ap.actions.where((a) => a == 'GetMetaInfo'),
          hasLength(1),
          reason:
              'the metadata is hardware identity — it does not change '
              'between connecting and provisioning',
        );
      },
    );

    test('a setup read that fails once is retried, not abandoned', () async {
      if (skipUnlessRust()) return;
      final ap = _WemoAp()..apListFailuresBeforeOk = 2;
      final service = AdoptService(
        codec: const RealSpecCodec(),
        soap: SoapControlClient(httpClient: ap.client),
        lifx: FakeLifxControlClient(),
        wemoPorts: const [49153],
        setupRetryGap: Duration.zero,
      );
      final session = await service.connect(
        family: AdoptFamily.wemo,
        specYaml: wemoYaml,
      );
      final networks = await service.listNetworks(session!);

      // The spec's catch-all troubleshooting entry is "genuinely try again":
      // Wemo devices fail an exchange and then answer the identical one.
      expect(
        networks,
        isNotEmpty,
        reason:
            'the third ask answered, so the user gets a picker rather '
            'than a typed-SSID fallback',
      );
      expect(ap.actions.where((a) => a == 'GetApList'), hasLength(3));
      expect(
        linesAt(LogLevel.warning).join('\n'),
        contains('GetApList failed on attempt 1 of 3'),
      );
    });

    test(
      'a single miss while connecting is retried, not warned about',
      () async {
        if (skipUnlessRust()) return;
        // The client can ask before it has properly settled on the setup AP.
        // That first miss is the transient the spec's "genuinely try again"
        // describes — absorbing it here is the difference between a clean picker
        // and a warning about a device that is answering perfectly well.
        final ap = _WemoAp()..metaFailuresBeforeOk = 1;
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
          setupRetryGap: Duration.zero,
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );

        expect(session!.metaInfo, startsWith('00005E00530A|'));
        expect(ap.actions.where((a) => a == 'GetMetaInfo'), hasLength(2));
        expect(
          linesAt(LogLevel.warning).join('\n'),
          allOf(
            contains('GetMetaInfo failed on attempt 1 of 2'),
            isNot(contains('failed on all')),
          ),
        );
      },
    );

    test(
      'a refusal is not retried — the device understood and said no',
      () async {
        if (skipUnlessRust()) return;
        final ap = _WemoAp()..faultOnApList = true;
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
          setupRetryGap: Duration.zero,
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        await expectLater(
          service.listNetworks(session!),
          throwsA(isA<SoapFaultException>()),
        );
        expect(
          ap.actions.where((a) => a == 'GetApList'),
          hasLength(1),
          reason:
              'a fault is an answer; asking again just wastes the '
              'device\'s few worker threads',
        );
      },
    );

    test(
      'a device that never answers GetMetaInfo says so before the password',
      () async {
        if (skipUnlessRust()) return;
        // The reported failure shape: setup.xml and the AP list answer, metainfo
        // times out. It used to surface as a bare TimeoutException after the
        // user had typed a password and picked a network.
        final ap = _WemoAp()..metaFailuresBeforeOk = 99;
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
          setupRetryGap: Duration.zero,
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        expect(
          session,
          isNotNull,
          reason: 'an open network still works without key material',
        );
        expect(session!.metaInfo, isNull);
        expect(
          linesAt(LogLevel.warning).join('\n'),
          allOf(
            contains('GetMetaInfo failed on all 2 attempt(s)'),
            contains('wemo connect: no metadata'),
          ),
        );

        // And provisioning a secured network spends the retry budget before
        // giving up with text that names the remedy.
        final networks = await service.listNetworks(session);
        await expectLater(
          service.provision(
            session,
            networks.firstWhere((n) => n.ssid == 'HomeNet'),
            'a good pass',
          ),
          throwsA(isA<AdoptException>()),
        );
        expect(
          ap.actions.where((a) => a == 'GetMetaInfo'),
          hasLength(5),
          reason:
              'a retried best-effort read while connecting (2), then the '
              'full retry budget when the answer is actually required (3)',
        );
      },
    );

    test(
      'lists the networks the device reports, flagging the WPA3 one',
      () async {
        if (skipUnlessRust()) return;
        final ap = _WemoAp();
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        final networks = await service.listNetworks(session!);

        final home = networks.firstWhere((n) => n.ssid == 'HomeNet');
        expect(home.auth, 'WPA2PSK');
        expect(home.encrypt, 'AES');
        expect(home.channel, '6');
        expect(home.joinable, isTrue);
        expect(
          networks.firstWhere((n) => n.ssid == 'OpenGuest').isOpen,
          isTrue,
        );
        expect(
          networks.firstWhere((n) => n.ssid == 'NewFangled').joinable,
          isFalse,
          reason: 'the device said Unknown — it cannot join it',
        );
      },
    );

    test(
      'provisioning a secured network encrypts and reports joined',
      () async {
        if (skipUnlessRust()) return;
        final ap = _WemoAp();
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        final networks = await service.listNetworks(session!);
        final home = networks.firstWhere((n) => n.ssid == 'HomeNet');

        final outcome = await service.provision(
          session,
          home,
          'correct horse battery staple',
        );
        expect(outcome.status, AdoptStatus.joined);
        expect(ap.connectBodies.length, 2, reason: 'sent twice, ~100ms apart');
        final body = ap.connectBodies.first;
        expect(body, contains('<ssid>HomeNet</ssid>'));
        expect(body, contains('<auth>WPA2PSK</auth>'));
        expect(body, contains('<channel>6</channel>'));
        expect(body, isNot(contains('correct horse battery staple')));
        expect(body, contains('<password>'));

        // Which of the six encryption variants the hardware actually took. The
        // device never says — it either joins or does not — so this line is the
        // only place that fact exists, and it is the first thing a Wemo bug
        // report needs.
        expect(
          linesAt(LogLevel.info).join('\n'),
          allOf(
            contains('credential variant(s) to try'),
            contains('joined with variant 1/6 (method 1, with length suffix)'),
          ),
        );

        // And what must never be in the transcript: the passphrase, and the
        // serial number — which is half the encryption key and the device's
        // identity. A console log gets screen-shared and pasted into issues.
        final everything = logs.map((r) => r.format()).join('\n');
        expect(everything, isNot(contains('correct horse battery staple')));
        expect(everything, isNot(contains('229999K9999999')));
        expect(
          everything,
          contains('serial=<14 chars>'),
          reason:
              'the shape is what diagnoses a swapped MetaInfo field, '
              'not the value',
        );
      },
    );

    test('an open network is provisioned with no encryption', () async {
      if (skipUnlessRust()) return;
      final ap = _WemoAp();
      final service = AdoptService(
        codec: const RealSpecCodec(),
        soap: SoapControlClient(httpClient: ap.client),
        lifx: FakeLifxControlClient(),
        wemoPorts: const [49153],
      );
      final session = await service.connect(
        family: AdoptFamily.wemo,
        specYaml: wemoYaml,
      );
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
      final session = await service.connect(
        family: AdoptFamily.wemo,
        specYaml: wemoYaml,
      );
      final networks = await service.listNetworks(session!);
      final home = networks.firstWhere((n) => n.ssid == 'HomeNet');

      final outcome = await service.provision(
        session,
        home,
        'password-long-enough',
      );
      expect(outcome.status, AdoptStatus.rejected);
      expect(ap.connectBodies.length, 2, reason: 'one candidate, sent twice');
    });

    test(
      'connect probes the port the spec profile names, not the defaults',
      () async {
        if (skipUnlessRust()) return;
        // The setup server came up on 49157 — outside the service's built-in
        // fallback list. Only the spec-derived port passed to connect reaches it.
        final ap = _WemoAp()..onlyPort = 49157;
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
        );
        expect(
          await service.connect(family: AdoptFamily.wemo, specYaml: wemoYaml),
          isNull,
          reason: 'the default fallback ports do not include 49157',
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
          ports: const [49157],
        );
        expect(
          session,
          isNotNull,
          reason: 'the spec profile names 49157, so the probe finds it',
        );
      },
    );

    test(
      'a poll that drops mid-join is unconfirmed, not a thrown failure',
      () async {
        if (skipUnlessRust()) return;
        // Credentials go through, then the setup AP drops for two polls before it
        // answers "connected" — the ordinary shape of a successful join, which
        // must not surface as "sending failed".
        final ap = _WemoAp()..statusFailuresBeforeOk = 2;
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        final networks = await service.listNetworks(session!);
        final home = networks.firstWhere((n) => n.ssid == 'HomeNet');

        final outcome = await service.provision(
          session,
          home,
          'a-good-password',
        );
        expect(
          outcome.status,
          AdoptStatus.joined,
          reason: 'the poll recovers and the join is confirmed',
        );
      },
    );

    test(
      'a send that fails outright reports unreachable, never throws',
      () async {
        if (skipUnlessRust()) return;
        // Every ConnectHomeNetwork errors: nothing was delivered, so the honest
        // answer is "still on the setup network?", not a raised exception that
        // aborts the whole variant sweep.
        final ap = _WemoAp()..failConnect = true;
        final service = AdoptService(
          codec: const RealSpecCodec(),
          soap: SoapControlClient(httpClient: ap.client),
          lifx: FakeLifxControlClient(),
          wemoPorts: const [49153],
        );
        final session = await service.connect(
          family: AdoptFamily.wemo,
          specYaml: wemoYaml,
        );
        final networks = await service.listNetworks(session!);
        final home = networks.firstWhere((n) => n.ssid == 'HomeNet');

        final outcome = await service.provision(
          session,
          home,
          'a-good-password',
        );
        expect(outcome.status, AdoptStatus.unreachable);
        expect(ap.connectBodies, isEmpty, reason: 'no send ever landed');
      },
    );

    test(
      "the setup.xml's rtos marker steers which credential is tried first",
      () async {
        if (skipUnlessRust()) return;
        // rtos=1 without iot=1 selects the method-2 password layout, so the first
        // ConnectHomeNetwork body must differ from a device that named neither.
        Future<String> firstBodyFor(String setupXml) async {
          final ap = _WemoAp()..setupXml = setupXml;
          final service = AdoptService(
            codec: const RealSpecCodec(),
            soap: SoapControlClient(httpClient: ap.client),
            lifx: FakeLifxControlClient(),
            wemoPorts: const [49153],
          );
          final session = await service.connect(
            family: AdoptFamily.wemo,
            specYaml: wemoYaml,
          );
          final networks = await service.listNetworks(session!);
          final home = networks.firstWhere((n) => n.ssid == 'HomeNet');
          await service.provision(session, home, 'a-good-password');
          return ap.connectBodies.first;
        }

        final plain = await firstBodyFor(_setupXml);
        final rtos = await firstBodyFor(
          _setupXml.replaceFirst(
            '<friendlyName>',
            '<rtos>1</rtos><iot>0</iot><friendlyName>',
          ),
        );
        expect(
          rtos,
          isNot(plain),
          reason: 'rtos=1/iot=0 leads with the method-2 credential',
        );
      },
    );
  });

  group('LIFX (fake client + codec)', () {
    test('connect answers when a StateService-shaped reply arrives', () async {
      final service = AdoptService(
        codec: FakeSpecCodec(),
        lifx: FakeLifxControlClient(),
      );
      final session = await service.connect(
        family: AdoptFamily.lifx,
        specYaml: '',
      );
      expect(session, isNotNull);
      expect(session!.family, AdoptFamily.lifx);
    });

    test('connect gives up when nothing answers', () async {
      final service = AdoptService(
        codec: FakeSpecCodec(),
        lifx: FakeLifxControlClient()..collectReplies = const [],
      );
      final session = await service.connect(
        family: AdoptFamily.lifx,
        specYaml: '',
      );
      expect(session, isNull);
    });

    test(
      'setup discovery accepts a reply that does not echo the sequence',
      () async {
        // On the setup AP there is one device, and some firmware zeroes the
        // sequence byte; requiring the echo would strand it. connect must ask
        // collect not to filter on the echo.
        final client = FakeLifxControlClient();
        final service = AdoptService(codec: FakeSpecCodec(), lifx: client);
        await service.connect(family: AdoptFamily.lifx, specYaml: '');
        expect(client.lastCollectMatchSequence, isFalse);
      },
    );

    test('open-ness comes from the codec, not a byte compare here', () async {
      // A non-1 security byte the codec still calls open (isOpen true) must
      // read as open — the LIFX security vocabulary is the codec's to own.
      final codec = FakeSpecCodec()
        ..lifxAccessPoint = const LifxAccessPointDto(
          ssid: 'GuestOpen',
          security: 7,
          isOpen: true,
          strength: -50,
          channel: 6,
        );
      final service = AdoptService(
        codec: codec,
        lifx: FakeLifxControlClient()..collectReplies = [Uint8List(41)],
      );
      final session = await service.connect(
        family: AdoptFamily.lifx,
        specYaml: '',
      );
      final networks = await service.listNetworks(session!);
      expect(
        networks.single.isOpen,
        isTrue,
        reason: 'security byte 7 but the codec says open',
      );
    });

    test('lists access points, de-duplicating a network seen twice', () async {
      final codec = FakeSpecCodec()
        ..lifxAccessPoint = const LifxAccessPointDto(
          ssid: 'HomeNet',
          security: 5,
          isOpen: false,
          strength: -40,
          channel: 11,
        );
      final client = FakeLifxControlClient()
        // Three replies, all decode (via the fake) to the same SSID.
        ..collectReplies = [Uint8List(41), Uint8List(41), Uint8List(41)];
      final service = AdoptService(codec: codec, lifx: client);
      final session = await service.connect(
        family: AdoptFamily.lifx,
        specYaml: '',
      );
      final networks = await service.listNetworks(session!);
      expect(networks, hasLength(1), reason: 'one row per SSID');
      expect(networks.single.ssid, 'HomeNet');
      expect(networks.single.securityByte, 5);
    });

    test(
      'provision sends one SetAccessPoint and reports it unconfirmed',
      () async {
        final codec = FakeSpecCodec();
        final client = FakeLifxControlClient();
        final service = AdoptService(codec: codec, lifx: client);
        final session = await service.connect(
          family: AdoptFamily.lifx,
          specYaml: '',
        );
        final outcome = await service.provision(
          session!,
          const SetupNetwork(
            ssid: 'HomeNet',
            joinable: true,
            isOpen: false,
            securityByte: 5,
          ),
          'hunter22',
        );
        expect(outcome.status, AdoptStatus.sentUnconfirmed);
        // One credential send went out, to the setup broadcast.
        expect(client.sent, hasLength(1));
        expect(client.sent.single.host, AdoptService.lifxSetupBroadcast);
        // The codec recorded the SSID/password/security it was asked to encode.
        expect(codec.setAccessPointCalls.single.ssid, 'HomeNet');
        expect(codec.setAccessPointCalls.single.security, 5);
      },
    );
  });
}
