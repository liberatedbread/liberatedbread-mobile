// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The one "is this a Roomba we can drive" rule the launcher, the saved row
// and the control screen share: keyed on protocol_handler, never on the
// mqtt transport, and an empty blid is no blid.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/screens/roomba_identity.dart';
import 'package:liberated_bread_mobile/services/roomba_control_service.dart'
    show roombaProtocolHandler;
import 'package:liberated_bread_mobile/services/spec_codec.dart';

NetworkControls _controls(String? handler) => NetworkControls(
  specYaml: 'yaml',
  entities: const [],
  capabilities: handler == null
      ? null
      : NetworkCapabilitiesDto(
          mqttClientIdGenerated: false,
          tlsSelfSigned: false,
          advertisedPortUnreliable: false,
          protocolHandler: handler,
        ),
);

void main() {
  test('a Roomba spec with a blid is driven by that blid', () {
    expect(
      roombaBlidFor(const {'blid': 'ABC'}, _controls(roombaProtocolHandler)),
      'ABC',
    );
  });

  test('another MQTT spec announcing a blid is not a Roomba', () {
    expect(roombaBlidFor(const {'blid': 'ABC'}, _controls('hisense')), isNull);
    expect(isRoombaControls(_controls('hisense')), isFalse);
    expect(isRoombaControls(null), isFalse);
  });

  test(
    'an empty or missing blid is absent, but the spec is still a Roomba',
    () {
      final roomba = _controls(roombaProtocolHandler);
      expect(roombaBlidFor(const {'blid': ''}, roomba), isNull);
      expect(roombaBlidFor(const {}, roomba), isNull);
      expect(announcedBlid(const {'blid': ''}), isNull);
      expect(isRoombaControls(roomba), isTrue);
    },
  );
}
