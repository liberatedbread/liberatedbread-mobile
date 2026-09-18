// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The catalogue moved into Rust, and two paths now answer the same questions:
// the handle path ([RustSpecCatalogue], which keeps the parse on the far side
// and returns indices) and the by-value path ([FallbackSpecCatalogue], which
// parses each spec into a DTO and matches over those). The second is what the
// app did before, and what every codec without native handles — the fakes the
// widget suite runs on — still does.
//
// So they must agree, over the real catalogue rather than a fixture: this is
// where a field dropped from the identity projection, or an axis that drifted
// between `match_device_to_spec` and `CatalogueHandle::match_device`, is
// caught. Requires the host-target Rust library; skipped without it.
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart' as rust;
import 'package:liberated_bread_mobile/src/rust/api/spec_handle.dart'
    as handles;

import '../helpers/host_rust_lib.dart';

/// Every bundled device spec, read straight out of the asset manifest rather
/// than through the index: the point is to compare the two paths over as much
/// real YAML as the build carries.
Future<Map<String, String>> bundledSpecs() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final paths =
      manifest
          .listAssets()
          .where(
            (asset) =>
                asset.startsWith('vendor/protocol-specs/device-specs/') &&
                asset.endsWith('.yaml'),
          )
          .toList()
        ..sort();
  return {for (final path in paths) path: await rootBundle.loadString(path)};
}

/// One identity as a comparable string.
///
/// Field by field rather than `==`: the generated `SpecIdentityDto ==`
/// compares its List fields by reference, which no FFI round trip preserves,
/// so it would report every identity unequal.
String identityDigest(SpecIdentityDto i) => [
  i.deviceName,
  i.manufacturer,
  i.category,
  i.pictogram,
  i.adminUrl,
  i.integration,
  i.securityAdvisory?.severity,
  i.securityAdvisory?.summary,
  i.localNamePrefixes.join(','),
  i.localNames.join(','),
  i.serviceUuids.join(','),
  i.companyIds.join(','),
  [for (final m in i.macPrefixes) '${m.prefix}:${m.confidence}'].join(','),
  i.mdnsServiceTypes.join(','),
  i.ssdpSearchTargets.join(','),
  i.lanProtocols.join(','),
  i.defaultPort,
  [for (final m in i.nameMatchers) '${m.kind}:${m.value}'].join(','),
  [
    for (final g in i.txtMatchGroups)
      '${g.serviceTypes.join('/')}:'
          '${g.conditions.map((c) => '${c.key}=${c.value}').join('&')}',
  ].join(','),
  i.platformFallbackTypes.join(','),
].join('');

String entryDigest(CatalogueSpec e) => [
  e.key,
  e.protocolHandler,
  e.gattServiceUuids.join(','),
  identityDigest(e.identity),
].join('');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final Map<String, String> specs;
  late final RealSpecCodec codec;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    specs = await bundledSpecs();
    codec = RealSpecCodec();
  });

  test('the bundle carries a catalogue worth comparing', () async {
    // Guards the rest of this file: every comparison below is vacuous if the
    // build bundled nothing, and a silently empty catalogue is exactly the
    // failure these tests exist to notice.
    expect(specs.length, greaterThan(50));
  });

  test(
    'the handle catalogue and the by-value catalogue see the same specs',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final handled = await codec.loadCatalogue(specs);
      final byValue = await FallbackSpecCatalogue.load(codec, specs);

      expect(
        handled.specs.length,
        byValue.specs.length,
        reason: 'the two loaders kept a different number of specs',
      );
      expect(
        handled.failures.map((f) => f.key).toList(),
        byValue.failures.map((f) => f.key).toList(),
        reason: 'the two loaders rejected different specs',
      );
      for (var i = 0; i < handled.specs.length; i++) {
        expect(
          entryDigest(handled.specs[i]),
          entryDigest(byValue.specs[i]),
          reason:
              'entry $i (${handled.specs[i].key}) differs between the '
              'handle catalogue and the by-value catalogue',
        );
        expect(handled.specs[i].index, i);
        expect(handled.specs[i].yaml, byValue.specs[i].yaml);
      }
    },
  );

  test('both catalogues match every spec\'s own device the same way', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    final handled = await codec.loadCatalogue(specs);
    final byValue = await FallbackSpecCatalogue.load(codec, specs);

    // Every spec that declares a name prefix or a service UUID becomes a
    // device that should match it — which is far more matching than any
    // hand-written fixture, and includes the cross-spec collisions (shared
    // platform services, two-letter prefixes) the ranking rules exist for.
    var devicesTried = 0;
    for (final entry in handled.specs) {
      final prefix = entry.identity.localNamePrefixes.firstOrNull;
      final uuids = entry.identity.serviceUuids;
      if (prefix == null && uuids.isEmpty) continue;
      devicesTried++;
      final name = '${prefix ?? ''}unit-1';
      final a = await handled.matchDevice(
        deviceName: name,
        serviceUuids: uuids,
      );
      final b = await byValue.matchDevice(
        deviceName: name,
        serviceUuids: uuids,
      );
      String digest(List<SpecMatch> matches) => [
        for (final m in matches)
          '${m.entry.index}/${m.matchedByNamePrefix}/${m.confidence}/'
              '${m.matchedServiceUuids.join(',')}',
      ].join(' ');
      expect(
        digest(a),
        digest(b),
        reason:
            'matching "$name" against ${entry.key} differs between the '
            'handle catalogue and the by-value catalogue',
      );
      expect(
        a,
        isNotEmpty,
        reason: '${entry.key} does not match its own device',
      );
    }
    expect(devicesTried, greaterThan(50));
  });

  test(
    'specAt returns what loadDeviceSpec returns, and holds the parse',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final catalogue = await codec.loadCatalogue(specs);
      // A spread across the catalogue rather than all of it: building 200 full
      // DTOs is the cost this whole change exists to avoid paying, and the
      // conversion is the same code for every spec.
      for (var i = 0; i < catalogue.specs.length; i += 17) {
        final entry = catalogue.specs[i];
        final viaIndex = await catalogue.specAt(i);
        final viaYaml = await codec.loadDeviceSpec(entry.yaml);
        expect(viaIndex.deviceName, viaYaml.deviceName, reason: entry.key);
        expect(viaIndex.manufacturer, viaYaml.manufacturer, reason: entry.key);
        expect(
          viaIndex.entities.map((e) => e.name).toList(),
          viaYaml.entities.map((e) => e.name).toList(),
          reason: entry.key,
        );
        expect(
          viaIndex.services.map((s) => s.uuid).toList(),
          viaYaml.services.map((s) => s.uuid).toList(),
          reason: entry.key,
        );
      }
    },
  );

  group('one spec, two doors', () {
    const bulb =
        'vendor/protocol-specs/device-specs/examples/'
        'example-bulb.yaml';
    const service = '0000fff0-0000-1000-8000-00805f9b34fb';
    const statusChar = '0000fff2-0000-1000-8000-00805f9b34fb';

    test(
      'a decode through a handle matches a decode through the YAML',
      () async {
        if (!rustReady) {
          markTestSkipped('Rust lib not loaded');
          return;
        }
        final yaml = specs[bulb]!;
        final handle = await handles.loadSpec(yaml: yaml);
        for (final bytes in const [
          [1, 80, 255, 180, 50],
          [0, 0, 0, 0, 0],
          [1, 100, 12, 34, 56],
        ]) {
          final throughHandle = await handle.decodeValue(
            serviceUuid: service,
            charUuid: statusChar,
            bytes: bytes,
          );
          final throughYaml = await rust.decodeValue(
            specYaml: yaml,
            serviceUuid: service,
            charUuid: statusChar,
            // A distinct list instance, so nothing can be served from the
            // codec's per-packet memo.
            bytes: List<int>.of(bytes),
          );
          expect(throughHandle.length, throughYaml.length, reason: '$bytes');
          for (var i = 0; i < throughHandle.length; i++) {
            expect(throughHandle[i].name, throughYaml[i].name);
            expect(throughHandle[i].uintValue, throughYaml[i].uintValue);
            expect(throughHandle[i].intValue, throughYaml[i].intValue);
            expect(throughHandle[i].decodedText, throughYaml[i].decodedText);
            expect(
              throughHandle[i].decodedNumber,
              throughYaml[i].decodedNumber,
            );
          }
        }
      },
    );

    test('the codec decodes the same values once it holds the parse', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final yaml = specs[bulb]!;
      // Cold: nothing held, so this one goes by value.
      final cold = await codec.decodeValue(
        specYaml: yaml,
        serviceUuid: service,
        charUuid: statusChar,
        bytes: [1, 80, 255, 180, 50],
      );
      await codec.prepareSpec(yaml);
      final warm = await codec.decodeValue(
        specYaml: yaml,
        serviceUuid: service,
        charUuid: statusChar,
        bytes: [1, 80, 255, 180, 50],
      );
      expect(warm.map((v) => '${v.name}=${v.decodedText}').toList(), [
        for (final v in cold) '${v.name}=${v.decodedText}',
      ]);
      expect(warm, isNotEmpty);
    });

    test('one packet is decoded once however many widgets ask', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final yaml = specs[bulb]!;
      // Its own codec, so the memo's bookkeeping is this test's alone.
      final owned = RealSpecCodec();
      await owned.prepareSpec(yaml);
      // The one list instance the BLE layer fans out to every subscriber.
      final packet = [1, 80, 255, 180, 50];
      final readings = await Future.wait([
        for (var i = 0; i < 7; i++)
          owned.decodeValue(
            specYaml: yaml,
            serviceUuid: service,
            charUuid: statusChar,
            bytes: packet,
          ),
      ]);
      expect(
        owned.memoisedPacketCount,
        1,
        reason: 'seven subscribers, one packet, one decode',
      );
      for (var i = 0; i < readings.length; i++) {
        expect(
          readings[i].map((v) => '${v.name}=${v.decodedText}').toList(),
          readings.first.map((v) => '${v.name}=${v.decodedText}').toList(),
        );
        // Each subscriber owns its list: one widget sorting or trimming what
        // it was handed must not reach into another's reading.
        if (i > 0) expect(identical(readings[i], readings.first), isFalse);
      }

      // A different packet is a different decode — the memo remembers, it
      // does not answer for bytes it has not seen.
      await owned.decodeValue(
        specYaml: yaml,
        serviceUuid: service,
        charUuid: statusChar,
        bytes: [0, 0, 0, 0, 0],
      );
      expect(owned.memoisedPacketCount, 2);
    });

    test('a disposed handle refuses to be used again', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final handle = await handles.loadSpec(yaml: specs[bulb]!);
      expect(handle.isDisposed, isFalse);
      expect((await handle.dto()).deviceName, isNotEmpty);
      handle.dispose();
      expect(handle.isDisposed, isTrue);
      // Thrown where the pointer is read, so it is a synchronous refusal,
      // not a rejected future — which matters: a caller that never awaits
      // still cannot use a released Arc.
      expect(handle.dto, throwsA(isA<Object>()));
      // Idempotent: a second dispose must not double-release the Arc.
      handle.dispose();
      expect(handle.isDisposed, isTrue);
    });

    test('the codec stops serving a handle its owner disposed', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final yaml = specs[bulb]!;
      final owned = RealSpecCodec();
      final handle = await handles.loadSpec(yaml: yaml);
      owned.hold(yaml, handle);
      expect(owned.heldParseCount, 1);
      handle.dispose();
      // The held parse is gone, so this must fall back to the by-value call
      // rather than throwing a use-after-dispose into a sensor tile.
      final decoded = await owned.decodeValue(
        specYaml: yaml,
        serviceUuid: service,
        charUuid: statusChar,
        bytes: [1, 80, 255, 180, 50],
      );
      expect(decoded, isNotEmpty);
      expect(
        owned.heldParseCount,
        0,
        reason: 'the disposed parse was dropped rather than served again',
      );
    });
  });
}
