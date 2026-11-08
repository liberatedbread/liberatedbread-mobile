// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/linux_spp_transport.dart';

List<int> _response({int channel = 5, bool continued = false}) => [
  0x05,
  0x00,
  0x01,
  0x00,
  0x16,
  0x35,
  0x13,
  0x35,
  0x11,
  0x09,
  0x00,
  0x04,
  0x35,
  0x0c,
  0x35,
  0x03,
  0x19,
  0x01,
  0x00,
  0x35,
  0x05,
  0x19,
  0x00,
  0x03,
  0x08,
  channel,
  continued ? 1 : 0,
];

void main() {
  test('the SDP request searches SPP for its protocol descriptor list', () {
    expect(buildSppSdpRequest(), [
      0x04,
      0x00,
      0x01,
      0x00,
      0x0d,
      0x35,
      0x03,
      0x19,
      0x11,
      0x01,
      0x00,
      0xff,
      0x35,
      0x03,
      0x09,
      0x00,
      0x04,
      0x00,
    ]);
  });

  test('reads the RFCOMM channel out of nested SDP elements', () {
    expect(rfcommChannelFromSdpResponse(_response(channel: 7)), 7);
  });

  test('does not invent a channel from an incomplete or continued reply', () {
    expect(
      () => rfcommChannelFromSdpResponse(_response(continued: true)),
      throwsFormatException,
    );
    expect(
      () => rfcommChannelFromSdpResponse(_response().sublist(0, 20)),
      throwsFormatException,
    );
    expect(rfcommChannelFromSdpResponse(_response(channel: 0)), isNull);
  });

  test(
    'rejects an SDP error instead of treating its payload as attributes',
    () {
      expect(
        () => rfcommChannelFromSdpResponse([0x06, 0, 1, 0, 2, 0, 1, 0]),
        throwsFormatException,
      );
    },
  );
}
