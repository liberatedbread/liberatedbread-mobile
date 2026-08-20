// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The SO_REUSEPORT fallback the mDNS transport binds through.
//
// Worth testing at this level because the failure it prevents is silent and
// platform-specific: Android's bionic libc throws on `reusePort: true`, so on a
// device (and only on a device) the whole mDNS half of a scan used to throw and
// be lost while the other transports kept working — a bug no desktop test run,
// where reusePort is supported, would ever reproduce. The fallback decision is
// exercised here without a socket so both branches are checked on every
// platform; a real loopback bind confirms the wiring end to end.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/datagram_bind.dart';

void main() {
  group('withReusePortFallback', () {
    test('returns the first result when reusePort is accepted', () async {
      final seen = <bool>[];
      final result = await withReusePortFallback(({required bool reusePort}) {
        seen.add(reusePort);
        return Future.value('ok:$reusePort');
      });
      // Tried reusePort once, it worked, so no fallback attempt.
      expect(seen, [true]);
      expect(result, 'ok:true');
    });

    test('retries without reusePort on SocketException', () async {
      final seen = <bool>[];
      final result = await withReusePortFallback(({required bool reusePort}) {
        seen.add(reusePort);
        if (reusePort) {
          // What Android's bionic libc raises for SO_REUSEPORT.
          throw const SocketException(
              'reusePort not supported on this platform');
        }
        return Future.value('ok:$reusePort');
      });
      // reusePort first, then the fallback with it off.
      expect(seen, [true, false]);
      expect(result, 'ok:false');
    });

    test('propagates a SocketException from the fallback attempt', () async {
      // Both binds fail (e.g. the port really is taken): the error surfaces
      // rather than being masked.
      await expectLater(
        withReusePortFallback(({required bool reusePort}) =>
            Future<Object>.error(const SocketException('port in use'))),
        throwsA(isA<SocketException>()),
      );
    });

    test('does not retry on a non-SocketException error', () async {
      var calls = 0;
      await expectLater(
        withReusePortFallback(({required bool reusePort}) {
          calls++;
          return Future<Object>.error(StateError('boom'));
        }),
        throwsA(isA<StateError>()),
      );
      // Only reusePort:true was attempted; a StateError is not a bind that a
      // reusePort retry could fix.
      expect(calls, 1);
    });
  });

  group('bindDatagramSocket', () {
    test('binds a real loopback socket with reusePort disabled', () async {
      final socket = await bindDatagramSocket(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);
      expect(socket.port, greaterThan(0));
    });

    test('binds on every platform when reusePort is requested', () async {
      // On desktop the reusePort bind succeeds outright; on a platform that
      // rejects it the fallback still yields a socket. Either way a bind comes
      // back rather than an exception — the property the mDNS transport relies
      // on. Loopback:0 keeps this off 5353/1900, so it is a plain unit test.
      final socket = await bindDatagramSocket(InternetAddress.loopbackIPv4, 0,
          reusePort: true);
      addTearDown(socket.close);
      expect(socket.port, greaterThan(0));
    });
  });
}
