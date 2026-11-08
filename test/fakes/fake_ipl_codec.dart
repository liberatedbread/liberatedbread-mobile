// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/ipl_codec.dart';

class FakeIplCodec implements IplCodec {
  final bool rejectAddress;

  FakeIplCodec({this.rejectAddress = false});

  @override
  Future<ForeoActivationDto> activation(String deviceAddress) async {
    if (rejectAddress) {
      throw const IplAddressException();
    }
    return ForeoActivationDto(
      securityAccess: Uint8List.fromList([0x01, 0xA1, 0xDD, 0xEE, 0xFF]),
      activationWrite: Uint8List.fromList([
        0x01,
        0x02,
        0xAD,
        0xEC,
        0x4A,
        0x44,
        0xCD,
        0x2E,
        0xCF,
        0xFB,
      ]),
    );
  }

  @override
  Future<ForeoStatusDto> decodeStatus({
    required List<int> activation,
    required List<int> wakeup,
  }) async {
    if (activation.isEmpty || wakeup.isEmpty) {
      throw ArgumentError('empty status');
    }
    return ForeoStatusDto(
      locked: activation.first == 0,
      wakeupEnabled: wakeup.first == 1,
    );
  }
}
