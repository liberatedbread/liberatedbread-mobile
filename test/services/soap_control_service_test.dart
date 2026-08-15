// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The SOAP transport, against canned HTTP. Every rule exercised here is one
// the Wemo spec publishes: control URLs come from the device's own service
// list (never a hardcoded path), the SOAPACTION quotes are part of the value,
// responses parse as envelope → Body → first child → name/text pairs, and a
// namespace-less description must parse because some firmware serves one.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

const _setupXml = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:Belkin:device:crockpot:1</deviceType>
    <friendlyName>Kitchen Crock-Pot</friendlyName>
    <serialNumber>221517K0101769</serialNumber>
    <UDN>uuid:Crockpot-1_0-221517K0101769</UDN>
    <firmwareVersion>WeMo_WW_2.00.10966</firmwareVersion>
    <serviceList>
      <service>
        <serviceType>urn:Belkin:service:basicevent:1</serviceType>
        <controlURL>/upnp/control/basicevent1</controlURL>
      </service>
      <service>
        <serviceType>urn:Belkin:service:metainfo:1</serviceType>
        <controlURL>/upnp/control/metainfo1</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

const _stateResponse = '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<u:GetCrockpotStateResponse xmlns:u="urn:Belkin:service:basicevent:1">
<mode>51</mode>
<time>240</time>
<cookedTime>15</cookedTime>
</u:GetCrockpotStateResponse>
</s:Body>
</s:Envelope>
''';

const _faultResponse = '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<s:Fault>
<faultcode>s:Client</faultcode>
<faultstring>UPnPError</faultstring>
</s:Fault>
</s:Body>
</s:Envelope>
''';

const _request = SoapRequestDto(
  service: 'urn:Belkin:service:basicevent:1',
  action: 'GetCrockpotState',
  soapAction: '"urn:Belkin:service:basicevent:1#GetCrockpotState"',
  path: '/from-the-spec',
  body: '<envelope/>',
);

void main() {
  group('fetchDescription', () {
    test('parses identity and the service list from setup.xml', () async {
      final client = SoapControlClient(
        httpClient: MockClient((request) async {
          expect(request.url.toString(), 'http://10.0.0.5:49153/setup.xml');
          return http.Response(_setupXml, 200);
        }),
      );
      final description = await client.fetchDescription('10.0.0.5', 49153);
      expect(description.friendlyName, 'Kitchen Crock-Pot');
      expect(description.deviceType, 'urn:Belkin:device:crockpot:1');
      expect(description.udn, 'uuid:Crockpot-1_0-221517K0101769');
      expect(description.firmwareVersion, 'WeMo_WW_2.00.10966');
      expect(
        description.controlUrls['urn:Belkin:service:basicevent:1'],
        '/upnp/control/basicevent1',
      );
    });

    test('reads the Wemo rtos/iot markers when present, null when not',
        () async {
      // A Wemo setup.xml carries <rtos>/<iot>; they pick the credential layout.
      final withMarkers = _setupXml.replaceFirst(
          '<friendlyName>', '<rtos>1</rtos><iot>0</iot><friendlyName>');
      final client = SoapControlClient(
        httpClient:
            MockClient((request) async => http.Response(withMarkers, 200)),
      );
      final description = await client.fetchDescription('10.0.0.5', 49153);
      expect(description.rtos, 1);
      expect(description.iot, 0);

      // A device without them (the plain fixture) reads null, not zero.
      final plain = SoapControlClient(
        httpClient:
            MockClient((request) async => http.Response(_setupXml, 200)),
      );
      final bare = await plain.fetchDescription('10.0.0.5', 49153);
      expect(bare.rtos, isNull);
      expect(bare.iot, isNull);
    });

    test('parses a description with no namespace at all', () async {
      // The spec records that some firmware serves setup.xml with no
      // namespace; a parser that requires it loses exactly those devices.
      final stripped = _setupXml.replaceFirst(
          ' xmlns="urn:schemas-upnp-org:device-1-0"', '');
      final client = SoapControlClient(
        httpClient: MockClient((request) async => http.Response(stripped, 200)),
      );
      final description = await client.fetchDescription('10.0.0.5', 49153);
      expect(description.friendlyName, 'Kitchen Crock-Pot');
      expect(description.controlUrls, isNotEmpty);
    });

    test('fetches the path the device advertised, not always setup.xml',
        () async {
      // A Panasonic Viera's LOCATION is http://<ip>:55000/nrc/ddd.xml; asking
      // it for /setup.xml turns a working device into a permanent error.
      final client = SoapControlClient(
        httpClient: MockClient((request) async {
          expect(request.url.toString(), 'http://10.0.0.5:55000/nrc/ddd.xml');
          return http.Response(_setupXml, 200);
        }),
      );
      final description = await client.fetchDescription('10.0.0.5', 55000,
          path: '/nrc/ddd.xml');
      expect(description.controlUrls, isNotEmpty);
    });

    test('a non-200 is a transport error naming the URL', () async {
      final client = SoapControlClient(
        httpClient: MockClient((request) async => http.Response('gone', 404)),
      );
      await expectLater(
        client.fetchDescription('10.0.0.5', 49153),
        throwsA(isA<SoapTransportException>()),
      );
    });
  });

  group('controlPathFor', () {
    test('the device answer wins over the spec path', () {
      const description = SoapDeviceDescription(
        host: 'h',
        port: 1,
        controlUrls: {
          'urn:Belkin:service:basicevent:1': '/upnp/control/device-truth'
        },
      );
      // Published paths move across firmware generations; the device's own
      // serviceList is the authority and the spec's path only a fallback.
      expect(
          description.controlPathFor(_request), '/upnp/control/device-truth');
    });

    test('falls back to the spec path, and to null past that', () {
      const empty = SoapDeviceDescription(host: 'h', port: 1, controlUrls: {});
      expect(empty.controlPathFor(_request), '/from-the-spec');
      const pathless = SoapRequestDto(
        service: 'urn:Belkin:service:absent:1',
        action: 'X',
        soapAction: '"urn:Belkin:service:absent:1#X"',
        path: null,
        body: '<x/>',
      );
      // Null, not a guess: POSTing to an invented path fails at the device
      // with less information than declining here.
      expect(empty.controlPathFor(pathless), isNull);
    });
  });

  group('send', () {
    test('POSTs the rendered body with the exact SOAPACTION header', () async {
      late http.Request seen;
      final client = SoapControlClient(
        httpClient: MockClient((request) async {
          seen = request;
          return http.Response(_stateResponse, 200);
        }),
      );
      final values = await client.send(
          '10.0.0.5', 49153, '/upnp/control/basicevent1', _request);

      expect(seen.method, 'POST');
      expect(seen.url.toString(),
          'http://10.0.0.5:49153/upnp/control/basicevent1');
      // The quotes are part of the header value — firmware that rejects a
      // bare value does not say why.
      expect(seen.headers['SOAPACTION'],
          '"urn:Belkin:service:basicevent:1#GetCrockpotState"');
      expect(seen.headers['Content-Type'], startsWith('text/xml'));
      expect(seen.body, '<envelope/>');

      // The reply, parsed by the published rule: Body → first child →
      // {tag: text}. One call carries the whole Crock-Pot state.
      expect(values, {'mode': '51', 'time': '240', 'cookedTime': '15'});
    });

    test('a SOAP Fault surfaces as its own exception type', () async {
      final client = SoapControlClient(
        httpClient:
            MockClient((request) async => http.Response(_faultResponse, 200)),
      );
      // A fault is the device refusing, not the network failing — a caller
      // that retries transport errors must not retry these.
      await expectLater(
        client.send('10.0.0.5', 49153, '/p', _request),
        throwsA(isA<SoapFaultException>()),
      );
    });

    test('unparseable XML is a transport error, not a crash', () async {
      final client = SoapControlClient(
        httpClient:
            MockClient((request) async => http.Response('not xml', 200)),
      );
      await expectLater(
        client.send('10.0.0.5', 49153, '/p', _request),
        throwsA(isA<SoapTransportException>()),
      );
    });
  });
}
