// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A pack spec that shadows a bundled one must not weaken its transport
// security: credentials and certificate pins are filed by DEVICE, so the
// pack's policy is the one they are sent under. The install and cache-read
// paths run on the production codec against the vendored Envoy spec.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_pack_service.dart';

import '../helpers/host_rust_lib.dart';

const _envoyPath =
    'vendor/protocol-specs/device-specs/devices/enphase-envoy.yaml';
const _roombaPath =
    'vendor/protocol-specs/device-specs/devices/irobot-roomba.yaml';
const _samsungPath =
    'vendor/protocol-specs/device-specs/devices/samsung-tizen-tv.yaml';
const _rokuPath = 'vendor/protocol-specs/device-specs/devices/roku-ecp.yaml';
const _hisensePath =
    'vendor/protocol-specs/device-specs/devices/hisense-vidaa.yaml';
const _manifestUrl = 'https://specs.example.com/packs/pack.json';

/// Samsung's shape: the token rides only the wss:8002 connect.
WebSocketSurfaceDto _socket({
  String fallbackPath = '/remote?name={client_name}',
  String fallbackScheme = 'ws',
  String? pairingMode = 'token_query',
  String scheme = 'wss',
  bool selfSigned = true,
  String? verification = 'none',
}) => WebSocketSurfaceDto(
  port: 8002,
  scheme: scheme,
  path: '/remote?name={client_name}&token={samsung_token}',
  fallbackPort: 8001,
  fallbackScheme: fallbackScheme,
  fallbackPath: fallbackPath,
  headers: const [],
  tlsSelfSigned: selfSigned,
  tlsVerification: verification,
  pairingMode: pairingMode,
  credentialName: 'samsung_token',
  channels: const [],
);

NetworkCapabilitiesDto _caps({
  String? scheme,
  String? verification,
  bool selfSigned = false,
  String? mqtt,
  int? port,
  String? handler,
}) => NetworkCapabilitiesDto(
  protocolHandler: handler,
  defaultPort: port,
  defaultScheme: scheme,
  tlsVerification: verification,
  tlsSelfSigned: selfSigned,
  advertisedPortUnreliable: false,
  mqttClientIdGenerated: false,
  mqttTransportSecurity: mqtt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('securityDowngrade', () {
    final envoy = _caps(
      scheme: 'https',
      verification: 'trust_on_first_use',
      selfSigned: true,
    );

    test('the same or a stricter policy passes', () {
      expect(
        SpecPackService.securityDowngrade(bundled: envoy, pack: envoy),
        isNull,
      );
      expect(
        SpecPackService.securityDowngrade(
          bundled: envoy,
          pack: _caps(scheme: 'https', verification: 'standard'),
        ),
        isNull,
      );
      // A bundled spec that asks nothing sets no floor.
      expect(
        SpecPackService.securityDowngrade(bundled: _caps(), pack: _caps()),
        isNull,
      );
    });

    test('verification none, unstated, or plain http is refused', () {
      for (final pack in [
        _caps(scheme: 'https', verification: 'none', selfSigned: true),
        _caps(scheme: 'https', selfSigned: true),
        _caps(verification: 'trust_on_first_use', selfSigned: true),
      ]) {
        expect(
          SpecPackService.securityDowngrade(bundled: envoy, pack: pack),
          isNotNull,
        );
      }
    });

    test('a TLS broker may not become plaintext', () {
      expect(
        SpecPackService.securityDowngrade(
          bundled: _caps(mqtt: 'tls'),
          pack: _caps(mqtt: 'plaintext'),
        ),
        isNotNull,
      );
    });

    test('an undeclared TLS broker port sets the floor too', () {
      // Roomba (8883) and Hisense (36669) declare no transport_security, so
      // the old floor, reading only the declaration, passed a copy that
      // said plaintext or moved to 1883 and the broker login went in clear.
      // The broker shows in its commands (Hisense) or its handler (Roomba).
      String? verdict(
        NetworkCapabilitiesDto bundled,
        NetworkCapabilitiesDto pack, {
        bool commands = true,
      }) => SpecPackService.securityDowngrade(
        bundled: bundled,
        pack: pack,
        bundledSpeaksMqtt: commands,
        packSpeaksMqtt: commands,
      );
      for (final port in [8883, 36669]) {
        final bundled = _caps(port: port);
        for (final pack in [
          _caps(port: port, mqtt: 'plaintext'),
          _caps(port: 1883),
          // A copy that also hides its broker commands (behind a variant)
          // is held to the bundled broker's TLS all the same.
          _caps(),
        ]) {
          expect(verdict(bundled, pack), isNotNull, reason: '$port');
        }
        for (final pack in [bundled, _caps(port: port, mqtt: 'tls')]) {
          expect(verdict(bundled, pack), isNull);
        }
      }
      expect(
        verdict(
          _caps(port: 8883, handler: 'roomba_mqtt'),
          _caps(port: 1883, handler: 'roomba_mqtt'),
          commands: false,
        ),
        isNotNull,
      );
      // A plaintext broker (Dyson on 1883) sets no floor.
      expect(
        SpecPackService.securityDowngrade(
          bundled: _caps(port: 1883, mqtt: 'plaintext'),
          pack: _caps(port: 1883),
        ),
        isNull,
      );
      // No port known: only a pack pinning plaintext is refused.
      expect(
        SpecPackService.securityDowngrade(
          bundled: _caps(),
          pack: _caps(mqtt: 'plaintext'),
        ),
        isNotNull,
      );
    });

    test('a spec with no broker sets no MQTT floor from its port', () {
      // Roku ECP on 8060: an HTTP spec. Fails on the old floor, which read
      // every declared port by the broker convention (not 1883, so TLS) and
      // refused a copy that dropped the port, or moved it to 1883, as "MQTT
      // without TLS".
      final roku = _caps(port: 8060);
      for (final pack in [_caps(), _caps(port: 1883), roku]) {
        expect(
          SpecPackService.securityDowngrade(bundled: roku, pack: pack),
          isNull,
          reason: '${pack.defaultPort}',
        );
      }
      // Portless and brokerless, moved to 1883: still no broker.
      expect(
        SpecPackService.securityDowngrade(
          bundled: _caps(),
          pack: _caps(port: 1883),
        ),
        isNull,
      );
    });

    test('a WebSocket may not start accepting any certificate', () {
      // Fails on the old floor, which ranked the socket by the HTTP rule:
      // `self_signed: true` beside `verification: standard` still read as
      // validating, while the connector accepts any certificate for it.
      String? verdict(WebSocketSurfaceDto was, WebSocketSurfaceDto pack) =>
          SpecPackService.securityDowngrade(
            bundled: _caps(),
            pack: _caps(),
            bundledSocket: was,
            packSocket: pack,
          );
      for (final was in [
        _socket(selfSigned: false, verification: 'standard'),
        // No TLS fields at all: the connector validates the chain.
        _socket(selfSigned: false, verification: null),
      ]) {
        expect(
          verdict(was, _socket(verification: 'standard')),
          isNotNull,
          reason: was.tlsVerification,
        );
        expect(verdict(was, _socket()), isNotNull);
        expect(verdict(was, was), isNull);
      }
      // Samsung's own posture already accepts any: no floor to fall below.
      expect(verdict(_socket(), _socket(verification: 'standard')), isNull);
      // A socket that dials only plain ws has no certificate to judge.
      final plain = _socket(
        scheme: 'ws',
        fallbackPath: '/remote?name={client_name}',
        selfSigned: false,
        verification: null,
      );
      expect(
        verdict(
          plain,
          _socket(
            scheme: 'ws',
            fallbackPath: '/remote?name={client_name}',
            verification: 'none',
          ),
        ),
        isNull,
      );
      // A bundled socket that only ever dials ws (Bose SoundTouch, Logitech
      // Harmony: no TLS fields) verified no certificate, so a pack adding a
      // wss fallback that accepts any is no downgrade. Fails on the floor
      // that only asked whether the pack dials wss: the bundled surface
      // ranked as validating.
      WebSocketSurfaceDto bose({
        int? fallbackPort,
        String? fallbackScheme,
        String? verification,
        bool selfSigned = false,
      }) => WebSocketSurfaceDto(
        port: 8080,
        scheme: 'ws',
        path: '/',
        fallbackPort: fallbackPort,
        fallbackScheme: fallbackScheme,
        headers: const [],
        tlsSelfSigned: selfSigned,
        tlsVerification: verification,
        channels: const [],
      );
      expect(
        verdict(
          bose(),
          bose(fallbackPort: 8443, fallbackScheme: 'wss', verification: 'none'),
        ),
        isNull,
      );
      expect(
        verdict(
          bose(),
          bose(fallbackPort: 8443, fallbackScheme: 'wss', selfSigned: true),
        ),
        isNull,
      );
      // A bundled socket whose only wss connect is its fallback still sets
      // the floor.
      expect(
        verdict(
          bose(fallbackPort: 8443, fallbackScheme: 'wss'),
          bose(fallbackPort: 8443, fallbackScheme: 'wss', verification: 'none'),
        ),
        isNotNull,
      );
      // Samsung-shaped wss:8002 that validates: a pack switching it to
      // accept any certificate is still refused.
      expect(
        verdict(
          _socket(selfSigned: false, verification: 'standard'),
          _socket(selfSigned: false, verification: 'none'),
        ),
        isNotNull,
      );
    });

    test('a WebSocket credential may not move from wss to ws', () {
      String? verdict(WebSocketSurfaceDto pack, {WebSocketSurfaceDto? was}) =>
          SpecPackService.securityDowngrade(
            bundled: _caps(),
            pack: _caps(),
            bundledSocket: was ?? _socket(),
            packSocket: pack,
          );
      expect(verdict(_socket()), isNull);
      // Fails on the old code: the token went to ws:8001 in clear.
      expect(
        verdict(
          _socket(
            fallbackPath: '/remote?name={client_name}&token={samsung_token}',
          ),
        ),
        isNotNull,
      );
      // The same leak through the {token} alias the sender also fills with
      // the credential. Fails on the old floor, which only knew the spec's
      // own credential name.
      expect(
        verdict(
          _socket(fallbackPath: '/remote?name={client_name}&token={token}'),
        ),
        isNotNull,
      );
      // Register-frame pairing sends the key on whichever socket opened.
      expect(verdict(_socket(pairingMode: 'register_frame')), isNotNull);
      // Already over ws in the bundle (LG's register frame on 3000): no
      // floor to fall below.
      expect(
        verdict(
          _socket(pairingMode: 'register_frame'),
          was: _socket(pairingMode: 'register_frame'),
        ),
        isNull,
      );
    });
  });

  group('on the production codec', () {
    late final bool rustReady;
    late final String envoyYaml;
    late Directory dir;

    setUpAll(() async {
      rustReady = await initHostRustLib();
      envoyYaml = File(_envoyPath).readAsStringSync();
    });
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('spec_pack_floor_');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    SpecPackService service(
      String packYaml, {
      bool floor = true,
      String bundledPath = _envoyPath,
    }) {
      final codec = RealSpecCodec();
      return SpecPackService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('pack.json')) {
            return http.Response(
              jsonEncode({
                'name': 'Fixes',
                'version': '1',
                'specs': ['envoy.yaml'],
              }),
              200,
            );
          }
          // Bytes: the String constructor encodes Latin-1, and the spec
          // carries em dashes.
          return http.Response.bytes(utf8.encode(packYaml), 200);
        }),
        cacheDirResolver: () async => dir,
        securityFloor: floor
            ? SpecPackService.bundledSecurityFloor(
                codec: codec,
                bundledSpecs: () async => {
                  bundledPath: File(bundledPath).readAsStringSync(),
                },
              )
            : null,
      );
    }

    String weakened() => envoyYaml.replaceFirst(
      'verification: "trust_on_first_use"',
      'verification: "none"',
    );

    test('install refuses an Envoy copy that drops the pin', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      expect(weakened(), isNot(envoyYaml));
      // Fails on the old code: the copy installed, and the Envoy token was
      // then sent to whatever certificate answered.
      final result = await service(weakened()).install(_manifestUrl);
      expect(result, isA<InstallFailed>());
      expect(
        (result as InstallFailed).error.kind,
        SpecPackErrorKind.noSpecsInstalled,
      );
    });

    test('install refuses an Envoy copy on plain http', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final http = envoyYaml.replaceFirst(
        'default_scheme: "https"',
        'default_scheme: "http"',
      );
      expect(http, isNot(envoyYaml));
      expect(await service(http).install(_manifestUrl), isA<InstallFailed>());
    });

    test('an equally strict copy installs', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final result = await service(envoyYaml).install(_manifestUrl);
      expect(result, isA<InstallOk>());
      expect((result as InstallOk).partialFailures, isEmpty);
    });

    test('a weaker copy already in the cache is not loaded', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      // Installed by a build without the floor (or before an app update
      // made the bundled spec stricter): the read path is the backstop.
      final old = service(weakened(), floor: false);
      expect(await old.install(_manifestUrl), isA<InstallOk>());
      expect(await old.loadCachedSpecs(), hasLength(1));

      expect(await service(weakened()).loadCachedSpecs(), isEmpty);
    });

    test('install refuses a Roomba copy moved to the plaintext port', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final roomba = File(_roombaPath).readAsStringSync();
      final moved = roomba.replaceFirst(
        'default_port: 8883',
        'default_port: 1883',
      );
      expect(moved, isNot(roomba));
      // Fails on the old code: the Roomba spec declares no
      // transport_security, so the copy installed and the robot password
      // was sent to 1883 in clear.
      expect(
        await service(moved, bundledPath: _roombaPath).install(_manifestUrl),
        isA<InstallFailed>(),
      );
      expect(
        await service(roomba, bundledPath: _roombaPath).install(_manifestUrl),
        isA<InstallOk>(),
      );
    });

    test('the MQTT surface is read from the commands', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      // Hisense declares no `mqtt:` block: only its commands say broker.
      final codec = RealSpecCodec();
      for (final (path, expected) in [
        (_hisensePath, true),
        (_roombaPath, true),
        (_rokuPath, false),
        (_envoyPath, false),
      ]) {
        expect(
          await SpecPackService.hasMqttCommands(
            codec,
            File(path).readAsStringSync(),
          ),
          expected,
          reason: path,
        );
      }
    });

    test('install takes a Roku copy that drops its port', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final roku = File(_rokuPath).readAsStringSync();
      final portless = roku.replaceFirst('    default_port: 8060\n', '');
      expect(portless, isNot(roku));
      // Fails on the old code: the HTTP spec's 8060 read as a TLS broker
      // port, and the copy was refused as "MQTT without TLS".
      final result = await service(
        portless,
        bundledPath: _rokuPath,
      ).install(_manifestUrl);
      expect(result, isA<InstallOk>());
    });

    test(
      'install refuses a Hisense copy moved to the plaintext port',
      () async {
        if (!rustReady) {
          markTestSkipped('Rust lib not loaded');
          return;
        }
        final hisense = File(_hisensePath).readAsStringSync();
        final moved = hisense.replaceFirst(
          'default_port: 36669',
          'default_port: 1883',
        );
        expect(moved, isNot(hisense));
        // No `mqtt:` block, no handler: the floor finds the broker only
        // through the `transport: mqtt` commands.
        expect(
          await service(moved, bundledPath: _hisensePath).install(_manifestUrl),
          isA<InstallFailed>(),
        );
        expect(
          await service(
            hisense,
            bundledPath: _hisensePath,
          ).install(_manifestUrl),
          isA<InstallOk>(),
        );
      },
    );

    test('install refuses a Samsung copy sending the token over ws', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final samsung = File(_samsungPath).readAsStringSync();
      const fallback =
          'path: "/api/v2/channels/samsung.remote.control?name={client_name}"\n';
      expect(fallback.allMatches(samsung), hasLength(1));
      final leaky = samsung.replaceFirst(
        fallback,
        'path: "/api/v2/channels/samsung.remote.control'
        '?name={client_name}&token={samsung_token}"\n',
      );
      // Fails on the old code: the floor never read the WebSocket surface.
      expect(
        await service(leaky, bundledPath: _samsungPath).install(_manifestUrl),
        isA<InstallFailed>(),
      );
      expect(
        await service(samsung, bundledPath: _samsungPath).install(_manifestUrl),
        isA<InstallOk>(),
      );
      // And through the {token} alias.
      final aliased = samsung.replaceFirst(
        fallback,
        'path: "/api/v2/channels/samsung.remote.control'
        '?name={client_name}&token={token}"\n',
      );
      expect(
        await service(aliased, bundledPath: _samsungPath).install(_manifestUrl),
        isA<InstallFailed>(),
      );
    });
  });
}
