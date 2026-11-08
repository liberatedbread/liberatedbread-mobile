// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/modbus_sunspec.dart';

/// A SolarEdge inverter's Modbus TCP surface could not be read.
class SunSpecException implements UserFacingException {
  @override
  final String message;

  const SunSpecException(this.message);

  @override
  String toString() => message;
}

/// One connection's worth of request and reply. The bytes on both sides are
/// Rust's; this only carries them. A fake answers in tests.
abstract interface class SunSpecTransport {
  Future<void> open(String host, int port, Duration timeout);

  /// Send one frame and return the whole reply. Throws [TimeoutException] when
  /// nothing complete arrives in time.
  Future<Uint8List> exchange(List<int> request, Duration timeout);

  Future<void> close();
}

/// The real socket, reading until the MBAP length field's worth has arrived.
class SocketSunSpecTransport implements SunSpecTransport {
  /// The longest reply Modbus TCP can carry: MBAP 7 + function 1 + count 1 +
  /// 250 data. The length field is the DEVICE's claim, so it is capped.
  static const maxReplyBytes = 260;

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  final _received = BytesBuilder();
  Completer<void>? _waiter;
  Object? _failure;

  @override
  Future<void> open(String host, int port, Duration timeout) async {
    // ignore: close_sinks — held in _socket and destroyed by close().
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _subscription = socket.listen(
      (chunk) {
        _received.add(chunk);
        _wake();
      },
      onError: (Object error) {
        _failure = error;
        _wake();
      },
      onDone: () {
        _failure ??= const SocketException('the inverter closed the socket');
        _wake();
      },
    );
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  @override
  Future<Uint8List> exchange(List<int> request, Duration timeout) async {
    final socket = _socket;
    if (socket == null) throw StateError('not open');
    _received.clear();
    socket.add(request);
    await socket.flush();
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final bytes = _received.toBytes();
      final length = bytes.length >= 6
          ? sunspecReplyLength(head: bytes.sublist(0, 6))
          : null;
      if (length != null && length > maxReplyBytes) {
        throw const SunSpecException(
          'The device claimed a reply longer than Modbus TCP allows.',
        );
      }
      if (length != null && bytes.length >= length) {
        return Uint8List.sublistView(bytes, 0, length);
      }
      if (bytes.length > maxReplyBytes) {
        throw const SunSpecException('The device sent more than it promised.');
      }
      final failure = _failure;
      if (failure != null) throw failure;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('no reply', timeout);
      final waiter = _waiter = Completer<void>();
      await waiter.future.timeout(left, onTimeout: () {});
    }
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
  }
}

/// What one read of the inverter found.
@immutable
class SunSpecReading {
  final SunSpecCommonDto common;
  final SunSpecInverterDto inverter;

  /// The highest lifetime total seen this session. The spec says never to let
  /// the total go backwards on a bad read.
  final double? lifetimeEnergyWh;

  /// Null when no meter answered at the address the spec gives for meter 1.
  final SunSpecMeterDto? meter;
  final SunSpecMeterPowerDto? meterPower;

  const SunSpecReading({
    required this.common,
    required this.inverter,
    required this.lifetimeEnergyWh,
    this.meter,
    this.meterPower,
  });
}

abstract interface class SunSpecClient {
  Future<SunSpecReading> read();
}

/// Reads a SolarEdge inverter, connecting for each read and closing after it.
///
/// Closing is deliberate. The spec's source says the server holds a single
/// connection and session, so a poller that stayed connected would lock out
/// whatever else on the site reads this inverter.
///
/// READ-ONLY: every frame comes from [sunspecEncodeRead], whose only argument
/// is which named read. Nothing in this class can name a register.
class ModbusSunSpecClient implements SunSpecClient {
  final String host;
  final int port;
  final int unitId;
  final SunSpecTransport Function() transportFactory;

  /// One exchange's ceiling. The spec records 3 s and 30 s from the two
  /// community integrations, and inverters on Wi-Fi answering past 10 s.
  final Duration timeout;

  /// At least 0.1 s between transfers, per SolarEdge's note.
  final Duration gap;

  SunSpecCommonDto? _common;
  SunSpecMeterDto? _meter;
  bool _meterAbsent = false;
  double? _highestEnergy;
  var _transaction = 0;

  ModbusSunSpecClient({
    required this.host,
    required this.port,
    this.unitId = 1,
    SunSpecTransport Function()? transportFactory,
    this.timeout = const Duration(seconds: 12),
    this.gap = const Duration(milliseconds: 150),
  }) : transportFactory = transportFactory ?? SocketSunSpecTransport.new;

  /// The unit id an mDNS announcement names in its `MODBUS_ID` TXT key, or 1
  /// when it is missing or outside 1-247, the same fallback the spec records.
  static int unitIdFromTxt(Map<String, String> txt) {
    final parsed = int.tryParse(txt['MODBUS_ID']?.trim() ?? '');
    return parsed != null && parsed >= 1 && parsed <= 247 ? parsed : 1;
  }

  int _nextTransaction() => _transaction = (_transaction + 1) & 0xffff;

  Future<({Uint8List reply, int transaction})> _ask(
    SunSpecTransport transport,
    SunSpecReadKind kind,
  ) async {
    final transaction = _nextTransaction();
    final request = sunspecEncodeRead(
      kind: kind,
      transactionId: transaction,
      unitId: unitId,
    );
    final reply = await transport.exchange(request, timeout);
    return (reply: reply, transaction: transaction);
  }

  Future<T> _decodeRequired<T>(
    SunSpecTransport transport,
    SunSpecReadKind kind,
    Future<T> Function(Uint8List reply, int transaction) decode,
  ) async {
    final (:reply, :transaction) = await _ask(transport, kind);
    final code = sunspecExceptionCode(
      reply: reply,
      transactionId: transaction,
      unitId: unitId,
    );
    if (code != null) {
      throw SunSpecException(
        'The device refused the read: '
        '${sunspecExceptionMeaning(code: code)}.',
      );
    }
    try {
      return await decode(reply, transaction);
    } on Object catch (e) {
      Log.net.debug('SunSpec reply from $host:$port not understood', error: e);
      throw const SunSpecException(
        'The device answered, but not with SunSpec registers this app reads.',
      );
    }
  }

  @override
  Future<SunSpecReading> read() async {
    final transport = transportFactory();
    try {
      try {
        await transport.open(host, port, timeout);
      } on Object catch (e) {
        Log.net.debug('Modbus connect to $host:$port failed', error: e);
        throw SunSpecException(
          'Could not reach $host:$port. Modbus TCP is off until it is enabled '
          'on the inverter, and only one client can connect at a time.',
        );
      }
      final common = await _readCommon(transport);
      await Future<void>.delayed(gap);
      final inverter = await _decodeRequired(
        transport,
        SunSpecReadKind.inverterBlock,
        (reply, transaction) => sunspecDecodeInverter(
          reply: reply,
          transactionId: transaction,
          unitId: unitId,
        ),
      );
      final energy = inverter.lifetimeEnergyWh;
      final highest = _highestEnergy;
      if (energy != null && (highest == null || energy > highest)) {
        _highestEnergy = energy;
      }
      final power = await _readMeter(transport);
      return SunSpecReading(
        common: common,
        inverter: inverter,
        lifetimeEnergyWh: _highestEnergy,
        meter: power == null ? null : _meter,
        meterPower: power,
      );
    } on SunSpecException {
      rethrow;
    } on TimeoutException {
      throw const SunSpecException(
        'The inverter did not answer in time. Only one client can connect at '
        'a time, so another system polling it can hold this one off.',
      );
    } on Object catch (e) {
      Log.net.debug('Modbus read from $host:$port failed', error: e);
      throw SunSpecException('The connection to $host:$port dropped.');
    } finally {
      await transport.close();
    }
  }

  Future<SunSpecCommonDto> _readCommon(SunSpecTransport transport) async {
    final known = _common;
    if (known != null) return known;
    final common = await _decodeRequired(
      transport,
      SunSpecReadKind.commonBlock,
      (reply, transaction) => sunspecDecodeCommon(
        reply: reply,
        transactionId: transaction,
        unitId: unitId,
      ),
    );
    // The spec's positive identification. Every address after this one is
    // SolarEdge's own, so another vendor's SunSpec map is not read with it.
    if (common.manufacturer != 'SolarEdge') {
      throw SunSpecException(
        'This device reports "${common.manufacturer}", not SolarEdge, and its '
        'registers may not sit where this app reads them.',
      );
    }
    return _common = common;
  }

  /// Meter 1, which is optional. Some firmware does not answer at all for a
  /// block it lacks, so the spec says to treat a timeout as absent and not ask
  /// again on every poll. Any failure here ends the meter for this session,
  /// and never the inverter's reading.
  Future<SunSpecMeterPowerDto?> _readMeter(SunSpecTransport transport) async {
    if (_meterAbsent) return null;
    try {
      await Future<void>.delayed(gap);
      final known = _meter;
      if (known == null) {
        final (:reply, :transaction) = await _ask(
          transport,
          SunSpecReadKind.meter1Common,
        );
        _meter = await sunspecDecodeMeterCommon(
          reply: reply,
          transactionId: transaction,
          unitId: unitId,
        );
        await Future<void>.delayed(gap);
      }
      final (:reply, :transaction) = await _ask(
        transport,
        SunSpecReadKind.meter1Power,
      );
      return await sunspecDecodeMeterPower(
        reply: reply,
        transactionId: transaction,
        unitId: unitId,
      );
    } on Object catch (e) {
      Log.net.debug('No meter 1 on $host:$port', error: e);
      _meterAbsent = true;
      _meter = null;
      return null;
    }
  }
}
