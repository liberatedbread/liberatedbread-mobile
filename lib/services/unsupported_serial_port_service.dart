// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'serial_port_service.dart';

/// The serial service on a platform that has none.
///
/// Says so rather than failing: the USB tab still appears everywhere, and on
/// a platform like this it explains why a cable cannot be used and what can
/// be used instead.
class UnsupportedSerialPortService implements SerialPortService {
  final String reason;

  const UnsupportedSerialPortService(this.reason);

  /// iPhone and iPad.
  static const String iosReason =
      'iPhone and iPad give apps no access to '
      'USB serial adapters, so a programming cable cannot be used here.';

  /// Anything else this build runs on without a serial backend.
  static const String otherReason =
      'This device has no way for the app to reach a USB serial adapter.';

  @override
  SerialAvailability get availability => SerialAvailability.unsupported(reason);

  @override
  Future<List<SerialPortInfo>> listPorts() async => const [];

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) =>
      Future.error(SerialPortException(reason));
}
