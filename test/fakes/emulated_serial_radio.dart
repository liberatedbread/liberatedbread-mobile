// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A UV-5R-family radio on the far end of a programming cable.

import 'dart:async';
import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/byte_inbox.dart';
import 'package:liberated_bread_mobile/services/serial_port_service.dart';

/// A radio of the older serial family, answering a cable byte by byte.
///
/// A serial link has no message boundaries, so unlike the Bluetooth
/// emulation — one GATT write, one command — this one parses a stream:
/// ident magic, ident request, clone mode, then `S` reads and `X` writes.
/// Its memory is the radio's whole address space, so the driver's reads
/// outside the image (the priming read) land somewhere real too.
///
/// It is written from the same facts the codec is, which is a limit worth
/// naming: a mistake in those facts would be made twice, once here and once
/// in Rust, and agree with itself. What it does prove is that the driver
/// holds a conversation of the documented shape, reassembles it from a
/// stream, and turns that into the right image and the right writes. The
/// live-radio suite is what checks the facts.
class EmulatedUv5rRadio {
  /// The radio's address space, 0x0000..0x2000.
  final Uint8List memory = Uint8List(0x2000);

  /// What the radio answers the ident request with.
  final List<int> ident;

  /// The magics this radio acknowledges. A real one answers exactly one.
  final List<List<int>> acceptedMagics;

  /// Model the radios that drop a byte from a full-size read of 0x1FC0.
  bool dropsByte = false;

  /// Answer nothing from this read address on: a radio going away mid-read.
  int? goSilentAt;

  /// Refuse a write here with a NAK: a radio that stops accepting mid-write.
  int? refuseWriteAt;

  /// Acknowledge a write here but keep none of it: the failure only reading
  /// back can catch.
  int? loseWriteAt;

  /// Reads served, as (address, length), in order.
  final List<(int, int)> reads = [];

  /// Writes accepted, as (address, data), in order.
  final List<(int, List<int>)> writes = [];

  /// How many times a magic has been acknowledged.
  int sessions = 0;

  void Function(List<int> bytes)? _sink;
  final List<int> _pending = [];
  _State _state = _State.idle;

  EmulatedUv5rRadio({
    required this.ident,
    required this.acceptedMagics,
    String firmware = 'BFB297',
  }) {
    // A recognisable pattern everywhere, so a block landing in the wrong
    // place is obvious rather than plausible.
    for (var i = 0; i < memory.length; i++) {
      memory[i] = (i * 31 + 7) & 0xFF;
    }
    setFirmware(firmware);
  }

  void setFirmware(String firmware) {
    memory.fillRange(0x1EF0, 0x1EF0 + 14, 0xFF);
    memory.setRange(0x1EF0, 0x1EF0 + firmware.length, firmware.codeUnits);
  }

  /// Empty every channel slot and its name, as a factory-fresh radio has.
  void clearChannels() {
    memory.fillRange(0x0000, 0x0800, 0xFF);
    memory.fillRange(0x1000, 0x1800, 0xFF);
  }

  void _reply(List<int> bytes) => _sink?.call(bytes);

  /// A new cable connection: the radio forgets any session in progress.
  void _connect(void Function(List<int> bytes) sink) {
    _sink = sink;
    _pending.clear();
    _state = _State.idle;
  }

  void _disconnect() {
    _sink = null;
    _pending.clear();
    _state = _State.idle;
  }

  void _receive(List<int> bytes) {
    for (final byte in bytes) {
      _pending.add(byte);
      _drain();
    }
  }

  void _drain() {
    while (_pending.isNotEmpty) {
      if (!_step()) return;
    }
  }

  /// Consume what can be consumed from the front of [_pending]. False when
  /// more bytes are needed first.
  bool _step() {
    switch (_state) {
      case _State.idle:
        for (final magic in acceptedMagics) {
          if (_endsWith(_pending, magic)) {
            _pending.clear();
            sessions++;
            _state = _State.awaitIdentRequest;
            _reply([0x06]);
            return true;
          }
        }
        // Keep only as much as the longest magic could need.
        if (_pending.length > 7) _pending.removeAt(0);
        return false;
      case _State.awaitIdentRequest:
        final byte = _pending.removeAt(0);
        if (byte == 0x02) {
          _state = _State.awaitIdentAck;
          _reply(ident);
        }
        return true;
      case _State.awaitIdentAck:
        final byte = _pending.removeAt(0);
        if (byte == 0x06) {
          _state = _State.clone;
          _reply([0x06]);
        }
        return true;
      case _State.clone:
        return _cloneStep();
    }
  }

  bool _cloneStep() {
    final opcode = _pending.first;
    if (opcode == 0x06) {
      // The host acknowledging a block. The radio acknowledges that in turn,
      // which is the byte a driver finds ahead of its next read's answer.
      _pending.removeAt(0);
      _reply([0x06]);
      return true;
    }
    if (opcode != 0x53 && opcode != 0x58) {
      _pending.removeAt(0);
      return true;
    }
    if (_pending.length < 4) return false;
    final addr = (_pending[1] << 8) | _pending[2];
    final len = _pending[3];
    if (opcode == 0x53) {
      _pending.removeRange(0, 4);
      if (goSilentAt != null && addr >= goSilentAt!) return true;
      reads.add((addr, len));
      final data = memory.sublist(addr, addr + len);
      if (dropsByte && addr == 0x1FC0 && len == 0x40) {
        // A full-size read here comes back damaged, with 0xFF where 0x1FCF
        // should be — the one thing the probe looks at. The driver must
        // then read this stretch sixteen bytes at a time, which is served
        // intact.
        data[15] = 0xFF;
      }
      _reply([0x58, addr >> 8, addr & 0xFF, len, ...data]);
      return true;
    }
    if (_pending.length < 4 + len) return false;
    final data = _pending.sublist(4, 4 + len);
    _pending.removeRange(0, 4 + len);
    if (refuseWriteAt == addr) {
      _reply([0x15]);
      return true;
    }
    if (loseWriteAt != addr) memory.setRange(addr, addr + len, data);
    writes.add((addr, data));
    _reply([0x06]);
    return true;
  }

  static bool _endsWith(List<int> buffer, List<int> suffix) {
    if (buffer.length < suffix.length) return false;
    final start = buffer.length - suffix.length;
    for (var i = 0; i < suffix.length; i++) {
      if (buffer[start + i] != suffix[i]) return false;
    }
    return true;
  }
}

enum _State { idle, awaitIdentRequest, awaitIdentAck, clone }

/// One cable, with [radio] on the far end.
class EmulatedSerialPortService implements SerialPortService {
  final EmulatedUv5rRadio radio;

  static const SerialPortInfo cable = SerialPortInfo(
    id: '/dev/ttyUSB-emulated',
    name: '/dev/ttyUSB-emulated',
    vendorId: 0x1A86,
    productId: 0x7523,
  );

  /// The baud rate of every open, in order.
  final List<int> openedAt = [];

  int openLinks = 0;

  EmulatedSerialPortService(this.radio);

  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async => const [cable];

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) async {
    if (port.id != cable.id) {
      throw SerialPortException('no such port ${port.id}');
    }
    openedAt.add(baudRate);
    openLinks++;
    return _EmulatedLink(this);
  }
}

class _EmulatedLink implements SerialLink {
  final EmulatedSerialPortService _service;
  final ByteInbox _inbox = ByteInbox();
  bool _closed = false;

  _EmulatedLink(this._service) {
    _service.radio._connect(_inbox.add);
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed) throw StateError('write on a closed link');
    _service.radio._receive(bytes);
  }

  @override
  Future<Uint8List> read(int length, {required Duration timeout}) async =>
      Uint8List.fromList(await _inbox.take(length, timeout));

  @override
  Future<void> discardInput() async => _inbox.clear();

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _service.openLinks--;
    _service.radio._disconnect();
  }
}
