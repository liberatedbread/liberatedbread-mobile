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
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/label_printer_screen.dart';
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

/// What makes a spec a Roomba: its protocol_handler, not its transport.
const _robotCaps = NetworkCapabilitiesDto(
  protocolHandler: 'roomba_mqtt',
  tlsSelfSigned: true,
  advertisedPortUnreliable: false,
  mqttClientIdGenerated: true,
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

/// Throws on reads or writes of one credential field, like a keystore fault.
class _FaultyStore extends InMemorySettingsStore {
  final String failingField;
  final bool failReads;
  _FaultyStore(this.failingField, {this.failReads = false});

  @override
  Future<String?> read(String key) async {
    if (failReads && key.endsWith(failingField)) {
      throw Exception('keystore fault');
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (!failReads && key.endsWith(failingField)) {
      throw Exception('keystore fault');
    }
    return super.write(key, value);
  }
}

void main() {
  late InMemorySettingsStore settings;

  setUp(() => settings = InMemorySettingsStore());

  /// A host with one button that opens [_robot]'s controls through the
  /// launcher — the same call the scan list and the saved-devices list make.
  Widget wrap({
    bool labelPrinter = false,
    NetworkCapabilitiesDto? capabilities = _robotCaps,
  }) => ProviderScope(
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
              // The label printer screen stands in for "the controls were
              // pushed": it settles on the fake codec without dialing.
              controls: NetworkControls(
                specYaml: 'yaml',
                entities: const [_robotEntity],
                capabilities: capabilities,
                rasterPrintHandler: labelPrinter ? 'brother_ql_raster' : null,
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

  // The pre-flight keyed on the `mqtt` transport, which Hisense, Dyson and
  // Bambu specs ride too: any of them announcing a `blid` key went to the
  // Roomba wizard, though the control screen keys on the handler and would
  // not treat it as a robot.
  testWidgets('an MQTT device that is not a Roomba skips the robot wizard', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        labelPrinter: true,
        capabilities: const NetworkCapabilitiesDto(
          protocolHandler: 'hisense_mqtt',
          tlsSelfSigned: true,
          advertisedPortUnreliable: false,
          mqttClientIdGenerated: false,
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(RoombaAdoptionScreen), findsNothing);
    expect(find.byType(LabelPrinterScreen), findsOneWidget);
  });

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
                    capabilities: _robotCaps,
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

  testWidgets('an adopted robot skips the wizard and re-files its address', (
    tester,
  ) async {
    // R-209: the adopted branch was left untested, on the grounds that the
    // control screen it pushes leaves timers pending — and pointed at
    // network_device_screen's tests, which do not cover this either. What
    // this file is for is the PRE-FLIGHT, and the pre-flight's two decisions
    // are both observable before the push: the wizard is not opened, and the
    // robot's address is re-filed from the sighting that got us here (a DHCP
    // lease moves, and the stored address is how a saved robot is reached
    // without a scan).
    final store = RoombaCredentialStore(settings);
    await store.save(
      const RoombaCredentials(blid: _blid, password: ':1:9:secret'),
    );
    await store.rememberAddress(_blid, '198.51.100.99');

    // The label printer screen stands in for the controls: with the robot's
    // real handler the control screen now takes the Roomba path, whose
    // connection leaves timers — and the pre-flight is what is under test.
    await tester.pumpWidget(wrap(labelPrinter: true));
    await tester.tap(find.text('Open'));
    // One pump, not pumpAndSettle: the control screen's own connection is
    // another file's business, and settling it here is what leaves timers.
    await tester.pump();

    expect(
      find.byType(RoombaAdoptionScreen),
      findsNothing,
      reason: 'a robot with a stored password does not re-run the wizard',
    );
    expect(
      (await store.credentials(_blid))?.lastIp,
      '198.51.100.12',
      reason: 'the sighting that opened this screen is where the robot is now',
    );
  });

  // Before the fix a throwing rememberAddress escaped _adopted, so a robot
  // whose password read fine never opened.
  testWidgets('a failed address write still opens the controls', (
    tester,
  ) async {
    settings = _FaultyStore('last_ip');
    await RoombaCredentialStore(
      settings,
    ).save(const RoombaCredentials(blid: _blid, password: ':1:9:secret'));

    await tester.pumpWidget(wrap(labelPrinter: true));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(LabelPrinterScreen), findsOneWidget);
  });

  // Before the fix a keychain read fault vanished into the zone handler:
  // the tap did nothing and said nothing.
  testWidgets('a keychain read fault is reported, not swallowed', (
    tester,
  ) async {
    settings = _FaultyStore('password', failReads: true);

    await tester.pumpWidget(wrap(labelPrinter: true));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('saved password'), findsOneWidget);
    expect(find.byType(RoombaAdoptionScreen), findsNothing);
    expect(find.byType(LabelPrinterScreen), findsNothing);
  });
}
