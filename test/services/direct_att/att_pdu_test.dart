// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);

void main() {
  group('uuids', () {
    test('a 16-bit UUID folds into the base UUID, lowercase', () {
      expect(uuid16ToString(0xf150), '0000f150-0000-1000-8000-00805f9b34fb');
      expect(uuidFromAttBytes(_b([0x50, 0xf1])), uuid16ToString(0xf150));
    });

    test('a 128-bit UUID is read little-endian off the wire', () {
      // 6e400001-b5a3-f393-e0a9-e50e24dcca9e as ATT sends it.
      final wire = _b([
        0x9e,
        0xca,
        0xdc,
        0x24,
        0x0e,
        0xe5,
        0xa9,
        0xe0,
        0x93,
        0xf3,
        0xa3,
        0xb5,
        0x01,
        0x00,
        0x40,
        0x6e,
      ]);
      expect(uuidFromAttBytes(wire), '6e400001-b5a3-f393-e0a9-e50e24dcca9e');
    });

    test('any other length is malformed', () {
      expect(() => uuidFromAttBytes(_b([1, 2, 3])), throwsFormatException);
    });
  });

  group('encode', () {
    test('requests carry little-endian handles and the right opcode', () {
      expect(AttEncode.exchangeMtu(517), _b([0x02, 0x05, 0x02]));
      expect(
        AttEncode.readByGroupType(0x0001, 0xffff, 0x2800),
        _b([0x10, 0x01, 0x00, 0xff, 0xff, 0x00, 0x28]),
      );
      expect(
        AttEncode.readByType(0x0050, 0x0055, 0x2803),
        _b([0x08, 0x50, 0x00, 0x55, 0x00, 0x03, 0x28]),
      );
      expect(
        AttEncode.findInformation(0x33, 0x33),
        _b([0x04, 0x33, 0, 0x33, 0]),
      );
      expect(AttEncode.read(0x0012), _b([0x0a, 0x12, 0x00]));
      expect(AttEncode.readBlob(0x0012, 22), _b([0x0c, 0x12, 0x00, 22, 0]));
      expect(AttEncode.write(0x53, [1, 0]), _b([0x12, 0x53, 0x00, 1, 0]));
      expect(
        AttEncode.writeCommand(0x55, [0x03, 0x0d, 0x0a]),
        _b([0x52, 0x55, 0x00, 0x03, 0x0d, 0x0a]),
      );
      expect(AttEncode.handleValueConfirmation(), _b([0x1e]));
    });

    test('a long write: prepare pieces at an offset, then execute', () {
      expect(
        AttEncode.prepareWrite(0x0055, 18, [0xaa, 0xbb]),
        _b([0x16, 0x55, 0x00, 18, 0x00, 0xaa, 0xbb]),
      );
      expect(
        AttEncode.prepareWrite(0x0102, 0x0304, const []),
        _b([0x16, 0x02, 0x01, 0x04, 0x03]),
      );
      expect(AttEncode.executeWrite(commit: true), _b([0x18, 0x01]));
      expect(AttEncode.executeWrite(commit: false), _b([0x18, 0x00]));
    });

    test('the answers the client gives the peer', () {
      expect(AttEncode.exchangeMtuResponse(517), _b([0x03, 0x05, 0x02]));
      expect(
        AttEncode.errorResponse(0x08, 0x0102, AttError.attributeNotFound),
        _b([0x01, 0x08, 0x02, 0x01, 0x0a]),
      );
    });
  });

  group('classify', () {
    test('requests are exactly the twelve the peer must be answered for', () {
      final requests = [
        for (var op = 0; op < 0x100; op++)
          if (AttDecode.isRequest(op)) op,
      ];
      expect(requests, [
        0x02,
        0x04,
        0x06,
        0x08,
        0x0a,
        0x0c,
        0x0e,
        0x10,
        0x12,
        0x16,
        0x18,
        0x20,
      ]);
    });

    test('commands carry the command flag; nothing else does', () {
      expect(AttDecode.isCommand(AttOpcode.writeCommand), isTrue);
      expect(AttDecode.isCommand(AttOpcode.signedWriteCommand), isTrue);
      for (final op in [0x01, 0x12, 0x13, 0x1b, 0x1d, 0x1e, 0x20, 0x23]) {
        expect(AttDecode.isCommand(op), isFalse, reason: '0x$op');
      }
    });

    test('error codes read as their spec names, or their range', () {
      expect(
        AttError.describe(AttError.insufficientAuthentication),
        'insufficient authentication',
      );
      expect(
        AttError.describe(AttError.insufficientEncryption),
        'insufficient encryption',
      );
      expect(AttError.describe(0x0c), 'encryption key size insufficient');
      expect(AttError.describe(0x80), 'application error 0x80');
      expect(AttError.describe(0x9f), 'application error 0x9f');
      expect(AttError.describe(0xfd), contains('improperly configured'));
      expect(AttError.describe(0xe0), 'profile error 0xe0');
      expect(AttError.describe(0x42), 'reserved error 0x42');
    });
  });

  group('decode', () {
    test('error response', () {
      final e = AttDecode.error(_b([0x01, 0x08, 0x01, 0x00, 0x0a]));
      expect(e.requestOpcode, 0x08);
      expect(e.handle, 1);
      expect(e.errorCode, AttError.attributeNotFound);
    });

    test('responses name the request they answer; events name none', () {
      expect(AttDecode.requestOpcodeOf(_b([0x11, 6])), 0x10);
      expect(AttDecode.requestOpcodeOf(_b([0x01, 0x08, 0, 0, 0x0a])), 0x08);
      expect(AttDecode.requestOpcodeOf(_b([0x1b, 0x52, 0, 1])), isNull);
      // The responses added with long writes and the rarer reads.
      expect(AttDecode.requestOpcodeOf(_b([0x07, 1, 0, 2, 0])), 0x06);
      expect(AttDecode.requestOpcodeOf(_b([0x0f, 1])), 0x0e);
      expect(AttDecode.requestOpcodeOf(_b([0x17, 1, 0, 0, 0])), 0x16);
      expect(AttDecode.requestOpcodeOf(_b([0x19])), 0x18);
      expect(AttDecode.requestOpcodeOf(_b([0x21, 1])), 0x20);
      // Requests, commands and the confirmation answer nothing.
      expect(AttDecode.requestOpcodeOf(_b([0x0a, 1, 0])), isNull);
      expect(AttDecode.requestOpcodeOf(_b([0x52, 1, 0, 1])), isNull);
      expect(AttDecode.requestOpcodeOf(_b([0x1e])), isNull);
    });

    test('prepare write response: the echo, field by field', () {
      final echo = AttDecode.prepareWrite(
        _b([0x17, 0x55, 0x00, 0x12, 0x00, 1, 2, 3]),
      );
      expect(echo.handle, 0x0055);
      expect(echo.offset, 18);
      expect(echo.value, [1, 2, 3]);
      expect(
        () => AttDecode.prepareWrite(_b([0x17, 0x55, 0x00, 0x12])),
        throwsA(isA<AttFormatException>()),
      );
      AttDecode.executeWriteResponse(_b([0x19]));
      expect(
        () => AttDecode.executeWriteResponse(_b([0x13])),
        throwsA(isA<AttFormatException>()),
      );
    });

    test('read by group type: the capture frame 1060, two services', () {
      final rsp = _b([
        0x11,
        0x06,
        0x01,
        0x00,
        0x07,
        0x00,
        0x00,
        0x18,
        0x10,
        0x00,
        0x1c,
        0x00,
        0x0a,
        0x18,
      ]);
      final groups = AttDecode.readByGroupType(rsp);
      expect(groups, hasLength(2));
      expect(groups[0].start, 0x0001);
      expect(groups[0].end, 0x0007);
      expect(groups[0].uuid, uuid16ToString(0x1800));
      expect(groups[1].start, 0x0010);
      expect(groups[1].uuid, uuid16ToString(0x180a));
    });

    test('read by type: characteristic declarations of the f150 service', () {
      final rsp = _b([
        0x09,
        0x07,
        0x51,
        0x00,
        0x10,
        0x52,
        0x00,
        0x54,
        0xf1,
        0x54,
        0x00,
        0x0c,
        0x55,
        0x00,
        0x51,
        0xf1,
      ]);
      final entries = AttDecode.readByType(rsp);
      expect(entries.map((e) => e.handle), [0x51, 0x54]);
      final data = AttDecode.characteristicDecl(entries[0].value);
      expect(data.properties, GattProperty.notify);
      expect(data.valueHandle, 0x52);
      expect(data.uuid, uuid16ToString(0xf154));
      final cmd = AttDecode.characteristicDecl(entries[1].value);
      expect(
        cmd.properties,
        GattProperty.write | GattProperty.writeWithoutResponse,
      );
      expect(cmd.valueHandle, 0x55);
    });

    test('find information: the CCCD at 0x0053', () {
      final entries = AttDecode.findInformation(
        _b([0x05, 0x01, 0x53, 0, 0x02, 0x29]),
      );
      expect(entries.single.handle, 0x53);
      expect(entries.single.uuid, uuid16ToString(0x2902));
    });

    test('a measurement notification: "A02.509b" from the capture', () {
      final pdu = _b([
        0x1b,
        0x52,
        0x00,
        0x41,
        0x30,
        0x32,
        0x2e,
        0x35,
        0x30,
        0x39,
        0x62,
        0x00,
        0x00,
      ]);
      final event = AttDecode.valueEvent(pdu)!;
      expect(event.handle, 0x52);
      expect(event.isIndication, isFalse);
      expect(String.fromCharCodes(event.value.sublist(0, 8)), 'A02.509b');
    });

    test('an indication is flagged so the client confirms it', () {
      expect(AttDecode.valueEvent(_b([0x1d, 1, 0, 9]))!.isIndication, isTrue);
      expect(AttDecode.valueEvent(_b([0x0b, 9])), isNull);
    });

    test('a wrong opcode or a short PDU is malformed, not misread', () {
      expect(
        () => AttDecode.exchangeMtu(_b([0x0b, 1, 2])),
        throwsA(isA<AttFormatException>()),
      );
      expect(
        () => AttDecode.error(_b([0x01, 0x08])),
        throwsA(isA<AttFormatException>()),
      );
      expect(
        () => AttDecode.readByGroupType(_b([0x11, 5, 1, 2, 3, 4, 5])),
        throwsA(isA<AttFormatException>()),
      );
    });
  });
}
