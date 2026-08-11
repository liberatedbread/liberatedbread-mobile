// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/lifx_provisioning_screen.dart';
import 'package:liberated_bread_mobile/services/lifx_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

/// A client that answers `collect` with canned replies (no socket, no waiting)
/// and records the credential send.
class _FakeLifxClient extends LifxControlClient {
  final List<({String host, List<int> packet})> sent = [];
  List<Uint8List> collectReplies = [Uint8List(41)];
  int _seq = 0;

  @override
  int nextSequence() => ++_seq;

  @override
  Future<void> send(String host, Uint8List packet, {int sends = 2}) async {
    sent.add((host: host, packet: packet));
  }

  @override
  Future<List<Uint8List>> collect(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration window = const Duration(seconds: 5),
    int sends = 2,
  }) async =>
      collectReplies;
}

Widget _wrap(FakeSpecCodec codec, _FakeLifxClient client) => ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(codec),
        lifxControlClientProvider.overrideWithValue(client),
      ],
      child: const MaterialApp(home: LifxProvisioningScreen()),
    );

void main() {
  testWidgets('drives the SoftAP flow: scan, pick, send credentials',
      (tester) async {
    final codec = FakeSpecCodec()
      ..lifxAccessPoint = const LifxAccessPointDto(
        ssid: 'HomeNet',
        security: 5,
        strength: -40,
        channel: 11,
      );
    final client = _FakeLifxClient();
    await tester.pumpWidget(_wrap(codec, client));

    // Step 1: join the AP.
    await tester.tap(find.text('I’ve joined the LIFX network'));
    await tester.pumpAndSettle();

    // Step 2: the scanned network shows up; pick it.
    expect(find.text('HomeNet'), findsOneWidget);
    await tester.tap(find.text('HomeNet'));
    await tester.pumpAndSettle();

    // Step 3: enter the password and send.
    await tester.enterText(find.byType(TextField), 's3cr3t');
    await tester.tap(find.text('Send to the strip'));
    await tester.pumpAndSettle();

    // The credentials were handed over exactly once, with what we chose.
    expect(client.sent, hasLength(1));
    expect(codec.setAccessPointCalls, hasLength(1));
    final call = codec.setAccessPointCalls.single;
    expect(call.ssid, 'HomeNet');
    expect(call.password, 's3cr3t');
    expect(call.security, 5);

    expect(find.text('Credentials sent'), findsOneWidget);
  });

  testWidgets('no scanned networks falls through to manual entry',
      (tester) async {
    final codec = FakeSpecCodec();
    final client = _FakeLifxClient()..collectReplies = const [];
    await tester.pumpWidget(_wrap(codec, client));

    await tester.tap(find.text('I’ve joined the LIFX network'));
    await tester.pumpAndSettle();

    // With nothing found, the manual SSID field is shown directly.
    expect(
        find.widgetWithText(TextField, 'Network name (SSID)'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'MyNetwork');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'pw12345678');
    await tester.tap(find.text('Send to the strip'));
    await tester.pumpAndSettle();

    final call = codec.setAccessPointCalls.single;
    expect(call.ssid, 'MyNetwork');
    // A manual SSID uses the WPA2-AES default (5).
    expect(call.security, 5);
  });
}
