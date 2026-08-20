// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The adoption screen's first stage — the instruction screen and the device
// picker. This is the part a user always sees; the provisioning stages past it
// are exercised through AdoptService in adopt_service_test. The claims here are
// that the screen explains the manual step it depends on (joining the setup AP
// in Settings, which no app can do for the user) and offers the families the
// catalogue says are adoptable, highlighting one the OS reports in range.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/adopt_provider.dart';
import 'package:liberated_bread_mobile/screens/adopt_device_screen.dart';
import 'package:liberated_bread_mobile/services/adopt_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart';

AdoptableDevice _device(String name, String prefix, String category,
        AdoptFamily family, String method) =>
    AdoptableDevice(
      profile: SoftApProfileDto(
        specName: name,
        category: category,
        methodType: method,
        ssidPrefix: prefix,
        ssidExamples: const [],
        openNetwork: true,
        gatewayIp: null,
        ports: Uint16List(0),
      ),
      specYaml: 'yaml',
      family: family,
    );

final _wemo = _device('Belkin Wemo Smart Devices', 'Wemo.', 'switch',
    AdoptFamily.wemo, 'softap_soap');
final _lifx =
    _device('LIFX Z', 'LIFX', 'light', AdoptFamily.lifx, 'softap_udp');

Widget _wrap({
  List<AdoptableDevice> devices = const [],
  AdoptableDevice? nearby,
}) =>
    ProviderScope(
      overrides: [
        adoptableDevicesProvider.overrideWith((ref) async => devices),
        nearbySetupNetworkProvider.overrideWith((ref) => Stream.value(nearby)),
      ],
      child: const MaterialApp(home: AdoptDeviceScreen()),
    );

void main() {
  testWidgets('explains the manual join step and offers Settings',
      (tester) async {
    await tester.pumpWidget(_wrap(devices: [_wemo, _lifx]));
    await tester.pumpAndSettle();

    expect(find.text('Adopt a Wi-Fi device'), findsOneWidget); // app bar
    expect(find.textContaining('Factory reset'), findsOneWidget);
    expect(find.textContaining('join that network'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Open Settings'), findsOneWidget);
  });

  testWidgets('lists every adoptable family with its setup prefix',
      (tester) async {
    await tester.pumpWidget(_wrap(devices: [_wemo, _lifx]));
    await tester.pumpAndSettle();

    expect(find.text('Belkin Wemo Smart Devices'), findsOneWidget);
    expect(find.text('LIFX Z'), findsOneWidget);
    expect(find.textContaining('"Wemo.…"'), findsOneWidget);
    expect(find.textContaining('"LIFX…"'), findsOneWidget);
  });

  testWidgets('highlights the family whose setup network is in range',
      (tester) async {
    await tester.pumpWidget(_wrap(devices: [_wemo, _lifx], nearby: _wemo));
    await tester.pumpAndSettle();

    // The nearby family gets the "in range now" subtitle; the other keeps the
    // plain "starts with" one.
    expect(find.textContaining('in range now'), findsOneWidget);
    expect(
      find.textContaining('Setup network "Wemo.…" is in range now'),
      findsOneWidget,
    );
  });

  testWidgets('says so when the catalogue has no adoptable devices',
      (tester) async {
    await tester.pumpWidget(_wrap(devices: const []));
    await tester.pumpAndSettle();

    expect(find.textContaining('No adoptable device types'), findsOneWidget);
  });
}
