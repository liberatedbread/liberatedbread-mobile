// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:liberated_bread_mobile/services/serial_port_service.dart';

/// Ports that can change between listings, and a count of how often anyone
/// looked. Nothing opens: the screens that use it only list.
class FakeSerialPorts implements SerialPortService {
  List<SerialPortInfo> ports;

  /// Thrown by the next listing, when set.
  Object? error;
  int listings = 0;

  FakeSerialPorts([this.ports = const []]);

  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    listings++;
    final failure = error;
    if (failure != null) throw failure;
    return ports;
  }

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) =>
      Future.error(const SerialPortException('nothing opens here'));
}
