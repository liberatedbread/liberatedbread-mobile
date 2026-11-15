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
      wakeupWrite: Uint8List.fromList([0x01]),
    );
  }

  @override
  Future<ForeoStatusDto> decodeStatus({
    required List<int> activation,
    required List<int>? wakeup,
  }) async {
    if (activation.isEmpty || (wakeup != null && wakeup.isEmpty)) {
      throw ArgumentError('empty status');
    }
    return ForeoStatusDto(
      locked: activation.first == 0,
      wakeupEnabled: wakeup == null ? null : wakeup.first == 1,
    );
  }

  // The rules below mirror rust/src/protocol/ipl.rs, whose own tests pin
  // them against the spec; these fakes only need to agree on the shapes.

  @override
  bool proModeSupported(String swRevision) {
    final parts = swRevision.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return false;
    return switch (parts.first.toUpperCase()) {
      'PEACH2GO' || 'PEACH2PROMAX' => true,
      'PEACH2' => !'abcdefg'.contains(
        parts.last.substring(parts.last.length - 1).toLowerCase(),
      ),
      _ => false,
    };
  }

  @override
  bool replyBusy(List<int> reply) => reply.every((byte) => byte == 0xFF);

  @override
  bool writeAcknowledged(List<int> reply) =>
      !replyBusy(reply) && reply.first == 0x01;

  @override
  Future<bool> decodeRemovalMode(List<int> reply) async {
    if (replyBusy(reply)) throw ArgumentError('busy');
    return reply.first >= 0x06;
  }
}
