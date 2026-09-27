// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PROBE: L2capAttChannel alone against the machine's real kernel — the
// socket, the worker isolate and the descriptor hand-offs that no fake can
// exercise. (The same worker also runs in every `flutter test` over a Unix
// socketpair — test/services/direct_att/att_channel_test.dart — but only a
// Bluetooth socket has BT_CONFIG.) Three checks:
//
//   (a) a connect to an address nobody has, cancelled after 300 ms, fails
//       with ECANCELED (125) promptly — the shutdown() from this isolate
//       really does end the worker's wait — and leaves no descriptor
//       behind. Needs only an adapter.
//   (b) with LB_LIVE_BLE_ID: connect to that device, read the link's
//       security level (1: nothing is ever encrypted unasked), close, and
//       again leave no descriptor behind.
//   (c) with LB_LIVE_BLE_ID and LB_LIVE_BLE_PAIR=1: raise that link's
//       security and watch the socket through BT_CONFIG. A send right after
//       the request is refused with ENOTCONN on a link that stays open;
//       the worker, woken by this run's SIGPROF every millisecond, does not
//       mistake BT_CONFIG for the link ending (it used to: closeErrno 107
//       within a millisecond of pairing starting); and an elevation that
//       fails leaves the link closed, not stuck in BT_CONFIG. Which way the
//       pairing goes depends on the host — with no agent registered
//       (`bluetoothctl show` says "Pairable: no") it is refused locally —
//       and both ways are checked. WARNING: success bonds the device.
//
// LB_LIVE_BLE=1 [LB_LIVE_BLE_ID=18:7A:93:12:DE:94] [LB_LIVE_BLE_RANDOM=1] \
//   [LB_LIVE_BLE_PAIR=1] \
//   flutter test test/live/att_l2cap_live_test.dart --tags=live_ble
@Tags(['live_ble'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_channel.dart';

/// A random static address (top bits 11) that no device should hold.
const _nobody = 'C0:FF:EE:0B:0D:01';

/// The descriptors this process holds right now.
int _openFds() => Directory('/proc/self/fd').listSync().length;

/// Wait (briefly) for the descriptor count to come back to [baseline]: the
/// worker closes its socket only after this isolate acknowledged its last
/// report, a few event-loop turns after the connect future settles.
Future<int> _settledFds(int baseline) async {
  final clock = Stopwatch()..start();
  var now = _openFds();
  while (now > baseline && clock.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    now = _openFds();
  }
  return now;
}

bool get _live => Platform.environment['LB_LIVE_BLE'] == '1';

void main() {
  test(
    'a cancelled connect fails with ECANCELED at once and leaks nothing',
    () async {
      if (!_live) {
        markTestSkipped('live hardware run not requested');
        return;
      }
      final baseline = _openFds();
      final cancel = Completer<void>();
      Timer(const Duration(milliseconds: 300), cancel.complete);
      final clock = Stopwatch()..start();
      Object? failure;
      try {
        final channel = await L2capAttChannel.connect(
          _nobody,
          randomAddress: true,
          timeout: const Duration(seconds: 15),
          cancel: cancel.future,
        );
        await channel.close();
      } catch (e) {
        failure = e;
      }
      stderr.writeln('[${clock.elapsedMilliseconds}ms] $failure');
      expect(
        failure,
        isA<AttChannelException>()
            .having((e) => e.errno, 'errno', AttErrno.ecanceled)
            .having((e) => e.stage, 'stage', 'connect'),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(await _settledFds(baseline), baseline);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'a real link starts at security level 1 and closes cleanly',
    () async {
      final deviceId = Platform.environment['LB_LIVE_BLE_ID'];
      if (!_live || deviceId == null) {
        markTestSkipped('live hardware run not requested');
        return;
      }
      final baseline = _openFds();
      final clock = Stopwatch()..start();
      final channel = await L2capAttChannel.connect(
        deviceId,
        randomAddress: Platform.environment['LB_LIVE_BLE_RANDOM'] == '1',
        timeout: const Duration(seconds: 20),
      );
      stderr.writeln('[${clock.elapsedMilliseconds}ms] connected');
      expect(channel.isOpen, isTrue);
      expect(channel.securityLevel, 1);
      expect(channel.closeErrno, isNull);
      await channel.close();
      stderr.writeln('[${clock.elapsedMilliseconds}ms] closed');
      expect(channel.isOpen, isFalse);
      expect(channel.closeErrno, isNull, reason: 'we closed it ourselves');
      expect(channel.securityLevel, 1);
      expect(await _settledFds(baseline), baseline);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'raising security: BT_CONFIG is neither a lost link nor a wedged one',
    () async {
      final deviceId = Platform.environment['LB_LIVE_BLE_ID'];
      if (!_live ||
          deviceId == null ||
          Platform.environment['LB_LIVE_BLE_PAIR'] != '1') {
        markTestSkipped('live pairing run not requested');
        return;
      }
      final baseline = _openFds();
      final clock = Stopwatch()..start();
      final channel = await L2capAttChannel.connect(
        deviceId,
        randomAddress: Platform.environment['LB_LIVE_BLE_RANDOM'] == '1',
        timeout: const Duration(seconds: 20),
      );
      void log(String s) =>
          stderr.writeln('[${clock.elapsedMilliseconds}ms] $s');
      log('connected at level ${channel.securityLevel}');
      if (channel.securityLevel >= 2) {
        await channel.close();
        markTestSkipped('the link is already encrypted: nothing to raise');
        return;
      }

      // The setsockopt runs synchronously inside the call: from here the
      // socket is in BT_CONFIG.
      final elevation = channel.elevateSecurity(
        2,
        timeout: const Duration(seconds: 20),
      );
      try {
        // An Exchange MTU Request: harmless if a peer PDU has already put
        // the socket back to connected and it goes out after all.
        channel.send(Uint8List.fromList([0x02, 0x17, 0x00]));
        log('send mid-pairing went out (a peer PDU resumed the socket)');
      } on AttChannelException catch (e) {
        log('send mid-pairing refused: $e');
        expect(e.errno, AttErrno.enotconn);
        expect(
          channel.isOpen,
          isTrue,
          reason: 'BT_CONFIG refuses a send without hanging up',
        );
      }

      // Diagnostics: whether the link was seen open while pairing ran.
      var sawOpenMidPairing = false;
      final watch = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (channel.isOpen) sawOpenMidPairing = true;
      });
      final ok = await elevation;
      watch.cancel();
      log(
        'elevation ${ok ? 'succeeded' : 'failed'}; level '
        '${channel.securityLevel}, open ${channel.isOpen}, closeErrno '
        '${channel.closeErrno}, seen open mid-pairing: $sawOpenMidPairing',
      );
      expect(
        channel.closeErrno,
        isNot(AttErrno.enotconn),
        reason: 'the worker must wait through BT_CONFIG, not end on it',
      );
      if (ok) {
        expect(channel.securityLevel, greaterThanOrEqualTo(2));
        expect(channel.isOpen, isTrue);
      } else {
        // Refused locally or timed out: closed by us (closeErrno null).
        // Refused by the peer: the kernel dropped it (EACCES). Either way
        // never left open in BT_CONFIG.
        expect(channel.isOpen, isFalse);
        await channel.closed.timeout(const Duration(seconds: 5));
      }
      await channel.close();
      expect(await _settledFds(baseline), baseline);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
