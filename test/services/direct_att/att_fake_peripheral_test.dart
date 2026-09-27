// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The fake ATT peripheral itself (test/fakes/fake_att_channel.dart). Every
// direct-ATT test above this layer trusts it twice over — to answer like a
// compliant server, and to referee: an empty `violations` list is only proof
// of discipline if the fake demonstrably records the violations. So those
// detectors, the per-link reset, the knobs and the factory's connect
// behaviour are tested here, driving raw PDUs rather than an AttClient.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_channel.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';

import '../../fakes/fake_att_channel.dart';

const _address = 'C0:FF:EE:00:00:01';

/// Collects what a channel delivers.
class _Wire {
  final FakeAttChannel channel;
  final List<Uint8List> received = [];
  late final StreamSubscription<Uint8List> _sub;
  _Wire(this.channel) {
    _sub = channel.incoming.listen(received.add);
  }
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  Future<void> dispose() => _sub.cancel();
}

FakeAttPeripheral _small() => FakeAttPeripheral()
  ..service(0x0001, 0x0006, 0x180f)
  ..characteristic(0x0002, 0x0003, 0x1a, 0x2a19, const [87])
  ..descriptor(0x0004, 0x2902)
  ..characteristic(0x0005, 0x0006, 0x0e, 0x2a1a, List.filled(10, 1));

void main() {
  group('the referee', () {
    late FakeAttPeripheral peer;
    late _Wire wire;

    setUp(() {
      peer = _small();
      wire = _Wire(FakeAttChannel(peer));
    });

    tearDown(() => wire.dispose());

    test('a request before the last one is answered is pipelining', () async {
      wire.channel
        ..send(AttEncode.read(0x0003))
        ..send(AttEncode.read(0x0006));
      expect(peer.violations.single, contains('0x0a was unanswered'));
      await wire.settle();
      // Waiting for the answer first is fine, including with latency.
      peer
        ..violations.clear()
        ..responseLatency = const Duration(milliseconds: 5);
      wire.channel.send(AttEncode.read(0x0003));
      await Future<void>.delayed(const Duration(milliseconds: 2));
      wire.channel.send(AttEncode.read(0x0006)); // still in the air: too soon
      expect(peer.violations, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      wire.channel.send(AttEncode.read(0x0003));
      expect(peer.violations, hasLength(1));
    });

    test('a silent request stays outstanding until something answers', () {
      peer.silentOpcodes.add(AttOpcode.readRequest);
      wire.channel.send(AttEncode.read(0x0003));
      // A stray answer to something else does not release it...
      wire.channel.deliver(AttEncode.errorResponse(0x08, 1, 0x0a));
      wire.channel.send(AttEncode.write(0x0003, [1]));
      expect(peer.violations, hasLength(1));
      // ...an answer to it does.
      wire.channel.deliver(Uint8List.fromList([AttOpcode.readResponse, 1]));
      wire.channel.deliver(Uint8List.fromList([AttOpcode.writeResponse]));
      wire.channel.send(AttEncode.read(0x0006));
      expect(peer.violations, hasLength(1));
    });

    test('a PDU over the link MTU is a violation, of any kind', () async {
      wire.channel.send(AttEncode.write(0x0006, List.filled(21, 0)));
      await wire.settle();
      wire.channel.send(AttEncode.writeCommand(0x0006, List.filled(21, 0)));
      expect(peer.violations, [
        contains('24-byte PDU 0x12 on a link with MTU 23'),
        contains('24-byte PDU 0x52 on a link with MTU 23'),
      ]);
    });

    test('a request mid-pairing is a violation, and refused like BT_CONFIG '
        'refuses it', () async {
      peer.pairingDelay = const Duration(milliseconds: 30);
      final pairing = wire.channel.elevateSecurity(2);
      // The socket is in BT_CONFIG: the kernel refuses every send with
      // ENOTCONN, and the link itself is fine.
      expect(
        () => wire.channel.send(AttEncode.read(0x0003)),
        throwsA(
          isA<AttChannelException>().having(
            (e) => e.errno,
            'errno',
            AttErrno.enotconn,
          ),
        ),
      );
      expect(
        () => wire.channel.send(AttEncode.writeCommand(6, [1])),
        throwsA(isA<AttChannelException>()),
      );
      expect(wire.channel.isOpen, isTrue);
      expect(wire.channel.sent, isEmpty, reason: 'nothing went out');
      expect(peer.violations.single, contains('while pairing was running'));
      // A PDU from the peer puts the socket back to connected before SMP
      // is done (the kernel's l2cap_chan_ready): sends work again, but a
      // request is still a request mid-pairing.
      peer.notify(0x0006, [1]); // no CCCD: always delivered
      wire.channel.send(AttEncode.read(0x0003));
      expect(peer.violations, hasLength(2));
      expect(await pairing, isTrue);
    });

    test('an answer to nothing the peripheral asked is a violation', () {
      wire.channel.send(AttEncode.exchangeMtuResponse(517));
      expect(peer.violations.single, contains('answering nothing'));
      // A confirmation nobody waited for is only counted.
      wire.channel.send(AttEncode.handleValueConfirmation());
      expect(peer.violations, hasLength(1));
      expect(peer.confirmations, 1);
    });

    test('commands are applied and logged apart from requests', () async {
      wire.channel.send(AttEncode.writeCommand(0x0006, [5]));
      expect(peer.commands, hasLength(1));
      expect(peer.requests, isEmpty);
      // Field by field: a record's == compares its List field by identity.
      final write = peer.writes.single;
      expect(write.handle, 0x0006);
      expect(write.value, [5]);
      expect(write.withResponse, isFalse);
      await wire.settle();
      expect(wire.received, isEmpty);
    });
  });

  group('the server', () {
    late FakeAttPeripheral peer;
    late _Wire wire;

    setUp(() {
      peer = _small();
      wire = _Wire(FakeAttChannel(peer));
    });

    tearDown(() => wire.dispose());

    Future<Uint8List> ask(List<int> pdu) async {
      wire.channel.send(Uint8List.fromList(pdu));
      await wire.settle();
      return wire.received.removeLast();
    }

    test(
      'is compliant by default; the LDM330 preset keeps its silence',
      () async {
        expect(
          await ask(AttEncode.readByType(1, 0xffff, 0x2b3a)),
          AttEncode.errorResponse(0x08, 1, 0x0a),
        );
        final meter = FakeAttPeripheral.ldm330();
        final meterWire = _Wire(FakeAttChannel(meter));
        meterWire.channel.send(AttEncode.readByType(1, 0xffff, 0x2b3a));
        meterWire.channel.deliver(Uint8List.fromList([0x0b])); // unblock
        meterWire.channel.send(AttEncode.readByType(1, 0xffff, 0x2b2a));
        await meterWire.settle();
        expect(meterWire.received, [
          [0x0b],
        ], reason: 'nothing but the hand-delivered PDU');
        await meterWire.dispose();
      },
    );

    test(
      'a range starting at 0 or running backwards: invalid handle',
      () async {
        expect(
          await ask(AttEncode.readByGroupType(0, 0xffff, 0x2800)),
          AttEncode.errorResponse(0x10, 0, 0x01),
        );
        expect(
          await ask(AttEncode.findInformation(5, 4)),
          AttEncode.errorResponse(0x04, 5, 0x01),
        );
      },
    );

    test('a notification is cut to MTU-3, as a server must', () async {
      await ask(AttEncode.write(0x0004, [1, 0])); // notifications on
      peer.notify(0x0003, List.filled(40, 7));
      await wire.settle();
      expect(wire.received.single.length, 23);
      expect(wire.received.single.sublist(3), List.filled(20, 7));
    });

    test('notify and indicate go out only as the CCCD allows', () async {
      expect(peer.cccdHandleOf(0x0003), 0x0004);
      expect(peer.cccdHandleOf(0x0006), isNull, reason: 'no CCCD');
      expect(peer.cccdHandleOf(0x0002), isNull, reason: 'a declaration');
      Future<List<int>> pushed(int handle, {bool indicate = false}) async {
        peer.notify(handle, [9], indicate: indicate);
        await wire.settle();
        final out = [for (final p in wire.received) p[0]];
        wire.received.clear();
        return out;
      }

      const ntf = AttOpcode.handleValueNotification;
      const ind = AttOpcode.handleValueIndication;
      // A new link: every CCCD 0, so nothing from 0x0003.
      expect(await pushed(0x0003), isEmpty);
      expect(await pushed(0x0003, indicate: true), isEmpty);
      await ask(AttEncode.write(0x0004, [1, 0]));
      expect(await pushed(0x0003), [ntf]);
      expect(await pushed(0x0003, indicate: true), isEmpty);
      await ask(AttEncode.write(0x0004, [2, 0]));
      expect(await pushed(0x0003), isEmpty);
      expect(await pushed(0x0003, indicate: true), [ind]);
      // No CCCD at all: firmware that notifies anyway is heard.
      expect(await pushed(0x0006), [ntf]);
      // And one that ignores its CCCD is heard whatever it says.
      await ask(AttEncode.write(0x0004, [0, 0]));
      peer.ignoresCccd = true;
      expect(await pushed(0x0003), [ntf]);
    });

    test(
      'ignoresStartHandle: every discovery page starts at handle 1',
      () async {
        peer.ignoresStartHandle = true;
        final groups = AttDecode.readByGroupType(
          await ask(AttEncode.readByGroupType(0x0005, 0xffff, 0x2800)),
        );
        expect(groups.single.start, 0x0001);
        final decls = AttDecode.readByType(
          await ask(AttEncode.readByType(0x0004, 0x0006, 0x2803)),
        );
        expect(decls.map((e) => e.handle), [0x0002, 0x0005]);
        final info = AttDecode.findInformation(
          await ask(AttEncode.findInformation(0x0005, 0x0006)),
        );
        expect(info.first.handle, 0x0001);
        // The End Handle still bounds it, and a malformed range is still one.
        expect(info.last.handle, lessThanOrEqualTo(0x0006));
        expect(
          await ask(AttEncode.findInformation(5, 4)),
          AttEncode.errorResponse(0x04, 5, 0x01),
        );
      },
    );

    test('blobIgnoresOffset: every Read Blob is the value from 0', () async {
      peer
        ..attributes[0x0006]!.value = Uint8List.fromList(
          List.generate(30, (i) => i),
        )
        ..blobIgnoresOffset = true;
      final expected = [
        AttOpcode.readBlobResponse,
        ...List.generate(22, (i) => i),
      ];
      expect(await ask(AttEncode.readBlob(0x0006, 22)), expected);
      expect(await ask(AttEncode.readBlob(0x0006, 400)), expected);
    });

    test('Read Blob on a short attribute: data, or "not long"', () async {
      expect(await ask(AttEncode.readBlob(0x0006, 4)), [
        AttOpcode.readBlobResponse,
        ...List.filled(6, 1),
      ]);
      peer.blobOnShortAttribute = FakeBlobOnShortAttribute.attributeNotLong;
      expect(
        await ask(AttEncode.readBlob(0x0006, 4)),
        AttEncode.errorResponse(0x0c, 6, AttError.attributeNotLong),
      );
      // Offset 0 is a plain read of the start either way.
      expect((await ask(AttEncode.readBlob(0x0006, 0)))[0], 0x0d);
    });

    test('prepared writes queue per link and apply all at once', () async {
      expect(await ask(AttEncode.prepareWrite(0x0006, 0, [1, 2, 3])), [
        0x17,
        0x06,
        0x00,
        0x00,
        0x00,
        1,
        2,
        3,
      ]);
      expect(
        await ask(AttEncode.prepareWrite(0x0006, 3, [4, 5])),
        hasLength(7),
      );
      expect(peer.attributes[0x0006]!.value, List.filled(10, 1));
      expect(await ask(AttEncode.executeWrite(commit: true)), [0x19]);
      expect(peer.attributes[0x0006]!.value, [1, 2, 3, 4, 5]);
      expect(peer.writes.single.value, [1, 2, 3, 4, 5]);

      // Cancelled: nothing applied. An offset past the value: 0x07.
      await ask(AttEncode.prepareWrite(0x0006, 0, [9]));
      expect(await ask(AttEncode.executeWrite(commit: false)), [0x19]);
      expect(peer.attributes[0x0006]!.value, [1, 2, 3, 4, 5]);
      await ask(AttEncode.prepareWrite(0x0006, 9, [9]));
      expect(
        await ask(AttEncode.executeWrite(commit: true)),
        AttEncode.errorResponse(0x18, 6, AttError.invalidOffset),
      );
      expect(peer.writes, hasLength(1));
    });

    test('security: too weak a link gets the attribute its error', () async {
      peer.attributes[0x0003]!
        ..requiredSecurity = 2
        ..securityError = AttError.insufficientEncryption;
      expect(
        await ask(AttEncode.read(0x0003)),
        AttEncode.errorResponse(0x0a, 3, 0x0f),
      );
      peer.linkSecurity = 2;
      expect(await ask(AttEncode.read(0x0003)), [0x0b, 87]);
    });

    test('Service Changed: the helper builds and indicates it', () async {
      peer.gattService(0x0010);
      expect(peer.serviceChangedHandle, 0x0012);
      expect(peer.serviceChangedCccdHandle, 0x0013);
      // Not until the client asks for it, as on a compliant server.
      peer.indicateServiceChanged(0x0001, 0xffff);
      await wire.settle();
      expect(wire.received, isEmpty);
      await ask(AttEncode.write(0x0013, [2, 0]));
      expect(await ask(AttEncode.readByGroupType(0x0010, 0xffff, 0x2800)), [
        0x11,
        6,
        0x10,
        0,
        0x13,
        0,
        0x01,
        0x18,
      ]);
      peer.indicateServiceChanged(0x0001, 0xffff);
      await wire.settle();
      expect(wire.received.single, [0x1d, 0x12, 0, 0x01, 0, 0xff, 0xff]);
    });

    test('a request to the client completes with its answer', () async {
      final answered = peer.sendRequestToClient(AttEncode.exchangeMtu(100));
      await wire.settle();
      expect(wire.received.single, AttEncode.exchangeMtu(100));
      wire.channel.send(AttEncode.exchangeMtuResponse(185));
      expect(await answered, AttEncode.exchangeMtuResponse(185));
      expect(peer.mtu, 100, reason: 'min(100, 185)');
      expect(peer.clientResponses, hasLength(1));

      final orphan = peer.sendRequestToClient(AttEncode.read(1));
      peer.dropLink();
      await expectLater(orphan, throwsStateError);
    });
  });

  group('links', () {
    test('each new link resets MTU, security and (unbonded) CCCDs', () async {
      final peer = _small()..serverRxMtu = 247;
      final first = FakeAttChannel(peer);
      final wire = _Wire(first);
      first.send(AttEncode.exchangeMtu(517));
      await wire.settle();
      first.send(AttEncode.write(0x0004, [1, 0]));
      expect(await first.elevateSecurity(2), isTrue);
      expect((peer.mtu, peer.linkSecurity, peer.cccd(0x0004)), (247, 2, 1));
      await first.close();

      final second = FakeAttChannel(peer);
      expect((peer.mtu, peer.linkSecurity, peer.cccd(0x0004)), (23, 1, 1));
      expect(second.securityLevel, 1);
      expect(peer.bonded, isTrue, reason: 'pairing bonded, so CCCDs stay');
      await second.close();

      peer.bonded = false;
      FakeAttChannel(peer);
      expect(peer.cccd(0x0004), 0);
      await wire.dispose();
    });

    test('pairing: accepted, refused, timed out, cut off, or turned down '
        'at once', () async {
      final peer = _small();
      var channel = FakeAttChannel(peer);
      expect(await channel.elevateSecurity(1), isTrue, reason: 'already');

      // Refused, or given up on: false, and the channel closed (the
      // production channel's contract — see AttChannel.elevateSecurity).
      peer.acceptsPairing = false;
      expect(await channel.elevateSecurity(2), isFalse);
      expect(channel.securityLevel, 1);
      expect(channel.isOpen, isFalse);
      expect(channel.closeErrno, isNull, reason: 'the channel closed it');

      channel = FakeAttChannel(peer);
      peer
        ..acceptsPairing = true
        ..pairingDelay = const Duration(seconds: 5);
      expect(
        await channel.elevateSecurity(
          2,
          timeout: const Duration(milliseconds: 20),
        ),
        isFalse,
      );
      expect(channel.isOpen, isFalse);

      // Cut off: the peer's hang-up is the link's end, with its errno.
      channel = FakeAttChannel(peer);
      final cutOff = channel.elevateSecurity(2);
      peer.dropLink(errno: AttErrno.eacces);
      expect(await cutOff, isFalse);
      expect(channel.closeErrno, AttErrno.eacces);

      // Turned down before it began: nothing changed, the link stays up.
      channel = FakeAttChannel(peer);
      peer.smpUnavailable = true;
      expect(await channel.elevateSecurity(2), isFalse);
      expect(channel.isOpen, isTrue);
      expect(peer.elevations, [1, 2, 2, 2, 2]);

      await channel.close();
      channel = FakeAttChannel(peer);
      peer
        ..smpUnavailable = false
        ..pairingDelay = Duration.zero;
      expect(await channel.elevateSecurity(3), isTrue);
      expect(channel.securityLevel, 3);
      await channel.close();
      expect(channel.securityLevel, 1);
    });

    test('closeErrno: what the link died with, never after close', () async {
      final peer = _small();
      final dropped = FakeAttChannel(peer);
      expect(dropped.closeErrno, isNull);
      peer.dropLink(errno: 104);
      expect(dropped.closeErrno, 104);
      expect(dropped.isOpen, isFalse);

      final closed = FakeAttChannel(peer);
      await closed.close();
      expect(closed.closeErrno, isNull);
    });
  });

  group('the factory', () {
    late FakeAttChannelFactory factory;
    late FakeAttPeripheral peer;

    setUp(() {
      factory = FakeAttChannelFactory();
      peer = factory.peripherals[_address] = _small();
    });

    TypeMatcher<AttChannelException> errno(int code) =>
        isA<AttChannelException>()
            .having((e) => e.stage, 'stage', 'connect')
            .having((e) => e.errno, 'errno', code);

    test('connects, in any spelling of the address, and logs it', () async {
      final channel = await factory.connect(
        _address.toLowerCase(),
        randomAddress: false,
      );
      expect(channel.isOpen, isTrue);
      expect(peer.isConnected, isTrue);
      expect(factory.attempts.single, (
        address: _address.toLowerCase(),
        random: false,
      ));
      expect(factory.channels.single, same(channel));
    });

    test('the wrong address type is refused at once', () async {
      await expectLater(
        factory.connect(_address, randomAddress: true),
        throwsA(errno(AttErrno.econnrefused)),
      );
      peer.randomAddress = true;
      expect(await factory.connect(_address, randomAddress: true), isNotNull);
    });

    test('queued failures come first, one per attempt', () async {
      const busy = AttChannelException('connect', 'busy', errno: 16);
      factory.failNextConnects(_address, [busy, busy]);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          factory.connect(_address, randomAddress: false),
          throwsA(
            isA<AttChannelException>().having((e) => e.isBusy, 'isBusy', true),
          ),
        );
      }
      expect(await factory.connect(_address, randomAddress: false), isNotNull);
      expect(factory.attempts, hasLength(3));
    });

    test('nobody at the address; a malformed address', () async {
      await expectLater(
        factory.connect('AA:BB:CC:DD:EE:FF', randomAddress: false),
        throwsA(errno(112)),
      );
      await expectLater(
        factory.connect('not-an-address', randomAddress: false),
        throwsArgumentError,
      );
    });

    test('latency, a cancel that beats it, and one that does not', () async {
      factory.connectLatency = const Duration(milliseconds: 40);
      final clock = Stopwatch()..start();
      await factory.connect(_address, randomAddress: false);
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(35));

      final cancel = Completer<void>();
      final attempt = factory.connect(
        _address,
        randomAddress: false,
        cancel: cancel.future,
      );
      Timer(const Duration(milliseconds: 5), cancel.complete);
      await expectLater(
        attempt,
        throwsA(
          errno(
            AttErrno.ecanceled,
          ).having((e) => e.isCanceled, 'isCanceled', true),
        ),
      );
      expect(factory.channels, hasLength(1), reason: 'no link was made');

      // Cancelled already: fails without waiting out the latency.
      await expectLater(
        factory.connect(_address, randomAddress: false, cancel: Future.value()),
        throwsA(errno(AttErrno.ecanceled)),
      );

      // Cancelling after the link is up changes nothing.
      final late = Completer<void>();
      final up = await factory.connect(
        _address,
        randomAddress: false,
        cancel: late.future,
      );
      late.complete();
      await Future<void>.delayed(Duration.zero);
      expect(up.isOpen, isTrue);
    });

    test('a connect slower than its timeout times out', () async {
      factory.connectLatency = const Duration(seconds: 5);
      final clock = Stopwatch()..start();
      await expectLater(
        factory.connect(
          _address,
          randomAddress: false,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(errno(AttErrno.etimedout)),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });
}
