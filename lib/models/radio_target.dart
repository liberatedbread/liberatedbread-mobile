// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Which radio, and how to reach it.

import 'package:flutter/foundation.dart';

/// The link a radio is programmed over.
enum RadioTransport {
  /// The radio's own Bluetooth, tunnelling its serial protocol over GATT.
  ble('Bluetooth'),

  /// A programming cable: a USB-serial bridge on the radio's K-plug port.
  usb('USB cable');

  /// How the link is named on screen.
  final String label;

  const RadioTransport(this.label);

  /// The link in a sentence: "programs over Bluetooth".
  String get overPhrase => switch (this) {
        RadioTransport.ble => 'over Bluetooth',
        RadioTransport.usb => 'over a USB cable',
      };

  String get wireName => name;

  static RadioTransport? fromWire(Object? value) {
    for (final transport in RadioTransport.values) {
      if (transport.wireName == value) return transport;
    }
    return null;
  }
}

/// One particular radio the app can talk to.
///
/// [id] is whatever the transport knows the radio by: a Bluetooth device id
/// (a MAC on Android and Linux, a CoreBluetooth UUID on Apple platforms) or a
/// serial port id. It is opaque everywhere above the transport, which is what
/// lets one device screen serve both.
@immutable
class RadioTarget {
  final RadioTransport transport;
  final String id;

  /// What to call the radio on screen. Not part of its identity: a radio
  /// that advertises a different name tomorrow is still the same radio.
  final String name;

  const RadioTarget({
    required this.transport,
    required this.id,
    required this.name,
  });

  /// [name], or the id when the radio advertised no name at all.
  String get displayName => name.trim().isEmpty ? id : name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioTarget && transport == other.transport && id == other.id;

  @override
  int get hashCode => Object.hash(transport, id);

  @override
  String toString() => 'RadioTarget(${transport.wireName}, $id)';
}
