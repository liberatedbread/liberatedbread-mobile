// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The GATT client against scripted peripherals — mostly the LDM330 preset,
// the device this path exists for: the discovery walk, the request/response
// discipline (refereed by the fake: it records any pipelining or oversize
// PDU in `violations`), long writes, the minimal server that answers the
// peer's own requests, and the two things the whole path exists for — never
// sending the probe the meter ignores, and surviving what bluetoothd does
// not. Security on demand has its own file, att_security_test.dart.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_channel.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_client.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';

import '../../fakes/fake_att_channel.dart';

void main() {
  late FakeAttPeripheral meter;
  late FakeAttChannel channel;
  late AttClient client;
  final log = <String>[];

  setUp(() {
    log.clear();
    meter = FakeAttPeripheral.ldm330(serverRxMtu: 23);
    channel = FakeAttChannel(meter);
    client = AttClient(channel, log: log.add);
  });

  tearDown(() => client.close());

  /// The 16-bit type of every Read By Type the client sent.
  Iterable<int> readByTypeTargets() => channel.sent
      .where((p) => p[0] == AttOpcode.readByTypeRequest && p.length == 7)
      .map((p) => p[5] | (p[6] << 8));

  group('discovery', () {
    test('walks the meter table the way its vendor app does', () async {
      final services = await client.discoverServices();
      expect(
        services.map((s) => s.uuid),
        [
          0x1800,
          0x180a,
          0x1803,
          0x1802,
          0x1804,
          0x180f,
          0x180d,
          0xf150,
          0xfff3,
        ].map(uuid16ToString),
      );
      final f150 = services.firstWhere((s) => s.uuid == uuid16ToString(0xf150));
      expect(f150.startHandle, 0x0050);
      expect(f150.endHandle, 0x0055);
      expect(f150.characteristics, hasLength(2));
      final data = f150.characteristics[0];
      expect(data.uuid, uuid16ToString(0xf154));
      expect(data.valueHandle, 0x0052);
      expect(data.canNotify, isTrue);
      expect(data.cccdHandle, 0x0053);
      final cmd = f150.characteristics[1];
      expect(cmd.uuid, uuid16ToString(0xf151));
      expect(cmd.valueHandle, 0x0055);
      expect(cmd.canWrite, isTrue);
      expect(cmd.canWriteWithoutResponse, isTrue);
      expect(cmd.cccdHandle, isNull);
      // Device Information: six characteristics, no descriptors, and the
      // discovery did not go looking for any in a zero-width gap.
      final di = services.firstWhere((s) => s.uuid == uuid16ToString(0x180a));
      expect(di.characteristics, hasLength(6));
      expect(di.characteristics.every((c) => c.descriptors.isEmpty), isTrue);
    });

    test('never sends the probes bluetoothd opens with', () async {
      await client.discoverServices();
      expect(readByTypeTargets(), isNot(contains(0x2b3a)));
      expect(readByTypeTargets(), isNot(contains(0x2b2a)));
      expect(readByTypeTargets().toSet(), {0x2803});
      // Nor the optional secondary/include walks some firmware ignores.
      final groupTypes = channel.sent
          .where((p) => p[0] == AttOpcode.readByGroupTypeRequest)
          .map((p) => p[5] | (p[6] << 8))
          .toSet();
      expect(groupTypes, {0x2800});
      expect(readByTypeTargets(), isNot(contains(0x2802)));
    });

    test(
      'asks for descriptors only where a characteristic leaves room',
      () async {
        await client.discoverServices();
        final findInfoRanges = channel.sent
            .where((p) => p[0] == AttOpcode.findInformationRequest)
            .map((p) => (p[1] | (p[2] << 8), p[3] | (p[4] << 8)))
            .toList();
        // Exactly the five single-handle gaps the capture shows Android
        // probing: the CCCDs of Tx Power, Battery, Heart Rate, f154, fff4.
        expect(findInfoRanges, [
          (0x33, 0x33),
          (0x37, 0x37),
          (0x3c, 0x3c),
          (0x53, 0x53),
          (0x63, 0x63),
        ]);
      },
    );

    test('an empty table is an empty list, not an error', () async {
      final empty = FakeAttPeripheral();
      final c = AttClient(FakeAttChannel(empty));
      expect(await c.discoverServices(), isEmpty);
      await c.close();
    });
  });

  group('a peer that ignores the Starting Handle', () {
    // Every page it sends starts at handle 1, whatever was asked. Each
    // request is answered, so no ATT timeout would ever end a walk that
    // trusts the page to move it forward: these would spin forever. A real
    // (if tiny) latency makes the wait timer-driven, so a regression fails
    // on the timeout instead of starving the event loop with microtasks.
    const bounded = Duration(seconds: 5);
    const latency = Duration(milliseconds: 1);

    test('primary service discovery keeps the first page and stops', () async {
      meter
        ..ignoresStartHandle = true
        ..responseLatency = latency;
      final services = await client.discoverServices().timeout(bounded);
      // At MTU 23 the first page holds three services; asking from 0x002d
      // gets the same page again, all behind the start: the walk ends.
      expect(services.map((s) => s.uuid), [
        uuid16ToString(0x1800),
        uuid16ToString(0x180a),
        uuid16ToString(0x1803),
      ]);
      expect(
        meter.requests.where((r) => r[0] == AttOpcode.readByGroupTypeRequest),
        hasLength(2),
      );
      // Generic Access starts at 1, so its page is the right one; the other
      // two are answered with it, all outside their range: kept out.
      expect(services[0].characteristics, hasLength(3));
      expect(services[1].characteristics, isEmpty);
      expect(services[2].characteristics, isEmpty);
      expect(meter.violations, isEmpty);
    });

    test('descriptor discovery keeps what is in range and stops', () async {
      await client.close();
      // One characteristic with six descriptors: at MTU 23 Find
      // Information pages hold five 16-bit entries, so the gap takes two.
      final peer = FakeAttPeripheral()
        ..service(0x0001, 0x0009, 0x180f)
        ..characteristic(0x0002, 0x0003, 0x12, 0x2a19, const [1]);
      for (var h = 0x0004; h <= 0x0009; h++) {
        peer.descriptor(h, h == 0x0004 ? 0x2902 : 0x2901);
      }
      final c = AttClient(FakeAttChannel(peer));
      final whole = await c.discoverServices();
      expect(whole.single.characteristics.single.descriptors, hasLength(6));
      await c.close();

      peer
        ..ignoresStartHandle = true
        ..responseLatency = latency
        ..requests.clear();
      final c2 = AttClient(FakeAttChannel(peer));
      final services = await c2.discoverServices().timeout(bounded);
      final descriptors = services.single.characteristics.single.descriptors;
      // Asked from 4, the page is 1..5: only 4 and 5 are in range. Asked
      // from 6, the page is 1..5 again, none in range: the walk ends there.
      expect(descriptors.map((d) => d.handle), [0x0004, 0x0005]);
      expect(
        peer.requests
            .where((r) => r[0] == AttOpcode.findInformationRequest)
            .map((r) => r[1] | (r[2] << 8)),
        [0x0004, 0x0006],
      );
      expect(peer.violations, isEmpty);
      await c2.close();
    });
  });

  group('a long read stops at the 512-byte attribute maximum', () {
    List<int> blobOffsets() => [
      for (final r in meter.requests)
        if (r[0] == AttOpcode.readBlobRequest) r[3] | (r[4] << 8),
    ];

    test('against a peer that ignores the Read Blob offset', () async {
      // Every blob answers the value's first 22 bytes again; only the cap
      // ends the read. (Latency: see the Starting Handle group.)
      meter
        ..blobIgnoresOffset = true
        ..responseLatency = const Duration(milliseconds: 1);
      final value = List<int>.generate(30, (i) => i);
      meter.attributes[0x0014]!.value = Uint8List.fromList(value);
      final read = await client
          .read(0x0014)
          .timeout(const Duration(seconds: 5));
      expect(read, hasLength(attMaxAttributeLength));
      expect(read.sublist(22, 44), value.sublist(0, 22));
      // 22 + 23 x 22 = 528 >= 512; never an offset at or past the cap.
      expect(blobOffsets(), hasLength(23));
      expect(blobOffsets().last, lessThan(attMaxAttributeLength));
    });

    test(
      'a value exactly 512 long reads whole, with no blob past it',
      () async {
        final value = List<int>.generate(512, (i) => i & 0xff);
        meter.attributes[0x0014]!.value = Uint8List.fromList(value);
        expect(await client.read(0x0014), value);
        expect(blobOffsets().last, 506, reason: '22 x 23; the last piece is 6');
      },
    );

    test('an over-long value is cut at 512', () async {
      final value = List<int>.generate(600, (i) => i & 0xff);
      meter.attributes[0x0014]!.value = Uint8List.fromList(value);
      expect(await client.read(0x0014), value.sublist(0, 512));
      expect(blobOffsets().every((o) => o < 512), isTrue);
    });

    test('...even by the first response alone, at MTU 517', () async {
      meter.serverRxMtu = attMaxMtu;
      expect(await client.exchangeMtu(), attMaxMtu);
      final value = List<int>.generate(600, (i) => i & 0xff);
      meter.attributes[0x0014]!.value = Uint8List.fromList(value);
      // The Read Response carries MTU-1 = 516 bytes: already past the cap.
      expect(await client.read(0x0014), value.sublist(0, 512));
      expect(blobOffsets(), isEmpty);
    });
  });

  group('mtu', () {
    test('settles on the smaller side', () async {
      meter.serverRxMtu = 247;
      expect(await client.exchangeMtu(517), 247);
      expect(client.mtu, 247);
      expect(meter.mtu, 247);
    });

    test('a peer that refuses the exchange keeps the default', () async {
      meter.refusesMtuExchange = true;
      expect(await client.exchangeMtu(517), 23);
      expect(client.mtu, 23);
    });

    test('offers localRxMtu by default, and says when the MTU moves', () async {
      await client.close();
      meter.serverRxMtu = 247;
      final ch = FakeAttChannel(meter);
      final c = AttClient(ch, localRxMtu: 185);
      final changes = <int>[];
      final sub = c.mtuChanges.listen(changes.add);
      expect(await c.exchangeMtu(), 185);
      expect(ch.sent.single, AttEncode.exchangeMtu(185));
      // The same answer again is no change.
      await c.exchangeMtu();
      await Future<void>.delayed(Duration.zero);
      expect(changes, [185]);
      await sub.cancel();
      await c.close();
    });

    test('an out-of-range localRxMtu is a programming error', () {
      expect(() => AttClient(channel, localRxMtu: 22), throwsArgumentError);
      expect(() => AttClient(channel, localRxMtu: 518), throwsArgumentError);
    });
  });

  group('reads and writes', () {
    test('reads a value by handle', () async {
      await client.discoverServices();
      expect(String.fromCharCodes(await client.read(0x0012)), 'Precaster');
    });

    test('reads a long value with read blob continuations', () async {
      final long = List<int>.generate(60, (i) => i);
      meter.attributes[0x0014]!.value = Uint8List.fromList(long);
      expect(await client.read(0x0014), long);
      expect(
        channel.sent.where((p) => p[0] == AttOpcode.readBlobRequest).length,
        greaterThan(0),
      );
    });

    test('a value of exactly MTU-1 bytes ends cleanly', () async {
      final exact = List<int>.filled(22, 7);
      meter.attributes[0x0014]!.value = Uint8List.fromList(exact);
      expect(await client.read(0x0014), exact);
    });

    test(
      '...also when the server answers the blob "attribute not long"',
      () async {
        meter.blobOnShortAttribute = FakeBlobOnShortAttribute.attributeNotLong;
        final exact = List<int>.filled(22, 7);
        meter.attributes[0x0014]!.value = Uint8List.fromList(exact);
        expect(await client.read(0x0014), exact);
        expect(
          channel.sent.where((p) => p[0] == AttOpcode.readBlobRequest),
          hasLength(1),
        );
      },
    );

    test('write with response waits for the ack', () async {
      await client.write(FakeAttPeripheral.ldm330CommandHandle, [1, 2, 3]);
      expect(meter.writes.single.value, [1, 2, 3]);
      expect(meter.writes.single.withResponse, isTrue);
    });

    test('write without response is fire and forget', () async {
      client.writeWithoutResponse(FakeAttPeripheral.ldm330CommandHandle, [
        0x03,
        0x0d,
        0x0a,
        0x03,
        0x0d,
        0x0a,
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(meter.writes.single.withResponse, isFalse);
      expect(meter.writes.single.value, [0x03, 0x0d, 0x0a, 0x03, 0x0d, 0x0a]);
    });

    test('a write without response that cannot fit is refused, not cut', () {
      expect(
        () => client.writeWithoutResponse(
          FakeAttPeripheral.ldm330CommandHandle,
          List.filled(21, 0),
        ),
        throwsArgumentError,
      );
      expect(channel.sent, isEmpty);
      // MTU-3 exactly still fits.
      client.writeWithoutResponse(
        FakeAttPeripheral.ldm330CommandHandle,
        List.filled(20, 1),
      );
      expect(meter.writes.single.value, List.filled(20, 1));
      expect(meter.violations, isEmpty);
    });

    test('an ATT error becomes AttErrorException with the code', () async {
      await expectLater(
        client.read(0x0052), // notify-only: read not permitted
        throwsA(
          isA<AttErrorException>()
              .having((e) => e.errorCode, 'code', 0x02)
              .having((e) => e.needsPairing, 'needsPairing', isFalse),
        ),
      );
    });

    test('insufficient authentication is flagged as needing pairing', () async {
      meter.attributes[0x0012]!.accessError =
          AttError.insufficientAuthentication;
      await expectLater(
        client.read(0x0012),
        throwsA(
          isA<AttErrorException>().having(
            (e) => e.needsPairing,
            'needsPairing',
            isTrue,
          ),
        ),
      );
    });

    test('requests are strictly one at a time, in order', () async {
      final a = client.read(0x0012);
      final b = client.read(0x0014);
      final c = client.read(0x0016);
      expect(String.fromCharCodes(await a), 'Precaster');
      expect(String.fromCharCodes(await b), 'BT A8105');
      expect(String.fromCharCodes(await c), '00001');
      final reads = meter.requests
          .where((r) => r[0] == AttOpcode.readRequest)
          .map((r) => r[1]);
      expect(reads, [0x12, 0x14, 0x16]);
    });
  });

  group('notifications', () {
    test(
      'subscribing writes the CCCD and the stream carries the frames',
      () async {
        await client.discoverServices();
        final seen = <String>[];
        final sub = client.notifications
            .where((e) => e.handle == FakeAttPeripheral.ldm330DataHandle)
            .listen((e) => seen.add(String.fromCharCodes(e.value)));
        await client.writeCccd(FakeAttPeripheral.ldm330DataCccd, 0x0001);
        expect(meter.cccd(FakeAttPeripheral.ldm330DataCccd), 0x0001);
        meter.notify(
          FakeAttPeripheral.ldm330DataHandle,
          'Ztest01\x00\x00\x00'.codeUnits,
        );
        meter.notify(
          FakeAttPeripheral.ldm330DataHandle,
          'A02.509b\x00\x00'.codeUnits,
        );
        await Future<void>.delayed(Duration.zero);
        expect(seen, ['Ztest01\x00\x00\x00', 'A02.509b\x00\x00']);
        await sub.cancel();
      },
    );

    test('an indication is confirmed without anyone asking', () async {
      await client.writeCccd(0x0033, 0x0002); // Tx Power: indications on
      meter.notify(0x0032, [1], indicate: true);
      await Future<void>.delayed(Duration.zero);
      expect(meter.confirmations, 1);
    });

    test('a notification arriving mid-request does not disturb it', () async {
      await client.writeCccd(FakeAttPeripheral.ldm330DataCccd, 0x0001);
      final seen = <AttValueEvent>[];
      final sub = client.notifications.listen(seen.add);
      final pending = client.read(0x0012);
      meter.notify(FakeAttPeripheral.ldm330DataHandle, [1]);
      expect(String.fromCharCodes(await pending), 'Precaster');
      expect(seen.single.value, [1]);
      await sub.cancel();
    });

    test(
      'nothing arrives from a characteristic nobody subscribed to',
      () async {
        final seen = <AttValueEvent>[];
        final sub = client.notifications.listen(seen.add);
        meter.notify(FakeAttPeripheral.ldm330DataHandle, [1]);
        await Future<void>.delayed(Duration.zero);
        expect(seen, isEmpty, reason: 'its CCCD is 0 on a new link');
        await sub.cancel();
      },
    );
  });

  group('long writes', () {
    List<Uint8List> sentOf(int opcode) =>
        channel.sent.where((p) => p[0] == opcode).toList();

    test('a value that fits one PDU is one Write Request', () async {
      await client.write(0x0055, List.filled(20, 3));
      expect(sentOf(AttOpcode.writeRequest), hasLength(1));
      expect(sentOf(AttOpcode.prepareWriteRequest), isEmpty);
    });

    test('a longer one goes as MTU-5 pieces, then one execute', () async {
      final value = List<int>.generate(50, (i) => i + 1);
      await client.write(0x0055, value);
      final prepares = sentOf(AttOpcode.prepareWriteRequest);
      // 18 + 18 + 14 at MTU 23; offsets follow the bytes.
      expect(prepares.map((p) => p[3] | (p[4] << 8)), [0, 18, 36]);
      expect(prepares.map((p) => p.length - 5), [18, 18, 14]);
      expect(sentOf(AttOpcode.executeWriteRequest).single, [0x18, 0x01]);
      expect(sentOf(AttOpcode.writeRequest), isEmpty);
      expect(meter.attributes[0x0055]!.value, value);
      expect(meter.writes.single.value, value);
      expect(meter.violations, isEmpty);
    });

    test('pieces grow with the MTU', () async {
      meter.serverRxMtu = 100;
      await client.exchangeMtu();
      final value = List<int>.generate(200, (i) => i);
      await client.write(0x0055, value);
      expect(sentOf(AttOpcode.prepareWriteRequest).map((p) => p.length - 5), [
        95,
        95,
        10,
      ]);
      expect(meter.attributes[0x0055]!.value, value);
      expect(meter.violations, isEmpty);
    });

    test('an echo that does not match cancels the queue and fails', () async {
      meter.corruptsPrepareWriteEcho = true;
      meter.attributes[0x0055]!.value = Uint8List.fromList([9]);
      await expectLater(
        client.write(0x0055, List.filled(40, 5)),
        throwsA(isA<AttFormatException>()),
      );
      // One piece, then the cancel — never a commit.
      expect(sentOf(AttOpcode.prepareWriteRequest), hasLength(1));
      expect(sentOf(AttOpcode.executeWriteRequest).single, [0x18, 0x00]);
      expect(meter.attributes[0x0055]!.value, [9]);
      expect(meter.writes, isEmpty);
    });

    test('a peer without queued writes refuses it with its error', () async {
      meter.supportsQueuedWrites = false;
      await expectLater(
        client.write(0x0055, List.filled(40, 5)),
        throwsA(
          isA<AttErrorException>()
              .having((e) => e.requestOpcode, 'op', 0x16)
              .having((e) => e.errorCode, 'code', 0x06),
        ),
      );
      // Nothing was queued, so there is nothing to cancel.
      expect(sentOf(AttOpcode.executeWriteRequest), isEmpty);
    });

    test(
      'exactly the 512-byte attribute maximum goes as a long write',
      () async {
        final value = List<int>.generate(
          attMaxAttributeLength,
          (i) => i & 0xff,
        );
        await client.write(0x0055, value);
        expect(meter.attributes[0x0055]!.value, value);
        expect(meter.violations, isEmpty);
      },
    );

    // Fails on the old code: write() sent 513+ bytes as Prepare Writes and
    // left refusing them to the peer — and past 0xFFFF bytes the 16-bit
    // offset on the wire wrapped.
    test('a value over the 512-byte attribute maximum is refused before '
        'anything is sent', () async {
      await expectLater(
        client.write(0x0055, List.filled(attMaxAttributeLength + 1, 5)),
        throwsA(isA<ArgumentError>()),
      );
      expect(channel.sent, isEmpty);
      expect(meter.writes, isEmpty);
    });

    // Fails on the old code: the piece size was taken once, so after the
    // peer's own exchange lowered the MTU from 100 to 40 the remaining
    // Prepare Writes still went out 100 bytes long.
    test("pieces shrink when the peer's own exchange lowers the MTU "
        'mid-write', () async {
      await client.close();
      meter.serverRxMtu = 100;
      var lowered = false;
      late final _SendHook ch;
      ch = _SendHook(meter, (pdu) {
        if (lowered || pdu[0] != AttOpcode.prepareWriteRequest) return;
        lowered = true;
        unawaited(meter.sendRequestToClient(AttEncode.exchangeMtu(40)));
      });
      final c = AttClient(ch);
      expect(await c.exchangeMtu(), 100);
      final value = List<int>.generate(200, (i) => i);

      await c.write(0x0055, value);

      final prepares = ch.sent
          .where((p) => p[0] == AttOpcode.prepareWriteRequest)
          .toList();
      expect(c.mtu, 40);
      expect(prepares.first.length, 100);
      expect(prepares.skip(1).every((p) => p.length <= 40), isTrue);
      expect(prepares.map((p) => p[3] | (p[4] << 8)).toList(), [
        0,
        95,
        130,
        165,
      ]);
      expect(meter.attributes[0x0055]!.value, value);
      expect(meter.violations, isEmpty);
      await c.close();
    });
  });

  group("the peer's requests", () {
    test('its MTU exchange is answered, and moves the MTU', () async {
      final changes = <int>[];
      final sub = client.mtuChanges.listen(changes.add);
      final answer = await meter.sendRequestToClient(
        AttEncode.exchangeMtu(247),
      );
      expect(answer, AttEncode.exchangeMtuResponse(attMaxMtu));
      expect(client.mtu, 247);
      expect(meter.mtu, 247);
      await Future<void>.delayed(Duration.zero);
      expect(changes, [247]);
      // The larger MTU is usable at once: 300 bytes in 246 + 54.
      meter.attributes[0x0014]!.value = Uint8List(300);
      expect(await client.read(0x0014), hasLength(300));
      expect(channel.sent.where((p) => p[0] == AttOpcode.readBlobRequest), [
        isNotNull,
      ]);
      await sub.cancel();
      expect(meter.violations, isEmpty);
    });

    test('...settling on the smaller side, never below 23', () async {
      await client.close();
      final ch = FakeAttChannel(meter);
      final c = AttClient(ch, localRxMtu: 100);
      expect(
        await meter.sendRequestToClient(AttEncode.exchangeMtu(247)),
        AttEncode.exchangeMtuResponse(100),
      );
      expect(c.mtu, 100);
      await c.close();

      final ch2 = FakeAttChannel(meter);
      final c2 = AttClient(ch2);
      await meter.sendRequestToClient([AttOpcode.exchangeMtuRequest, 10, 0]);
      expect(c2.mtu, 23);
      await c2.close();
    });

    test('every other request gets the error an empty server gives', () async {
      Uint8List err(int op, int handle, int code) =>
          AttEncode.errorResponse(op, handle, code);
      final cases = <List<int>, Uint8List>{
        // Discovery: nothing to find in range.
        AttEncode.findInformation(0x0001, 0xffff): err(0x04, 1, 0x0a),
        [0x06, 0x05, 0x00, 0xff, 0xff, 0x00, 0x28, 0x0f, 0x18]: err(
          0x06,
          5,
          0x0a,
        ),
        AttEncode.readByType(0x0001, 0xffff, 0x2b3a): err(0x08, 1, 0x0a),
        AttEncode.readByGroupType(0x0001, 0xffff, 0x2800): err(0x10, 1, 0x0a),
        // A range that starts at 0 or runs backwards is malformed.
        AttEncode.readByType(0x0000, 0xffff, 0x2803): err(0x08, 0, 0x01),
        AttEncode.readByType(0x0009, 0x0003, 0x2803): err(0x08, 9, 0x01),
        // Access to a named handle: there is none.
        AttEncode.read(0x0003): err(0x0a, 3, 0x01),
        AttEncode.readBlob(0x0003, 22): err(0x0c, 3, 0x01),
        [0x0e, 0x03, 0x00, 0x05, 0x00]: err(0x0e, 3, 0x01),
        [0x20, 0x03, 0x00, 0x05, 0x00]: err(0x20, 3, 0x01),
        AttEncode.write(0x0007, [1]): err(0x12, 7, 0x01),
        AttEncode.prepareWrite(0x0007, 0, [1]): err(0x16, 7, 0x01),
        // Nothing can be queued, so executing is trivially fine.
        AttEncode.executeWrite(commit: true): Uint8List.fromList([0x19]),
        // An opcode this side does not know: "not supported", as BlueZ.
        [0x30, 1, 2]: err(0x30, 0, 0x06),
      };
      for (final MapEntry(key: request, value: expected) in cases.entries) {
        expect(
          await meter.sendRequestToClient(request),
          expected,
          reason: 'peer request ${request.map((b) => b.toRadixString(16))}',
        );
      }
      expect(meter.clientResponses, hasLength(cases.length));
      expect(meter.violations, isEmpty);
      expect(log.where((l) => l.startsWith('answered peer request')), [
        for (final _ in cases.keys) isNotNull,
      ]);
    });

    test('commands and confirmations are not answered', () async {
      channel.deliver(Uint8List.fromList([0x52, 0x03, 0x00, 1]));
      channel.deliver(
        Uint8List.fromList([0xd2, 0x03, 0x00, 1, ...List.filled(12, 0)]),
      );
      channel.deliver(Uint8List.fromList([AttOpcode.handleValueConfirmation]));
      channel.deliver(Uint8List.fromList([0x23, 0x03, 0x00, 1, 0, 9]));
      await Future<void>.delayed(Duration.zero);
      expect(channel.sent, isEmpty);
      expect(log.where((l) => l.startsWith('ignoring peer PDU')), hasLength(4));
    });

    test('answered at once, even with our own request in flight', () async {
      meter.silentOpcodes.add(AttOpcode.readRequest);
      final pending = client.read(0x0012);
      await Future<void>.delayed(Duration.zero);
      final answer = await meter
          .sendRequestToClient(AttEncode.readByGroupType(1, 0xffff, 0x2800))
          .timeout(const Duration(seconds: 1));
      expect(answer, AttEncode.errorResponse(0x10, 1, 0x0a));
      // Our transaction is untouched by the other direction's.
      channel.deliver(
        Uint8List.fromList([AttOpcode.readResponse, ...'Precaster'.codeUnits]),
      );
      expect(String.fromCharCodes(await pending), 'Precaster');
      expect(meter.violations, isEmpty);
    });
  });

  group('one transaction at a time', () {
    int readRequests() =>
        meter.requests.where((r) => AttDecode.isRequest(r[0])).length;

    test('never pipelines across a whole LDM330 walk at MTU 23', () async {
      meter.responseLatency = const Duration(milliseconds: 1);
      final services = await client.discoverServices();
      expect(services, hasLength(9));
      expect(meter.violations, isEmpty);
      // 4 group-type pages (3 services each at MTU 23, then Not Found), 12
      // characteristic pages across the nine services (Device Information's
      // six declarations take two; Tx Power and Battery each end on a Not
      // Found probe of their CCCD handle), and the 5 one-handle descriptor
      // gaps: every one a full round trip.
      expect(readRequests(), 21);
    });

    test('...nor at MTU 247, in fewer round trips', () async {
      meter
        ..serverRxMtu = 247
        ..responseLatency = const Duration(milliseconds: 1);
      expect(await client.exchangeMtu(), 247);
      final services = await client.discoverServices();
      expect(services, hasLength(9));
      expect(meter.violations, isEmpty);
      // The exchange, 2 group-type pages, 11 characteristic pages (Device
      // Information's six declarations now fit one), the 5 descriptor gaps.
      expect(readRequests(), 19);
    });

    test('many callers at once are queued, not interleaved', () async {
      meter.responseLatency = const Duration(milliseconds: 2);
      final a = client.read(0x0012);
      final b = client.read(0x0014);
      final w = client.write(0x0055, [1]);
      final c = client.read(0x0016);
      final cccd = client.writeCccd(FakeAttPeripheral.ldm330DataCccd, 1);
      expect(String.fromCharCodes(await a), 'Precaster');
      expect(String.fromCharCodes(await b), 'BT A8105');
      await w;
      expect(String.fromCharCodes(await c), '00001');
      await cccd;
      expect(meter.cccd(FakeAttPeripheral.ldm330DataCccd), 1);
      expect(meter.violations, isEmpty);
    });
  });

  group('a generic peripheral', () {
    String vendor(int n) =>
        '6e40${n.toRadixString(16).padLeft(4, '0')}-b5a3-f393-e0a9-e50e24dcca9e';

    test('a 128-bit table with many services, walked at MTU 23', () async {
      await client.close();
      // Five vendor services of three 128-bit characteristics each: the
      // first notifies (CCCD plus a 128-bit vendor descriptor, so Find
      // Information has to change format mid-gap), the other two are plain.
      final peer = FakeAttPeripheral()
        ..service(0x0001, 0x0005, 0x1800)
        ..characteristic(0x0002, 0x0003, 0x02, 0x2a00, 'Generic'.codeUnits)
        ..characteristic(0x0004, 0x0005, 0x02, 0x2a01, const [0, 0]);
      var h = 0x0010;
      for (var s = 0; s < 5; s++) {
        final start = h;
        final end = start + 9;
        peer.service(start, end, 0, uuid128: vendor(0x100 * (s + 1)));
        peer
          ..characteristic(start + 1, start + 2, 0x12, 0, const [
            1,
          ], uuid128: vendor(0x100 * (s + 1) + 1))
          ..descriptor(start + 3, 0x2902)
          ..descriptor(start + 4, 0, uuid128: vendor(0xff00 + s))
          ..characteristic(start + 5, start + 6, 0x0a, 0, const [
            2,
          ], uuid128: vendor(0x100 * (s + 1) + 2))
          ..characteristic(
            start + 7,
            start + 8,
            0x04,
            0,
            const [],
            uuid128: vendor(0x100 * (s + 1) + 3),
          );
        h = end + 7; // a gap between services, as real tables have
      }
      final ch = FakeAttChannel(peer);
      final c = AttClient(ch);
      final services = await c.discoverServices();
      expect(services.map((s) => s.uuid), [
        uuid16ToString(0x1800),
        for (var s = 0; s < 5; s++) vendor(0x100 * (s + 1)),
      ]);
      for (var s = 0; s < 5; s++) {
        final svc = services[s + 1];
        expect(svc.endHandle, svc.startHandle + 9);
        expect(svc.characteristics.map((c) => c.uuid), [
          for (var k = 1; k <= 3; k++) vendor(0x100 * (s + 1) + k),
        ]);
        final notify = svc.characteristics[0];
        expect(notify.valueHandle, svc.startHandle + 2);
        expect(notify.canNotify, isTrue);
        expect(notify.cccdHandle, svc.startHandle + 3);
        expect(notify.descriptors.map((d) => d.uuid), [
          uuid16ToString(0x2902),
          vendor(0xff00 + s),
        ]);
        expect(svc.characteristics[1].canWrite, isTrue);
        expect(svc.characteristics[1].descriptors, isEmpty);
        expect(svc.characteristics[2].canWriteWithoutResponse, isTrue);
        // The last characteristic's gap runs to the service end, and it is
        // empty: asked, answered Not Found, nothing invented.
        expect(svc.characteristics[2].descriptors, isEmpty);
      }
      expect(peer.violations, isEmpty);
      // A 128-bit service or declaration fills a whole MTU-23 page, so
      // every one is its own round trip — and still one at a time.
      final groupPages = peer.requests
          .where((r) => r[0] == AttOpcode.readByGroupTypeRequest)
          .length;
      expect(groupPages, 1 + 5 + 1);
      await c.close();
    });
  });

  group('each link starts from scratch', () {
    test('a reconnect is back at MTU 23 with every CCCD off', () async {
      meter.serverRxMtu = 247;
      expect(await client.exchangeMtu(), 247);
      await client.writeCccd(FakeAttPeripheral.ldm330DataCccd, 1);
      expect(meter.cccd(FakeAttPeripheral.ldm330DataCccd), 1);
      await client.close();

      final again = AttClient(FakeAttChannel(meter));
      expect(again.mtu, 23);
      expect(meter.mtu, 23);
      expect(meter.cccd(FakeAttPeripheral.ldm330DataCccd), 0);
      // A long read proves the link really is at 23 again: 22-byte pieces.
      meter.attributes[0x0014]!.value = Uint8List(60);
      expect(await again.read(0x0014), hasLength(60));
      expect(meter.violations, isEmpty);
      await again.close();
    });

    test('...except what a bond keeps', () async {
      meter.bonded = true;
      await client.writeCccd(FakeAttPeripheral.ldm330DataCccd, 1);
      await client.close();
      final again = AttClient(FakeAttChannel(meter));
      expect(meter.cccd(FakeAttPeripheral.ldm330DataCccd), 1);
      await again.close();
    });
  });

  group('the bearer', () {
    test('a silent request times out and closes the bearer, by spec', () async {
      await client.close();
      final ch = FakeAttChannel(meter);
      final c = AttClient(
        ch,
        requestTimeout: const Duration(milliseconds: 30),
        log: log.add,
      );
      meter.silentOpcodes.add(AttOpcode.readRequest);
      final timedOut = expectLater(
        c.read(0x0012),
        throwsA(isA<AttTimeoutException>()),
      );
      final queued = expectLater(
        c.write(0x0055, [1]),
        throwsA(isA<AttLinkClosedException>()),
      );
      await timedOut;
      await queued;
      expect(ch.isOpen, isFalse);
      expect(log.any((l) => l.contains('unanswered')), isTrue);
    });

    test('the peer hanging up fails what was in flight', () async {
      meter.silentOpcodes.add(AttOpcode.readRequest);
      final pending = client.read(0x0012);
      meter.dropLink(errno: 104);
      await expectLater(pending, throwsA(isA<AttLinkClosedException>()));
      expect(client.isOpen, isFalse);
      expect(channel.closeErrno, 104);
      await expectLater(
        client.read(0x0012),
        throwsA(isA<AttLinkClosedException>()),
      );
    });

    test(
      'a stray response is ignored rather than failing the request',
      () async {
        // bluez/bluez#2486: a duplicate Exchange MTU Response landing on an
        // unrelated in-flight request took bluetoothd's discovery down.
        meter.silentOpcodes.add(AttOpcode.readRequest);
        final pending = client.read(0x0012);
        channel.deliver(
          Uint8List.fromList([AttOpcode.exchangeMtuResponse, 23, 0]),
        );
        channel.deliver(
          Uint8List.fromList([AttOpcode.errorResponse, 0x08, 1, 0, 0x0a]),
        );
        await Future<void>.delayed(Duration.zero);
        // Still waiting on the real answer; hand it over now.
        channel.deliver(
          Uint8List.fromList([
            AttOpcode.readResponse,
            ...'Precaster'.codeUnits,
          ]),
        );
        expect(String.fromCharCodes(await pending), 'Precaster');
        expect(
          log.where((l) => l.contains('ignoring unexpected')),
          hasLength(2),
        );
      },
    );

    test('close fails anything still queued and is idempotent', () async {
      meter.silentOpcodes.add(AttOpcode.readRequest);
      final failing = expectLater(
        client.read(0x0012),
        throwsA(isA<AttLinkClosedException>()),
      );
      await client.close();
      await client.close();
      await failing;
    });
  });
}

/// A [FakeAttChannel] that tells [onSend] about every PDU the client sends,
/// after the peer has taken it.
class _SendHook extends FakeAttChannel {
  final void Function(Uint8List pdu) onSend;
  _SendHook(super.peripheral, this.onSend);

  @override
  void send(Uint8List pdu) {
    super.send(pdu);
    onSend(pdu);
  }
}
