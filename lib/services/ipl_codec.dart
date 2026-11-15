// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../core/error_text.dart';
import '../src/rust/api/ipl_api.dart';
import '../src/rust/api/ipl_api.dart' as rust;

export '../src/rust/api/ipl_api.dart' show ForeoActivationDto, ForeoStatusDto;

abstract interface class IplCodec {
  Future<ForeoActivationDto> activation(String deviceAddress);

  /// [wakeup] is null when the unit exposes no 0A30 characteristic.
  Future<ForeoStatusDto> decodeStatus({
    required List<int> activation,
    required List<int>? wakeup,
  });

  /// Whether the unit gets the Basic/Pro switch, from its 2A28 SW revision.
  bool proModeSupported(String swRevision);

  /// An all-FF or empty FFF1 read-back: the device was busy.
  bool replyBusy(List<int> reply);

  /// An FFF1 read-back that acknowledges a settings write.
  bool writeAcknowledged(List<int> reply);

  /// The 0BD0 read-back: true for Pro, false for Basic.
  Future<bool> decodeRemovalMode(List<int> reply);
}

class RustIplCodec implements IplCodec {
  const RustIplCodec();

  @override
  Future<ForeoActivationDto> activation(String deviceAddress) async {
    try {
      return await rust.foreoActivation(deviceAddress: deviceAddress);
    } on AnyhowException {
      throw const IplAddressException();
    }
  }

  @override
  Future<ForeoStatusDto> decodeStatus({
    required List<int> activation,
    required List<int>? wakeup,
  }) => rust.decodeForeoStatus(
    activation: activation,
    wakeup: wakeup == null ? null : Uint8List.fromList(wakeup),
  );

  @override
  bool proModeSupported(String swRevision) =>
      rust.foreoProModeSupported(swRevision: swRevision);

  @override
  bool replyBusy(List<int> reply) => rust.foreoReplyBusy(reply: reply);

  @override
  bool writeAcknowledged(List<int> reply) =>
      rust.foreoWriteAcknowledged(reply: reply);

  @override
  Future<bool> decodeRemovalMode(List<int> reply) =>
      rust.decodeForeoRemovalMode(reply: reply);
}

class IplAddressException implements UserFacingException {
  const IplAddressException();

  @override
  String get message =>
      'Activation needs the device’s six-byte BLE MAC address, which this '
      'platform does not expose.';
}
