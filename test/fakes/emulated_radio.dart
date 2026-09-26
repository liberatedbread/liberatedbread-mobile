// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A Baofeng that is not there, at the GATT level.

import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart' as rust;

import 'emulated_ble.dart';

/// An emulated radio: the FFE0/FFE1 tunnel, and a codeplug behind it.
///
/// This plugs in at flutter_blue_plus's platform seam, so a test drives the
/// REAL BleService and the REAL driver against it -- everything but the
/// radio. The replies are built with the same substitution the driver undoes,
/// through the Rust API, so the decode being exercised is the real one rather
/// than a matching pair of mistakes.
class EmulatedRadio {
  final EmulatedPeripheral peripheral;

  /// The image the radio is holding, in the clear.
  Uint8List image;

  /// Blocks the central has written, keyed by address, descrambled.
  final Map<int, List<int>> written = {};

  /// Commands received, in order, so a test can assert the conversation
  /// happened in the right sequence.
  final List<List<int>> commands = [];

  /// Refuse the write at this address with a NAK, to model a radio that
  /// stops accepting mid-upload.
  int? failWriteAt;

  /// Answer nothing at all from this address on, to model a radio that goes
  /// away mid-read.
  int? goSilentAt;

  /// How many bytes fit in one notification. The BLE minimum leaves 20, which
  /// is what makes a 0x44-byte reply arrive in three pieces -- the case the
  /// reassembly exists for.
  int notificationChunk = 20;

  bool _identified = false;
  int _handshakeStep = 0;

  EmulatedRadio._(this.peripheral, this.image);

  /// Build one, with its replies precomputed.
  ///
  /// The scrambling has to happen before the write hook runs, because that
  /// hook is synchronous and the Rust bindings are not.
  static Future<EmulatedRadio> create({
    String id = 'AA:BB:CC:DD:EE:99',
    String name = 'UV-5R Mini',
    String modelId = 'uv-5r-mini',
    Uint8List? image,
  }) async {
    final models = await rust.radioModels();
    final model = models.firstWhere((m) => m.id == modelId);
    final contents = image ?? _patternedImage(model.imageLen);

    final characteristic = EmulatedCharacteristic(
      uuid: baofengUartCharacteristic,
      canWriteWithoutResponse: true,
      canWriteWithResponse: true,
      canNotify: true,
    );
    final peripheral = EmulatedPeripheral(
      id: id,
      name: name,
      mtu: 23,
      services: [
        EmulatedService(
          uuid: baofengUartService,
          characteristics: [characteristic],
        ),
      ],
    );

    final radio = EmulatedRadio._(peripheral, contents);
    radio._magic = await rust.radioIdentMagic(modelId: modelId);
    radio._handshake = await rust.radioHandshakeSteps();
    radio._ack = await rust.radioAckByte();

    // Pre-scramble every block the driver might read. Reusing the write
    // command's framing is how the real substitution gets applied without a
    // second implementation of it here.
    for (final block in await rust.radioReadPlan(modelId: modelId)) {
      final start = block.imageOffset;
      final plain = contents.sublist(start, start + block.len);
      final frame = await rust.radioWriteCommand(addr: block.addr, data: plain);
      radio._scrambled[block.addr] = frame.sublist(4);
    }

    characteristic.onWrite = radio._onWrite;
    return radio;
  }

  List<int> _magic = const [];
  List<rust.HandshakeStepDto> _handshake = const [];
  int _ack = 0x06;
  final Map<int, List<int>> _scrambled = {};

  /// A recognisable image: every byte its own offset, so a block landing at
  /// the wrong place is obvious rather than plausible.
  static Uint8List _patternedImage(int length) => Uint8List.fromList(
    List<int>.generate(length, (i) => (i * 31 + 7) & 0xFF),
  );

  void _reply(List<int> bytes) {
    for (var offset = 0; offset < bytes.length; offset += notificationChunk) {
      final end = (offset + notificationChunk).clamp(0, bytes.length);
      peripheral.pushNotification(
        baofengUartCharacteristic,
        bytes.sublist(offset, end),
      );
    }
  }

  void _onWrite(EmulatedPeripheral peripheral, List<int> value) {
    commands.add(value);

    // The magic re-enters programming mode from wherever the radio was. A
    // real one forgets its session when the link drops, and the driver opens
    // a fresh connection per operation -- so a read followed by a write sends
    // the magic twice, and the second one has to be answered.
    if (_listEquals(value, _magic)) {
      _identified = true;
      _handshakeStep = 0;
      _reply([_ack]);
      return;
    }

    if (!_identified) {
      // Anything before the magic is ignored, the way a radio that is on but
      // not in programming mode would.
      return;
    }

    if (_handshakeStep < _handshake.length) {
      final step = _handshake[_handshakeStep];
      if (_listEquals(value, step.request)) {
        _handshakeStep++;
        _reply(List<int>.filled(step.expectedReplyLen, 0x00));
      }
      return;
    }

    if (value.length < 4) return;
    final opcode = value[0];
    final addr = (value[1] << 8) | value[2];
    final len = value[3];

    if (opcode == 0x52) {
      if (goSilentAt != null && addr >= goSilentAt!) return;
      final payload = _scrambled[addr];
      if (payload == null) return;
      _reply([0x52, value[1], value[2], len, ...payload]);
      return;
    }

    if (opcode == 0x57) {
      if (failWriteAt == addr) {
        _reply([0x15]);
        return;
      }
      written[addr] = value.sublist(4);
      _reply([_ack]);
    }
  }

  /// What the central actually wrote at [addr], descrambled.
  ///
  /// The substitution is its own inverse, so the read parser is what turns
  /// the recorded bytes back into plaintext.
  Future<List<int>> plaintextWrittenAt(int addr, int len) async {
    final scrambled = written[addr];
    if (scrambled == null) throw StateError('nothing written at 0x$addr');
    return rust.radioParseReadReply(
      reply: [0x52, (addr >> 8) & 0xFF, addr & 0xFF, len, ...scrambled],
      addr: addr,
      len: len,
    );
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
