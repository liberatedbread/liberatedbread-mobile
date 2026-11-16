// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/linux_spp_transport.dart';

import '../helpers/host_rust_lib.dart';

List<int> _response({int channel = 5, bool continued = false}) => [
  0x07,
  0x00,
  0x01,
  0x00,
  0x18,
  0x00,
  0x15,
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
  var rustReady = false;
  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  test(
    'the SDP request searches SPP for its protocol descriptor list',
    () async {
      if (!rustReady) return;
      expect(await buildSppSdpRequest(), [
        0x06,
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
    },
  );

  test('reads the RFCOMM channel out of nested SDP elements', () async {
    if (!rustReady) return;
    expect(await rfcommChannelFromSdpResponse(_response(channel: 7)), 7);
  });

  test(
    'does not invent a channel from an incomplete or continued reply',
    () async {
      if (!rustReady) return;
      await expectLater(
        rfcommChannelFromSdpResponse(_response(continued: true)),
        throwsA(anything),
      );
      await expectLater(
        rfcommChannelFromSdpResponse(_response().sublist(0, 20)),
        throwsA(anything),
      );
      expect(await rfcommChannelFromSdpResponse(_response(channel: 0)), isNull);
    },
  );

  test(
    'rejects SDP errors and the old ServiceAttribute response opcode',
    () async {
      if (!rustReady) return;
      await expectLater(
        rfcommChannelFromSdpResponse([0x01, 0, 1, 0, 2, 0, 1]),
        throwsA(anything),
      );
      final wrongOpcode = _response()..[0] = 0x05;
      await expectLater(
        rfcommChannelFromSdpResponse(wrongOpcode),
        throwsA(anything),
      );
    },
  );

  group('sppPollVerdict', () {
    const pollin = 1, pollout = 4, pollerr = 8, pollhup = 0x10, pollnval = 0x20;

    // Before the fix any hangup failed the wait, so a printer that sent its
    // last status frame and closed had that frame thrown away.
    test('data that arrived before a hangup is read', () {
      expect(sppPollVerdict(pollin, pollin | pollhup), SppPollVerdict.ready);
      expect(sppPollVerdict(pollin, pollin | pollerr), SppPollVerdict.ready);
    });

    test('a hangup or error with nothing to read is a dropped link', () {
      expect(sppPollVerdict(pollin, pollhup), SppPollVerdict.dropped);
      expect(sppPollVerdict(pollin, pollerr), SppPollVerdict.dropped);
      expect(sppPollVerdict(pollin, pollnval), SppPollVerdict.dropped);
    });

    test('a failed connect is not a writable socket', () {
      expect(
        sppPollVerdict(pollout, pollout | pollerr),
        SppPollVerdict.dropped,
      );
      expect(
        sppPollVerdict(pollout, pollout | pollhup),
        SppPollVerdict.dropped,
      );
      expect(sppPollVerdict(pollout, pollout), SppPollVerdict.ready);
    });

    test('a wake for something else waits again', () {
      expect(sppPollVerdict(pollin, pollout), SppPollVerdict.notYet);
      expect(sppPollVerdict(pollin, 0), SppPollVerdict.notYet);
    });
  });
}
