// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The shared launcher's pre-flight: a robot with no password on THIS handset
// goes to the adoption wizard, not to a control screen whose every button
// would fail. Shared because it is not a property of how the device was found
// — the saved-devices row reaches it as often as the scan row does, and used
// to push straight past it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/network_controls_launcher.dart';
import 'package:liberated_bread_mobile/screens/network_device_screen.dart';
import 'package:liberated_bread_mobile/screens/roomba_adoption_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _blid = 'ABC123DEF456';

/// A robot's control surface: one button, over the robot's own MQTT transport.
const _robotEntity = NetworkEntityDto(
  isInstanced: false,
  name: 'Clean',
  platform: 'button',
  transport: 'mqtt',
  stateCommand: 'state',
  options: [],
  actions: [
    NetworkActionDto(
      role: 'start',
      commandName: 'start',
      transport: 'mqtt',
      userParams: [],
      readBack: [],
      credentials: [],
      instanceParams: [],
    ),
  ],
);

NetworkDevice _robot() => NetworkDevice(
  // RFC 5737 TEST-NET-2: this is a widget test, and the pre-flight must
  // settle before anything is dialed.
  host: '198.51.100.12',
  name: 'Dorita',
  txt: const {'blid': _blid, 'sku': 'R980020'},
  sources: const {NetworkDiscoverySource.lanProbe},
  discoveredAt: DateTime(2026),
);

void main() {
  late InMemorySettingsStore settings;

  setUp(() => settings = InMemorySettingsStore());

  /// A host with one button that opens [_robot]'s controls through the
  /// launcher — the same call the scan list and the saved-devices list make.
  Widget wrap() => ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(settings),
      specCodecProvider.overrideWithValue(FakeSpecCodec()),
    ],
    child: MaterialApp(
      home: Consumer(
        builder: (context, ref, _) => Scaffold(
          body: ElevatedButton(
            onPressed: () => openNetworkControls(
              context: context,
              ref: ref,
              device: _robot(),
              controls: const NetworkControls(
                specYaml: 'yaml',
                entities: [_robotEntity],
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'a robot with no stored password goes to adoption, not controls',
    (tester) async {
      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byType(RoombaAdoptionScreen), findsOneWidget);
      expect(
        find.byType(NetworkDeviceScreen),
        findsNothing,
        reason: 'the control screen can only report errors without a password',
      );
    },
  );

  testWidgets('backing out of adoption pushes nothing', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(RoombaAdoptionScreen), findsNothing);
    expect(find.byType(NetworkDeviceScreen), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('an empty BLID is not an identity, so no robot pre-flight runs', (
    tester,
  ) async {
    // A TXT record can carry a bare `blid` flag with no value, which the
    // parser stores as ''. Treating that as a robot identity would open the
    // wizard for a robot nothing can be filed under.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(settings),
          specCodecProvider.overrideWithValue(FakeSpecCodec()),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: ElevatedButton(
                onPressed: () => openNetworkControls(
                  context: context,
                  ref: ref,
                  device: NetworkDevice(
                    host: '198.51.100.12',
                    name: 'Dorita',
                    txt: const {'blid': ''},
                    sources: const {NetworkDiscoverySource.lanProbe},
                    discoveredAt: DateTime(2026),
                  ),
                  controls: const NetworkControls(
                    specYaml: 'yaml',
                    entities: [_robotEntity],
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();

    expect(find.byType(RoombaAdoptionScreen), findsNothing);
  });

  // The adopted path — credential present, wizard skipped — is deliberately
  // NOT exercised here: it pushes the real control screen, whose robot
  // connection leaves timers pending that fail the test at teardown. What that
  // path does with the credential belongs to network_device_screen's own
  // tests; what this file pins is the pre-flight that decides between them.
}
