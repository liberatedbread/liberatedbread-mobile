// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Wi-Fi tab's adoption entry point. Two things matter: it says the right
// thing in each state, and it comes alive only when the OS actually sees a
// setup network — so the spinning hint never lies on a platform (or a moment)
// where nothing is there.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/adopt_provider.dart';
import 'package:liberated_bread_mobile/services/adopt_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart';
import 'package:liberated_bread_mobile/widgets/adopt_device_card.dart';

final _wemoDevice = AdoptableDevice(
  profile: SoftApProfileDto(
    specName: 'Belkin Wemo Smart Devices',
    category: 'switch',
    methodType: 'softap_soap',
    ssidPrefix: 'Wemo.',
    ssidExamples: const [],
    openNetwork: true,
    gatewayIp: '10.22.22.1',
    ports: Uint16List.fromList(const [49153]),
  ),
  specYaml: 'yaml',
  family: AdoptFamily.wemo,
);

Widget _wrap({AdoptableDevice? nearby, required VoidCallback onTap}) =>
    ProviderScope(
      overrides: [
        nearbySetupNetworkProvider.overrideWith((ref) => Stream.value(nearby)),
      ],
      child: MaterialApp(
        home: Scaffold(body: AdoptDeviceCard(onTap: onTap)),
      ),
    );

void main() {
  testWidgets('reads as a plain button when nothing is nearby', (tester) async {
    await tester.pumpWidget(_wrap(nearby: null, onTap: () {}));
    await tester.pump(); // let the stream deliver

    expect(find.text('Adopt a new Wi-Fi device'), findsOneWidget);
    expect(find.text('Set up a reset Wemo or LIFX device on your Wi-Fi'),
        findsOneWidget);
    expect(find.textContaining('in range'), findsNothing);
  });

  testWidgets('announces a setup network the OS can see', (tester) async {
    await tester.pumpWidget(_wrap(nearby: _wemoDevice, onTap: () {}));
    await tester.pump();

    expect(find.textContaining('"Wemo.…" setup network is in range'),
        findsOneWidget);
  });

  testWidgets('tapping invokes the callback', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_wrap(nearby: null, onTap: () => tapped = true));
    await tester.pump();

    await tester.tap(find.byType(AdoptDeviceCard));
    expect(tapped, isTrue);
  });

  testWidgets('the icon animates while a network is nearby', (tester) async {
    await tester.pumpWidget(_wrap(nearby: _wemoDevice, onTap: () {}));
    await tester.pump();
    final rotation = tester
        .widget<RotationTransition>(find.byKey(const ValueKey('adopt-spin')));
    // A repeating controller reports itself as animating; a stopped one does
    // not. The card drives the controller straight from the hint, so "nearby"
    // must leave it running.
    expect(rotation.turns.isAnimating, isTrue);
    // Stop the pending animation frames so the test can settle.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the icon is still when nothing is nearby', (tester) async {
    await tester.pumpWidget(_wrap(nearby: null, onTap: () {}));
    await tester.pump();
    final rotation = tester
        .widget<RotationTransition>(find.byKey(const ValueKey('adopt-spin')));
    expect(rotation.turns.isAnimating, isFalse);
  });
}
