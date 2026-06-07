// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../models/ble_discovered_service.dart';
import '../services/spec_codec.dart';
import 'decoded_value_widget.dart';
import 'raw_characteristic_widget.dart';
import 'typed_command_widget.dart';

/// Chooses the right control for a spec-matched characteristic:
/// - writable + has commands           -> [TypedCommandWidget]
/// - readable/notify + has format spec -> [DecodedValueWidget]
/// - otherwise                         -> [RawCharacteristicWidget] (raw hex)
///
/// Device properties come from the *discovered* characteristic (ground truth);
/// the typed metadata comes from the matched spec.
class TypedCharacteristicWidget extends StatelessWidget {
  final String deviceId;
  final String serviceUuid;
  final String specYaml;
  final CharacteristicDto specChar;
  final BleDiscoveredCharacteristic discovered;

  const TypedCharacteristicWidget({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.specYaml,
    required this.specChar,
    required this.discovered,
  });

  @override
  Widget build(BuildContext context) {
    if (discovered.canWrite && specChar.commands.isNotEmpty) {
      return TypedCommandWidget(
        deviceId: deviceId,
        serviceUuid: serviceUuid,
        specYaml: specYaml,
        specChar: specChar,
      );
    }
    if ((discovered.canRead || discovered.canNotify) &&
        specChar.formatFields.isNotEmpty) {
      return DecodedValueWidget(
        deviceId: deviceId,
        serviceUuid: serviceUuid,
        specYaml: specYaml,
        specChar: specChar,
        canRead: discovered.canRead,
        canNotify: discovered.canNotify,
      );
    }
    return RawCharacteristicWidget(
      deviceId: deviceId,
      serviceUuid: serviceUuid,
      characteristic: discovered,
    );
  }
}
