// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// ATT protocol data units: the byte layouts a GATT client sends and receives
// on the ATT bearer (Bluetooth Core, Vol 3 Part F). Pure functions over
// bytes, no I/O, so the whole vocabulary is unit-testable on any machine.
//
// Only the subset a client needs to drive a peripheral is here: MTU
// exchange, the three discovery requests, read, write (both flavours, plus
// the prepare/execute pair behind a long write), the CCCD write behind
// subscriptions, the notification/indication PDUs the server pushes — and
// the handful of answers the client's own minimal ATT server gives when the
// PEER sends a request (see att_client.dart). Nothing here depends on
// Flutter, so a plain `dart run` tool can use it against a device.

import 'dart:typed_data';

/// ATT opcodes (Vol 3 Part F, 3.4.8).
abstract final class AttOpcode {
  static const int errorResponse = 0x01;
  static const int exchangeMtuRequest = 0x02;
  static const int exchangeMtuResponse = 0x03;
  static const int findInformationRequest = 0x04;
  static const int findInformationResponse = 0x05;
  static const int findByTypeValueRequest = 0x06;
  static const int findByTypeValueResponse = 0x07;
  static const int readByTypeRequest = 0x08;
  static const int readByTypeResponse = 0x09;
  static const int readRequest = 0x0A;
  static const int readResponse = 0x0B;
  static const int readBlobRequest = 0x0C;
  static const int readBlobResponse = 0x0D;
  static const int readMultipleRequest = 0x0E;
  static const int readMultipleResponse = 0x0F;
  static const int readByGroupTypeRequest = 0x10;
  static const int readByGroupTypeResponse = 0x11;
  static const int writeRequest = 0x12;
  static const int writeResponse = 0x13;
  static const int prepareWriteRequest = 0x16;
  static const int prepareWriteResponse = 0x17;
  static const int executeWriteRequest = 0x18;
  static const int executeWriteResponse = 0x19;
  static const int handleValueNotification = 0x1B;
  static const int handleValueIndication = 0x1D;
  static const int handleValueConfirmation = 0x1E;
  static const int readMultipleVariableRequest = 0x20;
  static const int readMultipleVariableResponse = 0x21;

  /// Only ever sent by a server the client enabled it on (through Client
  /// Supported Features, which this client never writes), so it is ignored
  /// rather than parsed — but it must not be mistaken for a request.
  static const int multipleHandleValueNotification = 0x23;
  static const int writeCommand = 0x52;
  static const int signedWriteCommand = 0xD2;
}

/// ATT error codes (Vol 3 Part F, 3.4.1.1) this client interprets or sends.
abstract final class AttError {
  static const int invalidHandle = 0x01;
  static const int readNotPermitted = 0x02;
  static const int writeNotPermitted = 0x03;
  static const int invalidPdu = 0x04;
  static const int insufficientAuthentication = 0x05;
  static const int requestNotSupported = 0x06;
  static const int invalidOffset = 0x07;
  static const int insufficientAuthorization = 0x08;
  static const int prepareQueueFull = 0x09;
  static const int attributeNotFound = 0x0A;
  static const int attributeNotLong = 0x0B;
  static const int encryptionKeySizeInsufficient = 0x0C;
  static const int invalidAttributeValueLength = 0x0D;
  static const int unlikelyError = 0x0E;
  static const int insufficientEncryption = 0x0F;
  static const int unsupportedGroupType = 0x10;

  static const Map<int, String> _names = {
    invalidHandle: 'invalid handle',
    readNotPermitted: 'read not permitted',
    writeNotPermitted: 'write not permitted',
    invalidPdu: 'invalid PDU',
    insufficientAuthentication: 'insufficient authentication',
    requestNotSupported: 'request not supported',
    invalidOffset: 'invalid offset',
    insufficientAuthorization: 'insufficient authorization',
    prepareQueueFull: 'prepare queue full',
    attributeNotFound: 'attribute not found',
    attributeNotLong: 'attribute not long',
    encryptionKeySizeInsufficient: 'encryption key size insufficient',
    invalidAttributeValueLength: 'invalid attribute value length',
    unlikelyError: 'unlikely error',
    insufficientEncryption: 'insufficient encryption',
    unsupportedGroupType: 'unsupported group type',
    0x11: 'insufficient resources',
    0x12: 'database out of sync',
    0x13: 'value not allowed',
    // The Common Profile and Service Error Codes (CSS Part B, 1.2).
    0xFC: 'write request rejected',
    0xFD:
        'client characteristic configuration descriptor improperly '
        'configured',
    0xFE: 'procedure already in progress',
    0xFF: 'out of range',
  };

  /// A human-readable name for [code], for logs and error strings: the
  /// spec's name where it has one, else the range the code falls in —
  /// 0x80-0x9F belong to the application (a vendor's own meaning), 0xE0-0xFF
  /// to profiles and services.
  static String describe(int code) {
    final name = _names[code];
    if (name != null) return name;
    final hex = '0x${code.toRadixString(16).padLeft(2, '0')}';
    if (code >= 0x80 && code <= 0x9F) return 'application error $hex';
    if (code >= 0xE0) return 'profile error $hex';
    return 'reserved error $hex';
  }
}

/// GATT attribute-type UUIDs used during discovery (Vol 3 Part G, 3.x).
abstract final class GattType {
  static const int primaryService = 0x2800;
  static const int secondaryService = 0x2801;
  static const int include = 0x2802;
  static const int characteristic = 0x2803;
  static const int clientCharacteristicConfiguration = 0x2902;

  /// The Service Changed characteristic in the GATT service: an indication
  /// of the handle range whose attributes the server has changed.
  static const int serviceChanged = 0x2A05;

  /// The two services every GATT server carries (GAP and GATT). Stacks hide
  /// them from apps; knowing them lets a caller do the same.
  static const int genericAccess = 0x1800;
  static const int genericAttribute = 0x1801;
}

/// Characteristic property bits (Vol 3 Part G, 3.3.1.1).
abstract final class GattProperty {
  static const int read = 0x02;
  static const int writeWithoutResponse = 0x04;
  static const int write = 0x08;
  static const int notify = 0x10;
  static const int indicate = 0x20;
}

/// The longest an attribute value can be (Vol 3 Part F, 3.2.9): where a
/// long read stops whatever the peer keeps sending, and what a long write
/// may not exceed.
const int attMaxAttributeLength = 512;

/// The Bluetooth base UUID, into which a 16-bit assigned number is folded.
const String bluetoothBaseUuidSuffix = '-0000-1000-8000-00805f9b34fb';

/// A 16-bit assigned number in the app's 128-bit lowercase UUID spelling.
String uuid16ToString(int uuid16) =>
    '0000${uuid16.toRadixString(16).padLeft(4, '0')}$bluetoothBaseUuidSuffix';

/// A UUID as it appears in an ATT PDU (little-endian, 2 or 16 bytes) in the
/// app's 128-bit lowercase spelling.
String uuidFromAttBytes(Uint8List bytes) {
  if (bytes.length == 2) {
    return uuid16ToString(bytes[0] | (bytes[1] << 8));
  }
  if (bytes.length != 16) {
    throw FormatException(
      'ATT UUID must be 2 or 16 bytes, got ${bytes.length}',
    );
  }
  final hex = StringBuffer();
  for (var i = 15; i >= 0; i--) {
    hex.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  final h = hex.toString();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// An ATT Error Response, decoded.
class AttErrorPdu {
  final int requestOpcode;
  final int handle;
  final int errorCode;
  const AttErrorPdu(this.requestOpcode, this.handle, this.errorCode);
}

/// One attribute-data entry from a Read By Group Type Response.
class AttGroupEntry {
  final int start;
  final int end;
  final String uuid;
  const AttGroupEntry(this.start, this.end, this.uuid);
}

/// One entry from a Read By Type Response: a handle and its value bytes.
class AttTypeEntry {
  final int handle;
  final Uint8List value;
  const AttTypeEntry(this.handle, this.value);
}

/// One entry from a Find Information Response: a handle and its type.
class AttInfoEntry {
  final int handle;
  final String uuid;
  const AttInfoEntry(this.handle, this.uuid);
}

/// A Handle Value Notification or Indication, decoded.
class AttValueEvent {
  final int handle;
  final Uint8List value;
  final bool isIndication;
  const AttValueEvent(this.handle, this.value, {required this.isIndication});
}

/// Malformed PDU from the peer.
class AttFormatException implements Exception {
  final String message;
  const AttFormatException(this.message);
  @override
  String toString() => 'AttFormatException: $message';
}

/// Encoders for the requests this client sends, and the few responses its
/// minimal server gives.
abstract final class AttEncode {
  static Uint8List exchangeMtu(int clientRxMtu) =>
      _pdu(AttOpcode.exchangeMtuRequest, 2)..setUint16(1, clientRxMtu);

  static Uint8List readByGroupType(int start, int end, int uuid16) =>
      _pdu(AttOpcode.readByGroupTypeRequest, 6)
        ..setUint16(1, start)
        ..setUint16(3, end)
        ..setUint16(5, uuid16);

  static Uint8List readByType(int start, int end, int uuid16) =>
      _pdu(AttOpcode.readByTypeRequest, 6)
        ..setUint16(1, start)
        ..setUint16(3, end)
        ..setUint16(5, uuid16);

  static Uint8List findInformation(int start, int end) =>
      _pdu(AttOpcode.findInformationRequest, 4)
        ..setUint16(1, start)
        ..setUint16(3, end);

  static Uint8List read(int handle) =>
      _pdu(AttOpcode.readRequest, 2)..setUint16(1, handle);

  static Uint8List readBlob(int handle, int offset) =>
      _pdu(AttOpcode.readBlobRequest, 4)
        ..setUint16(1, handle)
        ..setUint16(3, offset);

  static Uint8List write(int handle, List<int> value) =>
      _pdu(AttOpcode.writeRequest, 2 + value.length)
        ..setUint16(1, handle)
        ..setAll(3, value);

  static Uint8List writeCommand(int handle, List<int> value) =>
      _pdu(AttOpcode.writeCommand, 2 + value.length)
        ..setUint16(1, handle)
        ..setAll(3, value);

  /// One piece of a long write, queued by the server at [offset] until an
  /// Execute Write commits or cancels the lot (Vol 3 Part F, 3.4.6.1).
  static Uint8List prepareWrite(int handle, int offset, List<int> part) =>
      _pdu(AttOpcode.prepareWriteRequest, 4 + part.length)
        ..setUint16(1, handle)
        ..setUint16(3, offset)
        ..setAll(5, part);

  /// Commit ([commit]) or discard every queued Prepare Write.
  static Uint8List executeWrite({required bool commit}) =>
      _pdu(AttOpcode.executeWriteRequest, 1)..[1] = commit ? 0x01 : 0x00;

  static Uint8List handleValueConfirmation() =>
      _pdu(AttOpcode.handleValueConfirmation, 0);

  /// The answer to a PEER's Exchange MTU Request.
  static Uint8List exchangeMtuResponse(int serverRxMtu) =>
      _pdu(AttOpcode.exchangeMtuResponse, 2)..setUint16(1, serverRxMtu);

  /// An Error Response to a PEER's request.
  static Uint8List errorResponse(int requestOpcode, int handle, int code) =>
      _pdu(AttOpcode.errorResponse, 4)
        ..[1] = requestOpcode
        ..setUint16(2, handle)
        ..[4] = code;

  static Uint8List _pdu(int opcode, int paramLength) =>
      Uint8List(1 + paramLength)..[0] = opcode;
}

/// Decoders for the responses and events this client receives.
abstract final class AttDecode {
  static int opcode(Uint8List pdu) {
    if (pdu.isEmpty) throw const AttFormatException('empty PDU');
    return pdu[0];
  }

  static const Set<int> _requests = {
    AttOpcode.exchangeMtuRequest,
    AttOpcode.findInformationRequest,
    AttOpcode.findByTypeValueRequest,
    AttOpcode.readByTypeRequest,
    AttOpcode.readRequest,
    AttOpcode.readBlobRequest,
    AttOpcode.readMultipleRequest,
    AttOpcode.readByGroupTypeRequest,
    AttOpcode.writeRequest,
    AttOpcode.prepareWriteRequest,
    AttOpcode.executeWriteRequest,
    AttOpcode.readMultipleVariableRequest,
  };

  /// Whether [opcode] is an ATT request — a PDU the receiver must answer
  /// (with its response or an Error Response) before the sender may send
  /// another.
  static bool isRequest(int opcode) => _requests.contains(opcode);

  /// Whether [opcode] is an ATT command: the Command Flag (bit 6) set, e.g.
  /// Write Command 0x52 or Signed Write Command 0xD2. Commands get no
  /// response, and an unsupported one is silently ignored (3.3.1).
  static bool isCommand(int opcode) => opcode & 0x40 != 0;

  /// The request opcode an ATT response answers, or null for PDUs that are
  /// not responses (notifications, indications, commands).
  static int? requestOpcodeOf(Uint8List pdu) {
    final op = opcode(pdu);
    switch (op) {
      case AttOpcode.errorResponse:
        return error(pdu).requestOpcode;
      case AttOpcode.exchangeMtuResponse:
      case AttOpcode.findInformationResponse:
      case AttOpcode.findByTypeValueResponse:
      case AttOpcode.readByTypeResponse:
      case AttOpcode.readResponse:
      case AttOpcode.readBlobResponse:
      case AttOpcode.readMultipleResponse:
      case AttOpcode.readByGroupTypeResponse:
      case AttOpcode.writeResponse:
      case AttOpcode.prepareWriteResponse:
      case AttOpcode.executeWriteResponse:
      case AttOpcode.readMultipleVariableResponse:
        return op - 1;
      default:
        return null;
    }
  }

  static AttErrorPdu error(Uint8List pdu) {
    _expect(pdu, AttOpcode.errorResponse, minLength: 5);
    return AttErrorPdu(pdu[1], pdu.getUint16(2), pdu[4]);
  }

  static int exchangeMtu(Uint8List pdu) {
    _expect(pdu, AttOpcode.exchangeMtuResponse, minLength: 3);
    return pdu.getUint16(1);
  }

  static List<AttGroupEntry> readByGroupType(Uint8List pdu) {
    _expect(pdu, AttOpcode.readByGroupTypeResponse, minLength: 2);
    final length = pdu[1];
    if (length != 6 && length != 20) {
      throw AttFormatException('group entry length $length');
    }
    return [
      for (var i = 2; i + length <= pdu.length; i += length)
        AttGroupEntry(
          pdu.getUint16(i),
          pdu.getUint16(i + 2),
          uuidFromAttBytes(pdu.sublist(i + 4, i + length)),
        ),
    ];
  }

  static List<AttTypeEntry> readByType(Uint8List pdu) {
    _expect(pdu, AttOpcode.readByTypeResponse, minLength: 2);
    final length = pdu[1];
    if (length < 3) throw AttFormatException('type entry length $length');
    return [
      for (var i = 2; i + length <= pdu.length; i += length)
        AttTypeEntry(pdu.getUint16(i), pdu.sublist(i + 2, i + length)),
    ];
  }

  static List<AttInfoEntry> findInformation(Uint8List pdu) {
    _expect(pdu, AttOpcode.findInformationResponse, minLength: 2);
    final format = pdu[1];
    final uuidLength = switch (format) {
      0x01 => 2,
      0x02 => 16,
      _ => throw AttFormatException('find information format $format'),
    };
    final length = 2 + uuidLength;
    return [
      for (var i = 2; i + length <= pdu.length; i += length)
        AttInfoEntry(
          pdu.getUint16(i),
          uuidFromAttBytes(pdu.sublist(i + 2, i + length)),
        ),
    ];
  }

  static Uint8List read(Uint8List pdu) {
    _expect(pdu, AttOpcode.readResponse, minLength: 1);
    return pdu.sublist(1);
  }

  static Uint8List readBlob(Uint8List pdu) {
    _expect(pdu, AttOpcode.readBlobResponse, minLength: 1);
    return pdu.sublist(1);
  }

  static void writeResponse(Uint8List pdu) =>
      _expect(pdu, AttOpcode.writeResponse, minLength: 1);

  /// A Prepare Write Response: the server's echo of the piece it queued,
  /// which the client must compare with what it sent (3.4.6.2).
  static ({int handle, int offset, Uint8List value}) prepareWrite(
    Uint8List pdu,
  ) {
    _expect(pdu, AttOpcode.prepareWriteResponse, minLength: 5);
    return (
      handle: pdu.getUint16(1),
      offset: pdu.getUint16(3),
      value: pdu.sublist(5),
    );
  }

  static void executeWriteResponse(Uint8List pdu) =>
      _expect(pdu, AttOpcode.executeWriteResponse, minLength: 1);

  /// A notification or indication, or null when [pdu] is neither.
  static AttValueEvent? valueEvent(Uint8List pdu) {
    final op = opcode(pdu);
    if (op != AttOpcode.handleValueNotification &&
        op != AttOpcode.handleValueIndication) {
      return null;
    }
    if (pdu.length < 3) throw const AttFormatException('short value event');
    return AttValueEvent(
      pdu.getUint16(1),
      pdu.sublist(3),
      isIndication: op == AttOpcode.handleValueIndication,
    );
  }

  /// A characteristic declaration value (Vol 3 Part G, 3.3.1): properties,
  /// value handle, UUID.
  static ({int properties, int valueHandle, String uuid}) characteristicDecl(
    Uint8List value,
  ) {
    if (value.length != 5 && value.length != 19) {
      throw AttFormatException(
        'characteristic declaration of ${value.length} bytes',
      );
    }
    return (
      properties: value[0],
      valueHandle: value.getUint16(1),
      uuid: uuidFromAttBytes(value.sublist(3)),
    );
  }

  static void _expect(Uint8List pdu, int opcode, {required int minLength}) {
    if (pdu.length < minLength) {
      throw AttFormatException(
        'PDU 0x${opcode.toRadixString(16)} shorter than $minLength',
      );
    }
    if (pdu[0] != opcode) {
      throw AttFormatException(
        'expected opcode 0x${opcode.toRadixString(16)}, '
        'got 0x${pdu[0].toRadixString(16)}',
      );
    }
  }
}

extension on Uint8List {
  int getUint16(int offset) => this[offset] | (this[offset + 1] << 8);

  void setUint16(int offset, int value) {
    this[offset] = value & 0xFF;
    this[offset + 1] = (value >> 8) & 0xFF;
  }
}
