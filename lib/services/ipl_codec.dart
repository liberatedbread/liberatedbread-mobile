// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../core/error_text.dart';
import '../src/rust/api/ipl_api.dart';
import '../src/rust/api/ipl_api.dart' as rust;

export '../src/rust/api/ipl_api.dart' show ForeoActivationDto, ForeoStatusDto;

abstract interface class IplCodec {
  Future<ForeoActivationDto> activation(String deviceAddress);

  Future<ForeoStatusDto> decodeStatus({
    required List<int> activation,
    required List<int> wakeup,
  });
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
    required List<int> wakeup,
  }) => rust.decodeForeoStatus(activation: activation, wakeup: wakeup);
}

class IplAddressException implements UserFacingException {
  const IplAddressException();

  @override
  String get message =>
      'Activation needs the device’s six-byte BLE MAC address, which this '
      'platform does not expose.';
}
