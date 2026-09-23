// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What this file measures is not throughput. It is the SYNCHRONOUS share of
// each call — the microseconds spent on the calling isolate before the first
// await, encoding arguments and decoding results — because that is the
// number the user sees. Every flutter_rust_bridge function here is
// `executeNormal`: Rust runs on a thread pool, but the wire is serialized and
// deserialized on the isolate that called, and on the UI isolate that is a
// frame.
//
// The findings this pins (F-024, F-025) were exactly that: the catalogue
// crossing as 203 `DeviceSpecDto`s blocked the isolate ~71 ms before the
// first await, a `matchDeviceToSpec` over all of them ~16-31 ms per call, and
// a notification decode re-encoded up to 123 KB of YAML per subscribed widget
// per packet.
//
// The budgets are deliberately loose — this runs on whatever CI is holding —
// and sized to catch a return to by-value marshalling (a 20x regression),
// not a slow machine. The printed lines are the useful part; the assertions
// are the tripwire.
//
// Requires the host-target Rust library; skipped without it.
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart' as rust;

import '../helpers/host_rust_lib.dart';
import 'spec_catalogue_golden_test.dart' show bundledSpecs;

/// Run [body] and report how long it blocked the isolate BEFORE its first
/// await, alongside how long the whole thing took.
///
/// The split is the whole point: a call that takes 20 ms but blocks for 200 us
/// costs no frames, and a call that takes 20 ms while blocking for 18 of them
/// costs two.
Future<({int syncUs, int totalUs})> _timed(Future<void> Function() body) async {
  final watch = Stopwatch()..start();
  final future = body();
  final syncUs = watch.elapsedMicroseconds;
  await future;
  return (syncUs: syncUs, totalUs: watch.elapsedMicroseconds);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final bool rustReady;
  late final Map<String, String> specs;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    specs = await bundledSpecs();
  });

  test(
    'loading the catalogue does not block the isolate in one burst',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final codec = RealSpecCodec();
      final yamlBytes = specs.values.fold(0, (n, y) => n + y.length);

      // BEFORE: what the app did — one loadDeviceSpec per spec, all in flight
      // together, every result decoded into a full DeviceSpecDto on this
      // isolate.
      final before = await _timed(() async {
        await Future.wait([
          for (final yaml in specs.values) codec.loadDeviceSpec(yaml),
        ]);
      });

      // AFTER: the catalogue is parsed and kept on the far side, in chunks, and
      // what comes back is one light entry per spec.
      final after = await _timed(() async {
        await codec.loadCatalogue(specs);
      });

      // ignore: avoid_print
      print(
        'catalogue load (${specs.length} specs, $yamlBytes chars of YAML): '
        'by value ${before.syncUs} us sync / ${before.totalUs} us total; '
        'by handle ${after.syncUs} us sync / ${after.totalUs} us total',
      );

      // Each chunk yields to the event loop, so no single burst may approach a
      // frame's worth of the isolate. (The by-value path measured ~71 ms here
      // on an Apple Silicon host.)
      expect(
        after.syncUs,
        lessThan(25000),
        reason: 'the chunked load blocked the isolate for one long stretch',
      );
      expect(
        after.syncUs,
        lessThan(before.syncUs),
        reason: 'the handle load blocks the isolate more than the by-value one',
      );
    },
  );

  test(
    'matching a connected device sends two strings, not the catalogue',
    () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final codec = RealSpecCodec();
      final catalogue = await codec.loadCatalogue(specs);
      final dtos = <DeviceSpecDto>[
        for (final entry in catalogue.specs)
          await codec.loadDeviceSpec(entry.yaml),
      ];
      const name = 'ACME_1234';
      const uuids = ['0000fff0-0000-1000-8000-00805f9b34fb'];

      // Warm both paths once: the first call of either pays one-off costs
      // (thread-pool spin-up, the spec cache filling) that say nothing about
      // the steady state a connect repeats.
      await codec.matchDeviceToSpec(
        specs: dtos,
        deviceName: name,
        advertisedServiceUuids: uuids,
      );
      await catalogue.matchDevice(deviceName: name, serviceUuids: uuids);

      var beforeSync = 0;
      var afterSync = 0;
      const runs = 5;
      for (var i = 0; i < runs; i++) {
        beforeSync += (await _timed(
          () => codec.matchDeviceToSpec(
            specs: dtos,
            deviceName: name,
            advertisedServiceUuids: uuids,
          ),
        )).syncUs;
        afterSync += (await _timed(
          () => catalogue.matchDevice(deviceName: name, serviceUuids: uuids),
        )).syncUs;
      }
      // ignore: avoid_print
      print(
        'match against ${catalogue.specs.length} specs: '
        'by value ${beforeSync ~/ runs} us sync/call; '
        'by handle ${afterSync ~/ runs} us sync/call',
      );

      // Relative, not a wall-clock number: an absolute microsecond budget in
      // the ordinary unit lane went red on a busy runner with no code change
      // and would stay green after a regression smaller than its margin.
      // The by-value path is measured in the same process moments earlier,
      // so a fifth of it is a bound that moves with the host.
      expect(
        afterSync ~/ runs,
        lessThan(max(1, beforeSync ~/ runs ~/ 5)),
        reason: 'a match is back to marshalling the catalogue',
      );
    },
  );

  test('a notification decode does not re-send the spec', () async {
    if (!rustReady) {
      markTestSkipped('Rust lib not loaded');
      return;
    }
    // The largest bundled specs are the ones that hurt: a chatty notify
    // characteristic on an 85 KB spec re-encoded it per packet per widget.
    final biggest = specs.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final yaml =
        specs['vendor/protocol-specs/device-specs/examples/example-bulb.yaml']!;
    const service = '0000fff0-0000-1000-8000-00805f9b34fb';
    const statusChar = '0000fff2-0000-1000-8000-00805f9b34fb';

    final codec = RealSpecCodec();
    // BEFORE: the generated by-value call, which is what every decode was.
    await rust.decodeValue(
      specYaml: yaml,
      serviceUuid: service,
      charUuid: statusChar,
      bytes: [1, 80, 255, 180, 50],
    );
    await codec.prepareSpec(yaml);

    var beforeSync = 0;
    var afterSync = 0;
    const runs = 20;
    for (var i = 0; i < runs; i++) {
      beforeSync += (await _timed(
        () => rust.decodeValue(
          specYaml: yaml,
          serviceUuid: service,
          charUuid: statusChar,
          bytes: [1, 80, 255, 180, i],
        ),
      )).syncUs;
      afterSync += (await _timed(
        () => codec.decodeValue(
          specYaml: yaml,
          serviceUuid: service,
          charUuid: statusChar,
          bytes: [1, 80, 255, 180, i],
        ),
      )).syncUs;
    }
    // And the headline number for F-025, on the spec that actually hurt: the
    // largest bundled one. The characteristic does not exist in it, so both
    // calls fail — deliberately. What is being measured is the marshalling
    // either side of the failure, which is all a notification decode ever
    // paid the by-value path for.
    final bigYaml = biggest.first.value;
    final bigHandle = RealSpecCodec();
    await bigHandle.prepareSpec(bigYaml);
    Future<void> swallow(Future<Object?> call) =>
        call.then((_) {}, onError: (Object _) {});
    var bigBefore = 0;
    var bigAfter = 0;
    for (var i = 0; i < runs; i++) {
      bigBefore += (await _timed(
        () => swallow(
          rust.decodeValue(
            specYaml: bigYaml,
            charUuid: 'no-such-characteristic',
            bytes: [i],
          ),
        ),
      )).syncUs;
      bigAfter += (await _timed(
        () => swallow(
          bigHandle.decodeValue(
            specYaml: bigYaml,
            charUuid: 'no-such-characteristic',
            bytes: [i],
          ),
        ),
      )).syncUs;
    }
    // ignore: avoid_print
    print(
      'marshalling one decode against the largest bundled spec '
      '(${biggest.first.key.split('/').last}, ${bigYaml.length} chars): '
      'by value ${bigBefore / runs} us sync/call; '
      'by handle ${bigAfter / runs} us sync/call',
    );
    expect(
      bigAfter ~/ runs,
      lessThan(bigBefore ~/ runs),
      reason: 'the handle path marshals more than the by-value path',
    );

    // ignore: avoid_print
    print(
      'decode one packet (${yaml.length}-char spec): '
      'by value ${beforeSync / runs} us sync/call; '
      'by handle ${afterSync / runs} us sync/call '
      '(largest bundled spec is ${biggest.first.value.length} chars, '
      'which the by-value path would have re-encoded per packet per widget)',
    );

    expect(
      afterSync ~/ runs,
      lessThan(max(1, beforeSync ~/ runs ~/ 5)),
      reason: 'a decode is back to re-encoding the spec',
    );
  });
}
