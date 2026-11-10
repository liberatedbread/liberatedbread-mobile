// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../core/error_text.dart';
import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/apple_acp.dart';

/// An AirPort base station could not be read. Never carries the password.
class AcpException implements UserFacingException {
  @override
  final String message;
  const AcpException(this.message);
  @override
  String toString() => message;
}

/// One TCP connection's bytes.
abstract interface class AcpTransport {
  Future<void> open(String host, int port, Duration timeout);
  Future<void> write(List<int> bytes);

  /// The next bytes to arrive. Throws [TimeoutException] when none do and
  /// [SocketException] when the far end has closed.
  Future<List<int>> read(Duration timeout);
  Future<void> close();
}

class SocketAcpTransport implements AcpTransport {
  Socket? _socket;
  StreamIterator<Uint8List>? _incoming;
  Future<bool>? _pending;

  @override
  Future<void> open(String host, int port, Duration timeout) async {
    // ignore: close_sinks — held in _socket and destroyed by close().
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _incoming = StreamIterator(socket);
  }

  @override
  Future<void> write(List<int> bytes) async {
    final socket = _socket;
    if (socket == null) throw StateError('not open');
    socket.add(bytes);
    await socket.flush();
  }

  @override
  Future<List<int>> read(Duration timeout) async {
    final incoming = _incoming;
    if (incoming == null) throw StateError('not open');
    final pending = _pending ??= incoming.moveNext();
    final more = await pending.timeout(timeout);
    _pending = null;
    if (!more) {
      throw const SocketException('the base station closed the socket');
    }
    return incoming.current;
  }

  @override
  Future<void> close() async {
    _socket?.destroy();
    _socket = null;
    _incoming = null;
    _pending = null;
  }
}

/// Reads an AirPort base station's status over ACP: SRP as `admin` with the
/// base station password, then one encrypted GET_PROPERTY of name, firmware,
/// model, uptime and Wi-Fi name, then close.
///
/// READ-ONLY: the three messages it can write come from three Rust builders
/// that take no command or property (`acp_auth_start_message`,
/// `acp_srp_stage3`, `acp_status_request`). There is no legacy mode: the
/// password never travels in the reversible header key. The password is a
/// parameter of [read] and is kept nowhere.
class AcpStatusClient {
  final String host;
  final int port;
  final AcpTransport Function() transportFactory;
  final Duration timeout;
  final Random _random;

  /// Largest plaintext body this will wait for. A stage-1 reply is about
  /// 450 bytes and a status a few hundred.
  static const maxBody = 64 * 1024;

  AcpStatusClient({
    required this.host,
    required this.port,
    AcpTransport Function()? transportFactory,
    this.timeout = const Duration(seconds: 8),
    Random? random,
  }) : transportFactory = transportFactory ?? SocketAcpTransport.new,
       _random = random ?? Random.secure();

  Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

  Future<AcpStatusDto> read({required String password}) async {
    final transport = transportFactory();
    try {
      try {
        await transport.open(host, port, timeout);
      } on Object catch (e) {
        Log.net.debug('ACP connect to $host:$port failed', error: e);
        throw AcpException('Could not reach the base station at $host:$port.');
      }
      final session = _Session(transport, timeout);
      await session.write(acpAuthStartMessage());
      final (header1, body1) = await session.message();
      final stage3 = await acpSrpStage3(
        challengeHeader: header1,
        challengeBody: body1,
        password: password,
        aPrivate: _randomBytes(24),
        clientIv: _randomBytes(16),
      );
      await session.write(stage3.message);
      final (header2, body2) = await session.message();
      final keys = await acpFinishAuth(
        header: header2,
        body: body2,
        stage3: stage3,
      );
      session.encrypt(keys);
      await session.write(acpStatusRequest());
      return await session.status();
    } on AcpException {
      rethrow;
    } on TimeoutException {
      throw const AcpException('The base station did not answer in time.');
    } on AnyhowException catch (e) {
      // The codec's messages carry no password; they name what was wrong.
      if (e.message.contains('password is incorrect')) {
        throw const AcpException('The base station refused that password.');
      }
      Log.net.debug('ACP read failed: ${e.message}');
      throw AcpException(
        'The base station answered, but not in a way this app accepts: '
        '${_firstLine(e.message)}.',
      );
    } on Object catch (e) {
      Log.net.debug('ACP read failed: ${e.runtimeType}');
      throw const AcpException(
        'The base station answered, but not in a form this app can read.',
      );
    } finally {
      await transport.close();
    }
  }

  static String _firstLine(String text) {
    final line = text.split('\n').first.trim();
    return line.endsWith('.') ? line.substring(0, line.length - 1) : line;
  }
}

/// A connection's two directions: plaintext until [encrypt], then each
/// direction through its own keystream, continued across messages.
class _Session {
  final AcpTransport transport;
  final Duration timeout;
  final _plain = <int>[];
  AcpSessionKeysDto? _keys;
  var _sent = 0;
  var _received = 0;

  _Session(this.transport, this.timeout);

  Future<void> write(List<int> bytes) async {
    final keys = _keys;
    if (keys == null) {
      await transport.write(bytes);
      return;
    }
    final cipher = acpCtrApply(
      key: keys.clientKey,
      iv: keys.clientIv,
      offset: BigInt.from(_sent),
      data: bytes,
    );
    _sent += bytes.length;
    await transport.write(cipher);
  }

  /// From here on both directions are encrypted. Anything already received
  /// and not yet read arrived after the stage-3 reply, so it is ciphertext.
  void encrypt(AcpSessionKeysDto keys) {
    _keys = keys;
    final leftover = List<int>.of(_plain);
    _plain.clear();
    _absorb(leftover);
  }

  void _absorb(List<int> chunk) {
    final keys = _keys;
    if (keys == null) {
      _plain.addAll(chunk);
      return;
    }
    _plain.addAll(
      acpCtrApply(
        key: keys.serverKey,
        iv: keys.serverIv,
        offset: BigInt.from(_received),
        data: chunk,
      ),
    );
    _received += chunk.length;
  }

  Future<void> _fill(int n, DateTime deadline) async {
    while (_plain.length < n) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('ACP read', timeout);
      _absorb(await transport.read(left));
    }
  }

  Uint8List _take(int n) {
    final out = Uint8List.fromList(_plain.sublist(0, n));
    _plain.removeRange(0, n);
    return out;
  }

  /// One header and the body its size states (none for -1).
  Future<(Uint8List, Uint8List)> message() async {
    final deadline = DateTime.now().add(timeout);
    await _fill(128, deadline);
    final header = _take(128);
    final size = acpDecodeHeader(header: header).bodySize;
    if (size > AcpStatusClient.maxBody) {
      throw const AcpException('The base station sent a reply too long.');
    }
    if (size <= 0) return (header, Uint8List(0));
    await _fill(size, deadline);
    return (header, _take(size));
  }

  /// The status reply: a header, then elements up to the end marker (the
  /// clients do not trust the header's size here, and neither does this).
  Future<AcpStatusDto> status() async {
    final deadline = DateTime.now().add(timeout);
    await _fill(128, deadline);
    final header = _take(128);
    while (true) {
      final status = acpFeedStatus(
        header: header,
        body: Uint8List.fromList(_plain),
      );
      if (status != null) return status;
      if (_plain.length > AcpStatusClient.maxBody) {
        throw const AcpException('The base station sent a reply too long.');
      }
      await _fill(_plain.length + 1, deadline);
    }
  }
}
