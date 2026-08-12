// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The whole hub story against a live virtual bridge on a real wire: mDNS
// discovery finds it, the link-button flow pairs with it, one GET enumerates
// its lights, a write flips one, and the re-read proves it — through the
// REAL stack at every layer: RealNetworkScanService on real multicast,
// RealSpecCodec through the native Rust library, and HubHttpClient speaking
// actual HTTP to scripts/net_virtual_device.py's CLIP v1 responder.
//
// The unit suites cover each layer against canned data; what only this test
// can catch is the seams — a renderer whose output the transport mangles, an
// envelope the client parses differently than the responder writes, a port
// the SRV record and the listener disagree about.
//
// The virtual bridge plays the v1 round bridge: plain HTTP, no 443 at all,
// which is also what proves the https→http fallback ladder end to end. The
// TLS trust path (CN check, pinning) has its own loopback suite in
// hub_http_client_tls_test.dart.
//
// TAGGED `netdisco` and run by its own CI job, like every test that opens
// 5353/1900 and spends real seconds on the wire.
@Tags(['netdisco'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/services/hub_credential_store.dart';
import 'package:liberated_bread_mobile/services/hub_http_client.dart';
import 'package:liberated_bread_mobile/services/hue_pairing_service.dart';
import 'package:liberated_bread_mobile/services/multicast_lock.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/in_memory_settings_store.dart';
import '../helpers/host_rust_lib.dart';

const _bridgeId = '001788FFFE61FCB0';
const _scanWindow = Duration(seconds: 6);

/// The virtual bridge as a child process, with its link "button".
class _VirtualBridge {
  Process? _process;
  Directory? _work;
  late String address;
  late int port;
  late File _linkFile;

  Future<void> start() async {
    final work = await Directory.systemTemp.createTemp('lb-virtual-hue');
    _work = work;
    final ready = File('${work.path}/ready');
    _linkFile = File('${work.path}/link');
    final scenario = File('${work.path}/scenario.json');
    await scenario.writeAsString(jsonEncode([
      {
        'name': 'Virtual Hue',
        'mdns': [
          {
            'instance': 'Philips Hue - FCB0',
            'type': '_hue._tcp.local',
            'target': 'virtual-hue.local',
            'port': 443,
            'txt': {'bridgeid': _bridgeId, 'modelid': 'BSB001'},
          }
        ],
        'hue': {'bridgeid': _bridgeId, 'modelid': 'BSB001'},
      }
    ]));

    _process = await Process.start('python3', [
      'scripts/net_virtual_device.py',
      '--scenario',
      scenario.path,
      '--ready-file',
      ready.path,
      '--link-file',
      _linkFile.path,
    ]);
    _process!.stdout
        .transform(const SystemEncoding().decoder)
        .listen((line) => printOnFailure('[virtual-hue] $line'));
    final stderrText = StringBuffer();
    _process!.stderr
        .transform(const SystemEncoding().decoder)
        .listen(stderrText.write);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (ready.existsSync()) {
        final info =
            jsonDecode(await ready.readAsString()) as Map<String, dynamic>;
        address = info['address'] as String;
        port =
            (info['hue_ports'] as Map<String, dynamic>)['Virtual Hue'] as int;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError(
        'the virtual bridge did not start within 10s.\n$stderrText');
  }

  /// The button, pressed.
  Future<void> pressLinkButton() => _linkFile.create();

  Future<void> stop() async {
    _process?.kill();
    _process = null;
    await _work?.delete(recursive: true);
    _work = null;
  }
}

void main() {
  // Deliberately NO TestWidgetsFlutterBinding: the binding replaces every
  // dart:io HttpClient with a mock that answers 400, and this test exists
  // to speak real HTTP. Plain `test()` needs no binding, and the Rust
  // library helper opens the .so by path.
  final bridge = _VirtualBridge();
  late final bool rustReady;
  late final String specYaml;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    // The vendored fixture is the spec, verbatim — ahead of the subtree the
    // way network_control tests document.
    specYaml = await File('rust/tests/specs/hue-bridge.yaml').readAsString();
    await bridge.start();
  });
  tearDownAll(bridge.stop);

  test('discover, pair, enumerate, drive, and read it back', () async {
    if (!rustReady) {
      markTestSkipped(
          'host Rust library not built; run scripts/ensure-rust-lib.sh');
      return;
    }

    // ── Discovery: the bridge turns up over real mDNS, with its identity.
    // Up to three windows: multicast resolution on a shared wire can lose a
    // round when anything else is answering (another suite's responder, a
    // developer machine's real devices), and a retry is the honest model of
    // how scanning is used.
    final service = RealNetworkScanService(
        multicastLock: MulticastLock(isSupported: false));
    NetworkDevice? resolved;
    for (var attempt = 0; attempt < 3 && resolved == null; attempt++) {
      final found = <NetworkDevice>[];
      await for (final device in service.scan(timeout: _scanWindow)) {
        found.add(device);
      }
      final sightings =
          found.where((device) => device.txt['bridgeid'] == _bridgeId);
      if (sightings.isNotEmpty) resolved = sightings.last;
    }
    final sighting = resolved ??
        (throw StateError('the virtual bridge never appeared in three scans'));
    expect(sighting.port, bridge.port,
        reason: 'the SRV record must advertise the real listener');

    // ── The controls the spec declares, through the native codec.
    const codec = RealSpecCodec();
    final entities = await codec
        .networkEntitiesForDevice(specYaml: specYaml, ssdpTargets: const []);
    expect(entities, hasLength(1));
    final light = entities.single;
    expect(light.transport, 'http');
    expect(light.isInstanced, isTrue);

    // ── Pairing: poll, press the button mid-window, keep what was issued.
    final store = HubCredentialStore(InMemorySettingsStore());
    // No 443 at all on this bridge: an https probe must get connection
    // refused (a genuinely closed port) and fall back — the BSB001 ladder.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    final client = HubHttpClient(
      credentials: store,
      httpsPort: closedPort,
      httpPort: bridge.port,
    );

    final pairing = HuePairingService(codec: codec, client: client);
    var pressed = false;
    final result = await pairing.pair(
      specYaml: specYaml,
      host: sighting.host,
      bridgeId: _bridgeId,
      window: const Duration(seconds: 20),
      interval: const Duration(milliseconds: 200),
      onAttempt: (attempt) {
        // The first poll proves the 101 path; then the button is pressed.
        if (attempt == 2 && !pressed) {
          pressed = true;
          bridge.pressLinkButton();
        }
      },
    );
    expect(result.username, isNotEmpty);
    expect(result.clientKey, isNotEmpty,
        reason: 'generateclientkey rides along unconditionally');
    await store.saveCredentials(_bridgeId,
        HubCredentials(username: result.username, clientKey: result.clientKey));
    expect(await store.scheme(_bridgeId), 'http',
        reason: 'the no-443 fallback is remembered, not re-probed');

    // ── Enumerate: one GET carries every light and all their state.
    Future<(List<NetworkInstanceDto>, String)> readLights() async {
      final request = await codec.renderNetworkHttpStateRequest(
        specYaml: specYaml,
        stateCommand: light.stateCommand,
        values: {'username': result.username},
      );
      final body = await client.send(sighting.host, _bridgeId, request);
      final children = await codec.listNetworkInstances(
          specYaml: specYaml, entityName: light.name, stateReply: body);
      return (children, body);
    }

    var (children, body) = await readLights();
    expect(children.map((c) => c.label), ['Kitchen counter', 'Hallway']);

    Future<Map<String, NetworkReadingDto>> readingsOf(
        String body, String id) async {
      final readings = await codec.readNetworkInstance(
        specYaml: specYaml,
        entityName: light.name,
        stateReply: body,
        instanceId: id,
      );
      return {for (final r in readings) r.role: r.reading};
    }

    var hallway = await readingsOf(body, '2');
    expect(hallway['is_on']?.isOn, isFalse);
    expect(hallway['brightness']?.number, 77);

    // ── Drive: turn the hallway light on, then set its brightness.
    Future<void> send(String command, Map<String, String> extra) async {
      final request = await codec.renderNetworkHttpCommand(
        specYaml: specYaml,
        commandName: command,
        values: {'username': result.username, 'id': '2', ...extra},
      );
      await client.send(sighting.host, _bridgeId, request);
    }

    await send('light_turn_on', const {});
    (children, body) = await readLights();
    hallway = await readingsOf(body, '2');
    expect(hallway['is_on']?.isOn, isTrue,
        reason: 'the write acknowledged; the re-read is what proves it');

    await send('light_set_brightness', const {'bri': '200'});
    (children, body) = await readLights();
    hallway = await readingsOf(body, '2');
    expect(hallway['brightness']?.number, 200);

    // ── And the visible failure: a stale credential answers error 1.
    final stale = await codec.renderNetworkHttpStateRequest(
      specYaml: specYaml,
      stateCommand: light.stateCommand,
      values: const {'username': 'somebody-else'},
    );
    await expectLater(
      client.send(sighting.host, _bridgeId, stale),
      throwsA(isA<HubAuthException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
