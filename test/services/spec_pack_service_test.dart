// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/spec_pack_service.dart';

const _manifestUrl = 'https://specs.example.com/packs/pack.json';

/// Build a service whose cache lives in [dir] and whose HTTP goes through
/// [handler].
SpecPackService _service(
  Directory dir,
  Future<http.Response> Function(http.Request request) handler, {
  Duration timeout = const Duration(seconds: 5),
  SpecValidator? specValidator,
}) {
  return SpecPackService(
    client: MockClient(handler),
    cacheDirResolver: () async => dir,
    timeout: timeout,
    specValidator: specValidator,
  );
}

String _manifestJson({
  String name = 'Test Pack',
  String version = '1.0.0',
  List<String> specs = const ['bulb.yaml'],
}) => jsonEncode({'name': name, 'version': version, 'specs': specs});

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('spec_pack_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('install - success', () {
    test('downloads and caches every listed spec', () async {
      final service = _service(tempDir, (request) async {
        final path = request.url.path;
        if (path.endsWith('pack.json')) {
          return http.Response(
            _manifestJson(specs: ['bulb.yaml', 'sensor.yaml']),
            200,
          );
        }
        if (path.endsWith('bulb.yaml')) {
          return http.Response('device_name: Bulb', 200);
        }
        if (path.endsWith('sensor.yaml')) {
          return http.Response('device_name: Sensor', 200);
        }
        return http.Response('not found', 404);
      });

      final result = await service.install(_manifestUrl);

      expect(result, isA<InstallOk>());
      final ok = result as InstallOk;
      expect(ok.partialFailures, isEmpty);
      expect(ok.pack.name, 'Test Pack');
      expect(ok.pack.version, '1.0.0');
      expect(ok.pack.specCount, 2);

      // Cached specs come back namespaced and keyed by file.
      final cached = await service.loadCachedSpecs();
      expect(cached, hasLength(2));
      expect(cached['pack:Test Pack/bulb.yaml'], 'device_name: Bulb');
      expect(cached['pack:Test Pack/sensor.yaml'], 'device_name: Sensor');

      final packs = await service.listInstalledPacks();
      expect(packs, hasLength(1));
      expect(packs.single.name, 'Test Pack');
    });

    test('resolves spec filenames relative to the manifest URL', () async {
      Uri? seenSpecUrl;
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(_manifestJson(specs: ['bulb.yaml']), 200);
        }
        seenSpecUrl = request.url;
        return http.Response('yaml', 200);
      });

      await service.install(_manifestUrl);
      expect(
        seenSpecUrl.toString(),
        'https://specs.example.com/packs/bulb.yaml',
      );
    });

    test('reinstalling replaces the previous pack of the same name', () async {
      var version = '1.0.0';
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(
            _manifestJson(version: version, specs: ['bulb.yaml']),
            200,
          );
        }
        return http.Response('v$version', 200);
      });

      await service.install(_manifestUrl);
      version = '2.0.0';
      await service.install(_manifestUrl);

      final packs = await service.listInstalledPacks();
      expect(packs, hasLength(1));
      expect(packs.single.version, '2.0.0');
      final cached = await service.loadCachedSpecs();
      expect(cached['pack:Test Pack/bulb.yaml'], 'v2.0.0');
    });
  });

  group('install - filename collisions', () {
    test(
      'two specs sharing a basename in different dirs stay 1:1 on disk',
      () async {
        final service = _service(tempDir, (request) async {
          final path = request.url.path;
          if (path.endsWith('pack.json')) {
            return http.Response(
              _manifestJson(specs: ['subdir/sensor.yaml', 'other/sensor.yaml']),
              200,
            );
          }
          if (path.contains('/subdir/')) {
            return http.Response('device_name: Subdir Sensor', 200);
          }
          if (path.contains('/other/')) {
            return http.Response('device_name: Other Sensor', 200);
          }
          return http.Response('not found', 404);
        });

        final result = await service.install(_manifestUrl);
        expect(result, isA<InstallOk>());
        final ok = result as InstallOk;
        // Both specs install; neither clobbers the other.
        expect(ok.pack.specCount, 2);
        expect(ok.partialFailures, isEmpty);

        // Each namespaced key maps back to its OWN content, not a shared file.
        final cached = await service.loadCachedSpecs();
        expect(cached, hasLength(2));
        expect(
          cached['pack:Test Pack/subdir/sensor.yaml'],
          'device_name: Subdir Sensor',
        );
        expect(
          cached['pack:Test Pack/other/sensor.yaml'],
          'device_name: Other Sensor',
        );

        // Two distinct files really landed on disk.
        final specsDir = Directory(
          '${tempDir.path}/spec_packs/test_pack/specs',
        );
        final files = (await specsDir.list().toList())
            .whereType<File>()
            .toList();
        expect(files, hasLength(2));
      },
    );

    test(
      'a collision the VOLUME sees is annotated too, not just an exact one (R-061)',
      () async {
        // The app's Application Support directory is case-insensitive on iOS
        // and macOS, so a case-sensitive check passed 'Bulb.yaml' and
        // 'bulb.yaml' through and let them clobber each other on disk —
        // leaving both keys in the metadata, one of them serving the other's
        // spec.
        final service = _service(tempDir, (request) async {
          final path = request.url.path;
          if (path.endsWith('pack.json')) {
            return http.Response(
              _manifestJson(specs: ['Bulb.yaml', 'bulb.yaml']),
              200,
            );
          }
          return http.Response('device_name: X', 200);
        });

        final result = await service.install(_manifestUrl);
        expect(result, isA<InstallOk>());
        final ok = result as InstallOk;
        expect(ok.pack.specCount, 1);
        expect(ok.partialFailures, hasLength(1));
        expect(ok.partialFailures.single.reason, contains('collides'));
      },
    );

    test(
      'a residual on-disk name collision is annotated, not clobbered',
      () async {
        // 'a/b.yaml' and 'a_b.yaml' both sanitize to 'a_b.yaml'; the second is
        // skipped with a partial failure rather than overwriting the first.
        final service = _service(tempDir, (request) async {
          final path = request.url.path;
          if (path.endsWith('pack.json')) {
            return http.Response(
              _manifestJson(specs: ['a/b.yaml', 'a_b.yaml']),
              200,
            );
          }
          return http.Response('device_name: X', 200);
        });

        final result = await service.install(_manifestUrl);
        expect(result, isA<InstallOk>());
        final ok = result as InstallOk;
        expect(ok.pack.specCount, 1);
        expect(ok.partialFailures, hasLength(1));
        expect(ok.partialFailures.single.reason, contains('collides'));

        final specsDir = Directory(
          '${tempDir.path}/spec_packs/test_pack/specs',
        );
        final files = (await specsDir.list().toList())
            .whereType<File>()
            .toList();
        expect(files, hasLength(1));
      },
    );
  });

  group('install - spec validation', () {
    // A validator that treats YAML containing 'INVALID' as unparseable.
    Future<bool> validator(String yaml) async => !yaml.contains('INVALID');

    test(
      'an invalid spec among valid ones is skipped as a partial failure',
      () async {
        final service = _service(tempDir, (request) async {
          final path = request.url.path;
          if (path.endsWith('pack.json')) {
            return http.Response(
              _manifestJson(specs: ['good.yaml', 'bad.yaml']),
              200,
            );
          }
          if (path.endsWith('good.yaml')) {
            return http.Response('device_name: Good', 200);
          }
          return http.Response('INVALID not a spec', 200);
        }, specValidator: validator);

        final result = await service.install(_manifestUrl);
        expect(result, isA<InstallOk>());
        final ok = result as InstallOk;
        expect(ok.pack.specCount, 1);
        expect(ok.partialFailures, hasLength(1));
        expect(ok.partialFailures.single.specFile, 'bad.yaml');
        expect(ok.partialFailures.single.reason, contains('valid device spec'));

        final cached = await service.loadCachedSpecs();
        expect(cached.keys, ['pack:Test Pack/good.yaml']);
      },
    );

    test(
      'an install with only invalid specs fails (records no pack)',
      () async {
        final service = _service(tempDir, (request) async {
          final path = request.url.path;
          if (path.endsWith('pack.json')) {
            return http.Response(
              _manifestJson(specs: ['bad1.yaml', 'bad2.yaml']),
              200,
            );
          }
          return http.Response('INVALID', 200);
        }, specValidator: validator);

        final result = await service.install(_manifestUrl);
        expect(result, isA<InstallFailed>());
        expect(
          (result as InstallFailed).error.kind,
          SpecPackErrorKind.noSpecsInstalled,
        );
        // Nothing was recorded as installed.
        expect(await service.listInstalledPacks(), isEmpty);
      },
    );
  });

  group('install - errors', () {
    test('rejects a non-http URL without touching the network', () async {
      final service = _service(
        tempDir,
        (_) async => throw StateError('should not be called'),
      );
      final result = await service.install('ftp://example.com/pack.json');
      expect(result, isA<InstallFailed>());
      expect(
        (result as InstallFailed).error.kind,
        SpecPackErrorKind.invalidUrl,
      );
    });

    test('maps a connection failure to a network error', () async {
      final service = _service(
        tempDir,
        (_) async => throw http.ClientException('refused'),
      );
      final result = await service.install(_manifestUrl);
      expect((result as InstallFailed).error.kind, SpecPackErrorKind.network);
    });

    test('maps a non-2xx manifest response to an http error', () async {
      final service = _service(
        tempDir,
        (_) async => http.Response('nope', 500),
      );
      final result = await service.install(_manifestUrl);
      expect((result as InstallFailed).error.kind, SpecPackErrorKind.http);
    });

    test('maps a timeout to a timeout error', () async {
      final service = _service(tempDir, (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response(_manifestJson(), 200);
      }, timeout: const Duration(milliseconds: 50));
      final result = await service.install(_manifestUrl);
      expect((result as InstallFailed).error.kind, SpecPackErrorKind.timeout);
    });

    test('rejects a malformed (non-JSON) manifest', () async {
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response('this is not json {{{', 200);
        }
        return http.Response('yaml', 200);
      });
      final result = await service.install(_manifestUrl);
      expect(
        (result as InstallFailed).error.kind,
        SpecPackErrorKind.malformedManifest,
      );
    });

    test('rejects a JSON manifest of the wrong shape', () async {
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          // Missing "specs", wrong types.
          return http.Response(jsonEncode({'name': 'X', 'version': 1}), 200);
        }
        return http.Response('yaml', 200);
      });
      final result = await service.install(_manifestUrl);
      expect(
        (result as InstallFailed).error.kind,
        SpecPackErrorKind.malformedManifest,
      );
    });

    test('fails when the only spec is malformed (non-UTF8) YAML', () async {
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(_manifestJson(specs: ['bulb.yaml']), 200);
        }
        // Invalid UTF-8 bytes masquerading as a YAML file.
        return http.Response.bytes([0xff, 0xfe, 0xfd], 200);
      });
      final result = await service.install(_manifestUrl);
      expect(
        (result as InstallFailed).error.kind,
        SpecPackErrorKind.noSpecsInstalled,
      );
    });

    test('rejects an oversized spec without installing it', () async {
      final big = 'a' * (SpecPackLimits.maxSpecBytes + 1);
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(_manifestJson(specs: ['bulb.yaml']), 200);
        }
        return http.Response(big, 200);
      });
      final result = await service.install(_manifestUrl);
      expect(
        (result as InstallFailed).error.kind,
        SpecPackErrorKind.noSpecsInstalled,
      );
    });
  });

  group('install - partial failure', () {
    test('installs the good specs and reports the failed ones', () async {
      final service = _service(tempDir, (request) async {
        final path = request.url.path;
        if (path.endsWith('pack.json')) {
          return http.Response(
            _manifestJson(specs: ['good.yaml', 'missing.yaml']),
            200,
          );
        }
        if (path.endsWith('good.yaml')) {
          return http.Response('device_name: Good', 200);
        }
        return http.Response('not found', 404);
      });

      final result = await service.install(_manifestUrl);
      expect(result, isA<InstallOk>());
      final ok = result as InstallOk;
      expect(ok.pack.specCount, 1);
      expect(ok.partialFailures, hasLength(1));
      expect(ok.partialFailures.single.specFile, 'missing.yaml');

      final cached = await service.loadCachedSpecs();
      expect(cached.keys, ['pack:Test Pack/good.yaml']);
    });
  });

  group('install - transport', () {
    test(
      'a plain-http manifest off the local network is never fetched',
      () async {
        var requests = 0;
        final service = _service(tempDir, (request) async {
          requests++;
          return http.Response(_manifestJson(), 200);
        });
        final result = await service.install('http://specs.example.com/p.json');
        expect(result, isA<InstallFailed>());
        final error = (result as InstallFailed).error;
        expect(error.kind, SpecPackErrorKind.invalidUrl);
        expect(error.message, contains('https only'));
        expect(
          requests,
          0,
          reason: 'refused before any bytes leave the device',
        );
        expect(await service.listInstalledPacks(), isEmpty);
      },
    );

    test('a plain-http manifest on the local network installs', () async {
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('p.json')) {
          return http.Response(_manifestJson(), 200);
        }
        return http.Response('device_name: Bulb', 200);
      });
      final result = await service.install('http://192.168.1.20:8000/p.json');
      expect(result, isA<InstallOk>());
    });
  });

  group('migrateCacheDir', () {
    test('moves a Documents-era cache into the new base once', () async {
      final legacy = Directory('${tempDir.path}/Documents');
      final base = Directory('${tempDir.path}/Application Support');
      final oldPack = Directory('${legacy.path}/spec_packs/pack-a');
      await oldPack.create(recursive: true);
      await File('${oldPack.path}/a.yaml').writeAsString('device_name: A');

      final resolved = await SpecPackService.migrateCacheDir(
        legacyBase: legacy,
        base: base,
      );

      expect(resolved.path, base.path);
      expect(
        await File('${base.path}/spec_packs/pack-a/a.yaml').readAsString(),
        'device_name: A',
      );
      expect(
        await Directory('${legacy.path}/spec_packs').exists(),
        isFalse,
        reason:
            'moved, not copied: nothing re-downloadable stays in a '
            'backed-up directory',
      );

      // Second launch: nothing to move, same answer.
      expect(
        (await SpecPackService.migrateCacheDir(
          legacyBase: legacy,
          base: base,
        )).path,
        base.path,
      );
    });

    test('a fresh install has nothing to move', () async {
      final legacy = Directory('${tempDir.path}/Documents');
      final base = Directory('${tempDir.path}/Application Support');
      final resolved = await SpecPackService.migrateCacheDir(
        legacyBase: legacy,
        base: base,
      );
      expect(resolved.path, base.path);
      expect(await Directory('${base.path}/spec_packs').exists(), isFalse);
    });

    test(
      'an existing new-base cache is never overwritten by the old one',
      () async {
        final legacy = Directory('${tempDir.path}/Documents');
        final base = Directory('${tempDir.path}/Application Support');
        await Directory(
          '${legacy.path}/spec_packs/old',
        ).create(recursive: true);
        await Directory('${base.path}/spec_packs/new').create(recursive: true);

        await SpecPackService.migrateCacheDir(legacyBase: legacy, base: base);

        expect(await Directory('${base.path}/spec_packs/new').exists(), isTrue);
        expect(
          await Directory('${base.path}/spec_packs/old').exists(),
          isFalse,
        );
        expect(
          await Directory('${legacy.path}/spec_packs/old').exists(),
          isTrue,
          reason: 'left in place rather than merged or clobbered',
        );
      },
    );
  });

  group('cache management', () {
    test('removePack deletes just that pack', () async {
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(_manifestJson(), 200);
        }
        return http.Response('yaml', 200);
      });
      await service.install(_manifestUrl);
      expect(await service.listInstalledPacks(), hasLength(1));

      await service.removePack('Test Pack');
      expect(await service.listInstalledPacks(), isEmpty);
      expect(await service.loadCachedSpecs(), isEmpty);
    });

    test('clearCache removes everything and never throws when empty', () async {
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(_manifestJson(), 200);
        }
        return http.Response('yaml', 200);
      });
      await service.install(_manifestUrl);
      await service.clearCache();
      expect(await service.listInstalledPacks(), isEmpty);

      // Second clear on an already-empty cache is a no-op, not an error.
      await service.clearCache();
      expect(await service.loadCachedSpecs(), isEmpty);
    });

    test('loadCachedSpecs is empty before anything is installed', () async {
      final service = _service(tempDir, (_) async => http.Response('', 200));
      expect(await service.loadCachedSpecs(), isEmpty);
      expect(await service.listInstalledPacks(), isEmpty);
    });
  });

  group('isValidManifestUrl', () {
    test('accepts https anywhere, and http only on the local network', () {
      // F-009: a pack decides what the app sends to LAN devices and which
      // credentials fill it, and nothing on the install path verifies a
      // hash — so a cleartext fetch across the internet is refused, while a
      // laptop serving a pack under development is still reachable.
      expect(
        SpecPackService.isValidManifestUrl('https://a.com/p.json'),
        isTrue,
      );
      expect(
        SpecPackService.isValidManifestUrl('http://a.com/p.json'),
        isFalse,
      );
      expect(
        SpecPackService.manifestUrlProblem('http://a.com/p.json'),
        isA<SpecPackError>()
            .having((e) => e.kind, 'kind', SpecPackErrorKind.invalidUrl)
            .having((e) => e.message, 'message', contains('https only')),
      );
      for (final local in [
        'http://localhost:8000/p.json',
        'http://127.0.0.1:8000/p.json',
        'http://10.1.2.3/p.json',
        'http://172.16.0.9/p.json',
        'http://192.168.1.20:8080/p.json',
        'http://169.254.10.10/p.json',
        'http://[::1]:8000/p.json',
        'http://[fe80::1%25en0]/p.json',
        'http://[fd12::1]/p.json',
      ]) {
        expect(
          SpecPackService.manifestUrlProblem(local),
          isNull,
          reason: '$local is on the local network',
        );
      }
      for (final remote in [
        'http://8.8.8.8/p.json',
        'http://172.32.0.1/p.json',
        'http://[2001:db8::1]/p.json',
        'http://raw.githubusercontent.com/x/p.json',
        'http://mylocalhost.example/p.json',
      ]) {
        expect(
          SpecPackService.isValidManifestUrl(remote),
          isFalse,
          reason: '$remote is not on the local network',
        );
      }
    });

    test('isLocalNetworkHost is decided by the literal, never by DNS', () {
      expect(SpecPackService.isLocalNetworkHost('localhost'), isTrue);
      expect(SpecPackService.isLocalNetworkHost('LOCALHOST'), isTrue);
      expect(SpecPackService.isLocalNetworkHost('pack.localhost'), isTrue);
      expect(SpecPackService.isLocalNetworkHost('192.168.0.1'), isTrue);
      expect(SpecPackService.isLocalNetworkHost('::1'), isTrue);
      expect(SpecPackService.isLocalNetworkHost('fc00::1'), isTrue);
      expect(SpecPackService.isLocalNetworkHost('example.com'), isFalse);
      expect(SpecPackService.isLocalNetworkHost('100.64.0.1'), isFalse);
      expect(SpecPackService.isLocalNetworkHost('::ffff:8.8.8.8'), isFalse);
    });

    test('rejects empty, whitespace, and non-http schemes', () {
      expect(SpecPackService.isValidManifestUrl(''), isFalse);
      expect(SpecPackService.isValidManifestUrl('  '), isFalse);
      expect(SpecPackService.isValidManifestUrl('ftp://a.com/p'), isFalse);
      expect(SpecPackService.isValidManifestUrl('a.com/p'), isFalse);
      expect(SpecPackService.isValidManifestUrl('http://a b.com/p'), isFalse);
    });
  });

  group('SpecPackManifest.tryParse', () {
    test('trims entries and enforces the spec-count cap', () {
      final ok = SpecPackManifest.tryParse(
        _manifestJson(specs: [' bulb.yaml ', 'sensor.yaml']),
      );
      expect(ok!.specs, ['bulb.yaml', 'sensor.yaml']);

      final tooMany = SpecPackManifest.tryParse(
        _manifestJson(
          specs: [
            for (var i = 0; i < SpecPackLimits.maxSpecCount + 1; i++)
              's$i.yaml',
          ],
        ),
      );
      expect(tooMany, isNull);
    });
  });

  group('security - path traversal via pack name', () {
    test(
      "a pack named '..' cannot escape or delete outside the cache root",
      () async {
        // A sentinel next to (outside) the spec_packs root. The pre-fix bug made
        // _packDir('..') resolve to the cache root's parent and delete it.
        final sentinel = File('${tempDir.path}/DO_NOT_DELETE.txt');
        await sentinel.writeAsString('keep me');

        final service = _service(tempDir, (request) async {
          if (request.url.path.endsWith('pack.json')) {
            return http.Response(_manifestJson(name: '..'), 200);
          }
          return http.Response('device_name: Bulb', 200);
        });

        final result = await service.install(_manifestUrl);

        // The install is neutralized to a safe fallback dir, and nothing outside
        // spec_packs is touched.
        expect(result, isA<InstallOk>());
        expect(
          await sentinel.exists(),
          isTrue,
          reason: 'traversal must not delete the parent dir',
        );
        expect(await tempDir.exists(), isTrue);
        final root = Directory('${tempDir.path}/spec_packs');
        final entries = await root.list().toList();
        for (final e in entries) {
          expect(
            _canonical(e.path),
            startsWith(_canonical(root.path)),
            reason: 'every pack dir must live under spec_packs',
          );
        }
      },
    );

    test("a pack named '.' is neutralized to a safe fallback", () async {
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(_manifestJson(name: '.'), 200);
        }
        return http.Response('yaml', 200);
      });
      final result = await service.install(_manifestUrl);
      expect(result, isA<InstallOk>());
      // Stored somewhere strictly inside spec_packs, never AS spec_packs itself.
      final root = Directory('${tempDir.path}/spec_packs');
      final dirs = (await root.list().toList()).whereType<Directory>();
      expect(dirs, isNotEmpty);
      for (final d in dirs) {
        expect(
          _canonical(d.path),
          startsWith('${_canonical(root.path)}${Platform.pathSeparator}'),
        );
      }
    });
  });

  group('security - path traversal via spec filename', () {
    test(
      "a spec entry of '..' is neutralized and stays inside specs/",
      () async {
        final service = _service(tempDir, (request) async {
          if (request.url.path.endsWith('pack.json')) {
            return http.Response(_manifestJson(specs: ['..']), 200);
          }
          return http.Response('device_name: Bulb', 200);
        });

        final result = await service.install(_manifestUrl);
        expect(result, isA<InstallOk>());

        final specsDir = Directory(
          '${tempDir.path}/spec_packs/test_pack/specs',
        );
        final files = (await specsDir.list().toList()).whereType<File>();
        expect(files, isNotEmpty);
        for (final f in files) {
          // No file escaped specs/, and none is literally named '..'.
          expect(
            _canonical(f.path),
            startsWith('${_canonical(specsDir.path)}${Platform.pathSeparator}'),
          );
          expect(f.path.endsWith('${Platform.pathSeparator}..'), isFalse);
        }
        // No stray file landed in the pack dir's parent (the cache root).
        final root = Directory('${tempDir.path}/spec_packs');
        final rootFiles = (await root.list().toList()).whereType<File>();
        expect(rootFiles, isEmpty);
      },
    );
  });

  group('security - SSRF via absolute/cross-origin spec URLs', () {
    test(
      'absolute, scheme-relative, and rooted spec URLs are rejected',
      () async {
        final requestedHosts = <String>[];
        final service = _service(tempDir, (request) async {
          requestedHosts.add(request.url.host);
          if (request.url.path.endsWith('pack.json')) {
            return http.Response(
              _manifestJson(
                specs: [
                  'https://evil.example.net/x.yaml',
                  '//evil.example.net/y.yaml',
                  '/rooted.yaml',
                  'good.yaml',
                ],
              ),
              200,
            );
          }
          return http.Response('device_name: Good', 200);
        });

        final result = await service.install(_manifestUrl);
        expect(result, isA<InstallOk>());
        final ok = result as InstallOk;
        // Only the same-origin relative spec installs.
        expect(ok.pack.specCount, 1);
        expect(ok.partialFailures, hasLength(3));
        // The evil host was never contacted.
        expect(requestedHosts, isNot(contains('evil.example.net')));
        expect(requestedHosts, everyElement('specs.example.com'));
      },
    );

    test('a cross-origin redirect is refused (host never fetched)', () async {
      final requestedHosts = <String>[];
      final service = _service(tempDir, (request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'specs.example.com') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://evil.example.net/pack.json'},
          );
        }
        return http.Response(_manifestJson(), 200);
      });

      final result = await service.install(_manifestUrl);
      expect((result as InstallFailed).error.kind, SpecPackErrorKind.network);
      expect(requestedHosts, isNot(contains('evil.example.net')));
    });

    test(
      'a same-origin redirect that moves the path re-bases the specs',
      () async {
        // /packs/pack.json -> /packs/v2/pack.json: the manifest's relative
        // entries must resolve under /packs/v2/, where the manifest actually
        // came from. Resolving against the URL the user typed fetched
        // /packs/bulb.yaml, which is the 404 below, and the install reported
        // that none of the specs could be downloaded.
        final requested = <String>[];
        final service = _service(tempDir, (request) async {
          final path = request.url.path;
          requested.add(path);
          if (path == '/packs/pack.json') {
            return http.Response(
              '',
              302,
              headers: {'location': '/packs/v2/pack.json'},
            );
          }
          if (path == '/packs/v2/pack.json') {
            return http.Response(_manifestJson(specs: ['bulb.yaml']), 200);
          }
          if (path == '/packs/v2/bulb.yaml') {
            return http.Response('device_name: Bulb', 200);
          }
          return http.Response('not found', 404);
        });
        final result = await service.install(_manifestUrl);
        expect(
          result,
          isA<InstallOk>(),
          reason: '$result — requests were $requested',
        );
        expect(requested, contains('/packs/v2/bulb.yaml'));
        expect(requested, isNot(contains('/packs/bulb.yaml')));
      },
    );

    test('a same-origin redirect is followed', () async {
      final service = _service(tempDir, (request) async {
        final path = request.url.path;
        if (path.endsWith('moved/pack.json')) {
          return http.Response(_manifestJson(specs: ['bulb.yaml']), 200);
        }
        if (path.endsWith('pack.json')) {
          return http.Response(
            '',
            302,
            headers: {'location': 'moved/pack.json'},
          );
        }
        return http.Response('device_name: Bulb', 200);
      });
      final result = await service.install(_manifestUrl);
      expect(result, isA<InstallOk>());
    });
  });

  group('security - size caps', () {
    test('a manifest over the 256KB cap is rejected', () async {
      final huge = jsonEncode({
        'name': 'X',
        'version': '1',
        'specs': <String>[],
        'pad': 'a' * (SpecPackLimits.maxManifestBytes + 10),
      });
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(huge, 200);
        }
        return http.Response('yaml', 200);
      });
      final result = await service.install(_manifestUrl);
      expect((result as InstallFailed).error.kind, SpecPackErrorKind.tooLarge);
    });

    test('specs beyond the 4MB total cap are rejected', () async {
      // 512KB per spec; 8 fill the 4MB budget exactly, the 9th is refused.
      final big = 'a' * SpecPackLimits.maxSpecBytes;
      final specs = [for (var i = 0; i < 9; i++) 's$i.yaml'];
      final service = _service(tempDir, (request) async {
        if (request.url.path.endsWith('pack.json')) {
          return http.Response(_manifestJson(specs: specs), 200);
        }
        return http.Response(big, 200);
      });
      final result = await service.install(_manifestUrl);
      expect(result, isA<InstallOk>());
      final ok = result as InstallOk;
      expect(ok.pack.specCount, 8);
      expect(ok.partialFailures, hasLength(1));
      expect(ok.partialFailures.single.specFile, 's8.yaml');
    });
  });

  group('security - hostile cache never throws', () {
    test('a corrupt manifest.json is skipped, not fatal', () async {
      final packDir = Directory('${tempDir.path}/spec_packs/broken');
      await packDir.create(recursive: true);
      await File(
        '${packDir.path}/manifest.json',
      ).writeAsString('not json at all');

      final service = _service(tempDir, (_) async => http.Response('', 404));
      expect(await service.listInstalledPacks(), isEmpty);
      expect(await service.loadCachedSpecs(), isEmpty);
    });

    test(
      "removePack('..') cannot delete the cache root or its parent",
      () async {
        final sentinel = File('${tempDir.path}/DO_NOT_DELETE.txt');
        await sentinel.writeAsString('keep me');
        final service = _service(tempDir, (request) async {
          if (request.url.path.endsWith('pack.json')) {
            return http.Response(_manifestJson(), 200);
          }
          return http.Response('yaml', 200);
        });
        await service.install(_manifestUrl);

        await service.removePack('..');
        await service.removePack('.');

        expect(await sentinel.exists(), isTrue);
        expect(await Directory('${tempDir.path}/spec_packs').exists(), isTrue);
        // The legitimately-installed pack is untouched.
        expect(await service.listInstalledPacks(), hasLength(1));
      },
    );
  });

  group('security - same-origin is case-insensitive on host', () {
    test(
      'a mixed-case manifest host still accepts its relative specs',
      () async {
        final service = _service(tempDir, (request) async {
          if (request.url.path.endsWith('pack.json')) {
            return http.Response(_manifestJson(specs: ['bulb.yaml']), 200);
          }
          return http.Response('device_name: Bulb', 200);
        });
        final result = await service.install(
          'https://Specs.Example.COM/packs/pack.json',
        );
        expect(result, isA<InstallOk>());
        expect((result as InstallOk).pack.specCount, 1);
      },
    );
  });
}

/// Absolute, dot-segment-normalized path, mirroring the service's own check so
/// the traversal assertions compare like-for-like.
String _canonical(String path) =>
    Uri.file(Directory(path).absolute.path).normalizePath().toFilePath();
