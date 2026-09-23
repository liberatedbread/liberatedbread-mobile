// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/usb_bridges.dart';

void main() {
  test('names the chips programming cables are built on', () {
    expect(usbBridgeFor(0x1A86, 0x7523)?.name, 'WCH CH340');
    expect(usbBridgeFor(0x10C4, 0xEA60)?.name, 'Silicon Labs CP210x');
    expect(usbBridgeFor(0x0403, 0x6001)?.name, 'FTDI FT232R');
    expect(usbBridgeFor(0x067B, 0x2303)?.name, 'Prolific PL2303');
  });

  test('warns about the chip most often counterfeited, and only that one', () {
    expect(usbBridgeFor(0x067B, 0x2303)?.caution, contains('Counterfeit'));
    expect(usbBridgeFor(0x1A86, 0x7523)?.caution, isNull);
  });

  test('an unknown or partial id names nothing', () {
    expect(usbBridgeFor(0x1234, 0x5678), isNull);
    expect(usbBridgeFor(0x1A86, null), isNull);
    expect(usbBridgeFor(null, 0x7523), isNull);
  });

  test('ids are written the usual way', () {
    expect(usbIdLabel(0x1A86, 0x7523), '1a86:7523');
    expect(usbIdLabel(0x403, 0x6001), '0403:6001');
  });
}
