// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Security on demand: a link starts unencrypted, and only when the peer
// rejects a read or write for want of security does the client raise the
// link (encrypt, or pair) and retry that one request — once. What BlueZ's
// bt_att, Android and iOS all do, and the only safe policy, because some
// peripherals (the LDM330) support no encryption at all and a pairing
// attempt just gets the link dropped.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_channel.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_client.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';

import '../../fakes/fake_att_channel.dart';

// A battery-style peripheral with one attribute per security need.
const _open = 0x0003; // no security
const _encrypted = 0x0005; // level 2, answers 0x05 below it
const _mitm = 0x0007; // level 3, answers 0x05 below it
const _strict = 0x0009; // level 3, answers 0x0F (encryption) below it
const _keySize = 0x000b; // level 2, answers 0x0C (key size) below it
const _cccd = 0x000c; // level 2, a CCCD

FakeAttPeripheral _peer() => FakeAttPeripheral()
  ..service(0x0001, 0x000c, 0x180f)
  ..characteristic(0x0002, _open, 0x0a, 0x2a19, const [10])
  ..characteristic(0x0004, _encrypted, 0x0a, 0x2a1a, const [
    20,
  ], requiredSecurity: 2)
  ..characteristic(0x0006, _mitm, 0x0a, 0x2a1b, const [30], requiredSecurity: 3)
  ..characteristic(
    0x0008,
    _strict,
    0x0a,
    0x2a1c,
    const [40],
    requiredSecurity: 3,
    securityError: AttError.insufficientEncryption,
  )
  ..characteristic(
    0x000a,
    _keySize,
    0x1a,
    0x2a1d,
    const [50],
    requiredSecurity: 2,
    securityError: AttError.encryptionKeySizeInsufficient,
  )
  ..descriptor(_cccd, 0x2902, requiredSecurity: 2);

void main() {
  late FakeAttPeripheral peer;
  late FakeAttChannel channel;
  late AttClient client;
  final log = <String>[];

  AttClient connect({
    bool elevateSecurityOnDemand = true,
    Duration securityTimeout = const Duration(seconds: 5),
  }) {
    channel = FakeAttChannel(peer);
    return client = AttClient(
      channel,
      log: log.add,
      elevateSecurityOnDemand: elevateSecurityOnDemand,
      securityTimeout: securityTimeout,
    );
  }

  setUp(() {
    log.clear();
    peer = _peer();
    connect();
  });

  tearDown(() => client.close());

  /// The handles of every Read Request the peer received, in order.
  List<int> reads() => [
    for (final r in peer.requests)
      if (r[0] == AttOpcode.readRequest) r[1] | (r[2] << 8),
  ];

  Matcher attError(int op, int handle, int code) => isA<AttErrorException>()
      .having((e) => e.requestOpcode, 'requestOpcode', op)
      .having((e) => e.handle, 'handle', handle)
      .having((e) => e.errorCode, 'errorCode', code);

  test('0x05 on an unencrypted link: encrypt, retry once, succeed', () async {
    expect(await client.read(_encrypted), [20]);
    expect(peer.elevations, [2]);
    expect(reads(), [_encrypted, _encrypted]);
    expect(channel.securityLevel, 2);
    expect(peer.bonded, isTrue);
    expect(peer.violations, isEmpty);
    // Once raised, the link stays raised: no second elevation.
    expect(await client.read(_encrypted), [20]);
    expect(peer.elevations, [2]);
  });

  test('a refused pairing surfaces the original error, then closes', () async {
    peer.acceptsPairing = false;
    final order = <String>[];
    unawaited(channel.closed.then((_) => order.add('link closed')));
    await expectLater(
      client.read(_encrypted).whenComplete(() => order.add('read failed')),
      throwsA(attError(0x0a, _encrypted, AttError.insufficientAuthentication)),
    );
    expect(peer.elevations, [2]);
    expect(reads(), [_encrypted]);
    expect(channel.securityLevel, 1);
    // The kernel leaves a socket whose pairing was refused locally stuck in
    // BT_CONFIG, refusing every send; the channel closes it instead, and
    // the app hears "pair first" and then an ordinary disconnect — in that
    // order, as on Linux, where the end arrives from the worker isolate.
    expect(channel.isOpen, isFalse);
    expect(client.isOpen, isFalse);
    await channel.closed;
    expect(order, ['read failed', 'link closed']);
    expect(channel.closeErrno, isNull, reason: 'we closed it');
  });

  test('the peer refusing (and the kernel dropping the link): still 0x05, '
      'while what was queued behind it is lost with the link', () async {
    peer.pairingDelay = const Duration(milliseconds: 200);
    final pending = client.read(_encrypted);
    final queued = client.read(_open);
    // What a peer's Pairing Failed does on Linux: the kernel disconnects
    // with Authentication Failure, which the socket reports as EACCES.
    Timer(
      const Duration(milliseconds: 20),
      () => peer.dropLink(errno: AttErrno.eacces),
    );
    await expectLater(
      pending,
      throwsA(attError(0x0a, _encrypted, AttError.insufficientAuthentication)),
    );
    await expectLater(queued, throwsA(isA<AttLinkClosedException>()));
    expect(channel.closeErrno, AttErrno.eacces);
  });

  test('an elevation the kernel turns down at once leaves the link up, '
      'and one attempt answers every later ask', () async {
    // setsockopt(BT_SECURITY) failing outright (no SMP on the link):
    // nothing changed state, so nothing needs closing, and the failure is
    // remembered — asking again would only fail again.
    peer.smpUnavailable = true;
    await expectLater(
      client.read(_encrypted),
      throwsA(attError(0x0a, _encrypted, 0x05)),
    );
    await expectLater(
      client.read(_keySize),
      throwsA(attError(0x0a, _keySize, 0x0c)),
    );
    await expectLater(
      client.writeCccd(_cccd, 1),
      throwsA(attError(0x12, _cccd, 0x05)),
    );
    // All three wanted level 2; one attempt answered them all.
    expect(peer.elevations, [2]);
    expect(client.isOpen, isTrue);
    expect(await client.read(_open), [10]);
    expect(peer.violations, isEmpty);
  });

  test('0x05 on an encrypted link asks for MITM protection', () async {
    peer.linkSecurity = 2;
    expect(await client.read(_mitm), [30]);
    expect(peer.elevations, [3]);
  });

  test('0x0F on an encrypted link is final: no elevation', () async {
    peer.linkSecurity = 2;
    await expectLater(
      client.read(_strict),
      throwsA(attError(0x0a, _strict, AttError.insufficientEncryption)),
    );
    expect(peer.elevations, isEmpty);
    expect(reads(), [_strict]);
  });

  test('0x0C (key size) on an unencrypted link encrypts too', () async {
    expect(await client.read(_keySize), [50]);
    expect(peer.elevations, [2]);
  });

  test('the retry happens once, even when it fails again', () async {
    // Encrypting (level 2) is not enough for _strict (level 3): the retry
    // earns 0x0F again, and that is the answer.
    await expectLater(
      client.read(_strict),
      throwsA(attError(0x0a, _strict, AttError.insufficientEncryption)),
    );
    expect(peer.elevations, [2]);
    expect(reads(), [_strict, _strict]);
  });

  test('writes, long writes and CCCD writes are raised as well', () async {
    await client.writeCccd(_cccd, 0x0001);
    expect(peer.cccd(_cccd), 0x0001);
    expect(peer.elevations, [2]);

    await client.close();
    connect();
    final long = List<int>.generate(40, (i) => i);
    await client.write(_encrypted, long);
    expect(peer.attributes[_encrypted]!.value, long);
    expect(peer.elevations, [2, 2]);
    // The refused first piece, its retry, then the rest.
    final prepares = peer.requests
        .where((r) => r[0] == AttOpcode.prepareWriteRequest)
        .map((r) => r[3] | (r[4] << 8));
    expect(prepares, [0, 0, 18, 36]);
    expect(peer.violations, isEmpty);
  });

  test('many callers needing security at once: one pairing', () async {
    // Three at once: the first is refused and parks everything behind it;
    // the other two reach the peer only on the raised link, so they never
    // ask at all. (A failed attempt shared by later asks is the "turns
    // down at once" test above: a failed pairing closes the link.)
    peer.pairingDelay = const Duration(milliseconds: 20);
    final results = await Future.wait([
      client.read(_encrypted),
      client.read(_keySize),
      client.writeCccd(_cccd, 1).then((_) => Uint8List(0)),
    ]);
    expect(results.take(2), [
      [20],
      [50],
    ]);
    expect(peer.cccd(_cccd), 1);
    expect(peer.elevations, [2]);
    expect(peer.violations, isEmpty);
  });

  test('nothing is sent while pairing runs; the retry goes first', () async {
    peer.pairingDelay = const Duration(milliseconds: 60);
    final secured = client.read(_encrypted);
    final behind = client.read(_open);
    final write = client.write(_open, [11]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // Mid-pairing: the refused read only, the rest held back.
    expect(reads(), [_encrypted]);
    expect(peer.requests, hasLength(1));
    expect(await secured, [20]);
    expect(await behind, [10]);
    await write;
    expect(reads(), [_encrypted, _encrypted, _open]);
    expect(peer.requests.last[0], AttOpcode.writeRequest);
    // The fake records any request that reaches it mid-pairing, or out of
    // turn; there were none.
    expect(peer.violations, isEmpty);
  });

  test('a pairing that never finishes is given up on', () async {
    await client.close();
    peer.pairingDelay = const Duration(seconds: 10);
    connect(securityTimeout: const Duration(milliseconds: 50));
    final clock = Stopwatch()..start();
    await expectLater(
      client.read(_encrypted),
      throwsA(attError(0x0a, _encrypted, 0x05)),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    expect(peer.linkSecurity, 1);
    // Given up on, the socket would sit in BT_CONFIG: closed instead.
    expect(channel.isOpen, isFalse);
  });

  test('once raised, a link lost before the retry is answered is just a '
      'lost link', () async {
    peer.pairingDelay = const Duration(milliseconds: 30);
    final pending = client.read(_encrypted);
    // Pairing succeeds; the retry then goes unanswered and the link drops.
    Timer(const Duration(milliseconds: 10), () {
      peer.silentOpcodes.add(AttOpcode.readRequest);
    });
    Timer(const Duration(milliseconds: 80), peer.dropLink);
    await expectLater(pending, throwsA(isA<AttLinkClosedException>()));
    expect(peer.elevations, [2]);
    expect(reads(), [_encrypted, _encrypted]);
  });

  group('secure: false', () {
    test(
      'the error is the answer: no pairing, whatever the peer asks',
      () async {
        await expectLater(
          client.write(_cccd, const [2, 0], secure: false),
          throwsA(attError(0x12, _cccd, AttError.insufficientAuthentication)),
        );
        expect(peer.elevations, isEmpty);
        expect(peer.writes, isEmpty);
        expect(client.isOpen, isTrue);
      },
    );

    test('...for a long write too, from its first piece', () async {
      await expectLater(
        client.write(_encrypted, List<int>.filled(40, 1), secure: false),
        throwsA(
          attError(0x16, _encrypted, AttError.insufficientAuthentication),
        ),
      );
      expect(peer.elevations, isEmpty);
      expect(
        peer.requests.where((r) => r[0] == AttOpcode.prepareWriteRequest),
        hasLength(1),
      );
    });

    test('and a write the link already allows simply happens', () async {
      await client.write(_open, const [7], secure: false);
      expect(peer.attributes[_open]!.value, [7]);
      // writeCccd stays securable: it still raises the link on demand.
      await client.writeCccd(_cccd, 0x0002);
      expect(peer.elevations, [2]);
      expect(peer.cccd(_cccd), 0x0002);
    });
  });

  test('switched off, the error is simply the answer', () async {
    await client.close();
    connect(elevateSecurityOnDemand: false);
    await expectLater(
      client.read(_encrypted),
      throwsA(attError(0x0a, _encrypted, 0x05)),
    );
    expect(peer.elevations, isEmpty);
  });

  test('discovery and the MTU exchange are never retried', () async {
    // A peer that (wrongly) guards discovery: answer the walk's first
    // request, and the exchange, with 0x05 by hand.
    peer.silentOpcodes.addAll([
      AttOpcode.readByGroupTypeRequest,
      AttOpcode.exchangeMtuRequest,
    ]);
    final walk = expectLater(
      client.discoverServices(),
      throwsA(attError(0x10, 1, 0x05)),
    );
    await Future<void>.delayed(Duration.zero);
    channel.deliver(AttEncode.errorResponse(0x10, 1, 0x05));
    await walk;

    final exchange = expectLater(
      client.exchangeMtu(),
      throwsA(attError(0x02, 0, 0x05)),
    );
    await Future<void>.delayed(Duration.zero);
    channel.deliver(AttEncode.errorResponse(0x02, 0, 0x05));
    await exchange;
    expect(peer.elevations, isEmpty);
  });

  test('a stored bond still re-encrypts each new link', () async {
    expect(await client.read(_encrypted), [20]);
    await client.close();
    connect();
    // The new link starts at level 1; the bond makes the upgrade quick,
    // but it is still one the peer has to ask for.
    expect(channel.securityLevel, 1);
    expect(await client.read(_encrypted), Uint8List.fromList([20]));
    expect(peer.elevations, [2, 2]);
  });
}
