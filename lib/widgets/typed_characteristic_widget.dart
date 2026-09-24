// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../models/ble_discovered_service.dart';
import '../services/spec_codec.dart';
import 'decoded_value_widget.dart';
import 'raw_characteristic_widget.dart';
import 'typed_command_widget.dart';

/// Chooses the right control(s) for a spec-matched characteristic:
/// - readable/notify + has format spec -> [DecodedValueWidget]
/// - writable + has commands           -> [TypedCommandWidget]
/// - neither                           -> [RawCharacteristicWidget] (raw hex)
///
/// A characteristic can be both, and many are: a light's control point is
/// read+write with a `format:` block describing what a read returns. This
/// used to answer with the writer alone, so the GATT browser showed a
/// send button for a characteristic whose CURRENT VALUE it could read and
/// simply did not — the decoded state was reachable only by disabling the
/// spec match. Both are drawn now, reading first, because "what is it" reads
/// before "change it".
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
    // Don't route through typed controls when every command has an encoding
    // (protobuf, JSON, TLV) that can't be serialised to bytes yet — the
    // raw-byte fallback must stay visible.
    final encodable = specChar.commands
        .where((c) => c.isEncodable)
        .toList(growable: false);
    final writes = discovered.canWrite && encodable.isNotEmpty;
    final reads =
        (discovered.canRead || discovered.canNotify) &&
        specChar.formatFields.isNotEmpty;

    if (!writes && !reads) {
      return RawCharacteristicWidget(
        deviceId: deviceId,
        serviceUuid: serviceUuid,
        characteristic: discovered,
      );
    }

    final decoded = reads
        ? DecodedValueWidget(
            deviceId: deviceId,
            serviceUuid: serviceUuid,
            specYaml: specYaml,
            specChar: specChar,
            canRead: discovered.canRead,
            canNotify: discovered.canNotify,
          )
        : null;
    final commands = writes
        ? TypedCommandWidget(
            deviceId: deviceId,
            serviceUuid: serviceUuid,
            specYaml: specYaml,
            specChar: specChar,
          )
        : null;

    if (decoded == null) return commands!;
    if (commands == null) return decoded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [decoded, commands],
    );
  }
}
