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
const _manifestUrl = 'https://specs.example.com/packs/pack.json';

NetworkCapabilitiesDto _caps({
  String? scheme,
  String? verification,
  bool selfSigned = false,
  String? mqtt,
}) => NetworkCapabilitiesDto(
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

    SpecPackService service(String packYaml, {bool floor = true}) {
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
                bundledSpecs: () async => {_envoyPath: envoyYaml},
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
  });
}
