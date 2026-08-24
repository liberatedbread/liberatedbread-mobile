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

BleAdoptableDevice _bleDevice(
  String name,
  String advertisedName,
  String category,
  String? handler,
) =>
    BleAdoptableDevice(
      profile: BleProvisioningProfileDto(
        specName: name,
        category: category,
        advertisedName: advertisedName,
        exactName: true,
        serviceUuid: '366048ae-9f36-43cf-8004-010c0c9fa52e',
        writeCharacteristic: '53ef7d7d-c244-42bd-9064-a1569a521ca9',
        readCharacteristic: '53ef7d7d-c244-42bd-9064-a1569a521ca9',
        mtu: 515,
      ),
      specYaml: 'yaml',
      protocolHandler: handler,
    );

final _rabbitAir = _bleDevice(
    'Rabbit Air Purifier', 'RabbitAirSetup', 'fan', 'rabbit_air_lan');

Widget _wrap({
  List<AdoptableDevice> devices = const [],
  AdoptableDevice? nearby,
  List<BleAdoptableDevice> bleDevices = const [],
}) =>
    ProviderScope(
      overrides: [
        adoptableDevicesProvider.overrideWith((ref) async => devices),
        nearbySetupNetworkProvider.overrideWith((ref) => Stream.value(nearby)),
        bleAdoptableDevicesProvider.overrideWith((ref) async => bleDevices),
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

  // ── The Bluetooth-provisioned families ──────────────────────────────────
  // These have no setup network to join, so they sit in their own section —
  // built from the catalogue, not written into the screen.

  /// The picker is a lazy [ListView] and this section sits below the fold in a
  /// test viewport, so it has to be scrolled to before it is built at all.
  Future<void> scrollToBleSection(WidgetTester tester) =>
      tester.dragUntilVisible(
        find.text('Sets up over Bluetooth instead'),
        find.byType(ListView),
        const Offset(0, -200),
      );

  /// Drag to the end of the list, so a "not found" below means absent rather
  /// than merely unbuilt.
  Future<void> scrollToEnd(WidgetTester tester) async {
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
  }

  testWidgets('lists a BLE-provisioned family from the catalogue',
      (tester) async {
    await tester.pumpWidget(_wrap(devices: [_wemo], bleDevices: [_rabbitAir]));
    await tester.pumpAndSettle();
    await scrollToBleSection(tester);

    expect(find.text('Sets up over Bluetooth instead'), findsOneWidget);
    // The spec names the family and the name it advertises while it waits.
    expect(find.text('Rabbit Air Purifier'), findsOneWidget);
    expect(find.textContaining('"RabbitAirSetup"'), findsOneWidget);
  });

  testWidgets('hides the whole section when nothing BLE is adoptable',
      (tester) async {
    await tester.pumpWidget(_wrap(devices: [_wemo]));
    await tester.pumpAndSettle();
    await scrollToEnd(tester);

    // A heading over empty space reads as a bug, so there is no heading.
    expect(find.text('Sets up over Bluetooth instead'), findsNothing);
  });

  testWidgets('skips a BLE family whose provisioning this app cannot drive',
      (tester) async {
    // A spec can declare a ble_provisioning method long before the app has a
    // conversation for it. Offering a card that dead-ends is worse than not
    // offering one, so an unknown handler is left out — and with it the
    // section, when it is the only entry.
    await tester.pumpWidget(_wrap(
      devices: [_wemo],
      bleDevices: [
        _bleDevice('Some Future Kettle', 'KettleSetup', 'appliance',
            'not_implemented_yet'),
      ],
    ));
    await tester.pumpAndSettle();
    await scrollToEnd(tester);

    expect(find.text('Sets up over Bluetooth instead'), findsNothing);
    expect(find.text('Some Future Kettle'), findsNothing);
  });
}
