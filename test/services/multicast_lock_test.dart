// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Android multicast lock, and the scan's use of it.
//
// Worth testing at this level because the failure it prevents is invisible:
// without the lock Android's Wi-Fi driver drops the mDNS and SSDP replies
// before they reach the app, so the queries go out, nothing errors, and the
// Wi-Fi tab shows an empty list. Nothing downstream can tell that apart from a
// network with no devices on it.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/multicast_lock.dart';
import 'package:liberated_bread_mobile/services/real_network_scan_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MulticastLock.channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MulticastLock.channel, null);
  });

  test('acquire and release reach the platform when supported', () async {
    final lock = MulticastLock(isSupported: true);
    await lock.acquire();
    await lock.release();
    expect(calls, ['acquire', 'release']);
  });

  test('does nothing on a platform without the lock', () async {
    // iOS gates this traffic behind the local-network permission instead, and
    // desktop platforms do not filter it. Calling a channel no MainActivity is
    // listening on would just log a failure on every scan.
    final lock = MulticastLock(isSupported: false);
    await lock.acquire();
    await lock.release();
    expect(calls, isEmpty);
  });

  test('a platform failure does not propagate', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MulticastLock.channel, (call) async {
      throw PlatformException(code: 'no-wifi-service');
    });
    final lock = MulticastLock(isSupported: true);
    // A scan that comes back empty beats a scan that fails outright, so the
    // lock never takes the scan down with it.
    await expectLater(lock.acquire(), completes);
    await expectLater(lock.release(), completes);
  });

  test('a scan takes the lock and gives it back', () async {
    final lock = MulticastLock(isSupported: true);
    final service = RealNetworkScanService(multicastLock: lock);

    // A very short window: this runs with no network, so both transports come
    // back empty almost immediately. What is being asserted is the lock
    // lifecycle around them, not what they found.
    await service
        .scan(timeout: const Duration(milliseconds: 20))
        .drain<void>()
        .catchError((Object _) {});

    expect(
      calls,
      containsAllInOrder(['acquire', 'release']),
      reason: 'the lock must be held before the queries go out and released '
          'when the scan ends, or it costs battery for the whole device',
    );
    expect(calls.where((c) => c == 'release'), isNotEmpty);
  });
}
