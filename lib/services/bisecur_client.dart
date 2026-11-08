// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/bisecur.dart';

/// A BiSecur gateway could not be read. Never carries the password.
class BiSecurException implements UserFacingException {
  @override
  final String message;

  const BiSecurException(this.message);

  @override
  String toString() => message;
}

/// One TCP connection's bytes. The frames are Rust's; a fake answers in tests.
abstract interface class BiSecurTransport {
  Future<void> open(String host, int port, Duration timeout);
  Future<void> write(List<int> bytes);

  /// The next bytes to arrive. Throws [TimeoutException] when none do, and
  /// [SocketException] when the gateway has closed the connection.
  Future<List<int>> read(Duration timeout);
  Future<void> close();
}

class SocketBiSecurTransport implements BiSecurTransport {
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
    // A read that timed out is still waiting on the iterator, which allows
    // only one moveNext at a time, so the next read picks that one up.
    final pending = _pending ??= incoming.moveNext();
    final more = await pending.timeout(timeout);
    _pending = null;
    if (!more) throw const SocketException('the gateway closed the socket');
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

/// One port's reading.
@immutable
class BiSecurPortReading {
  final String groupName;
  final BiSecurPortDto port;

  /// Null when the gateway had no position to give; see [note].
  final BiSecurTransitionDto? transition;
  final String? note;

  const BiSecurPortReading({
    required this.groupName,
    required this.port,
    this.transition,
    this.note,
  });
}

abstract interface class BiSecurClient {
  Future<List<BiSecurPortReading>> read({
    required String user,
    required String password,
  });
}

/// Reads door positions from a BiSecur gateway, one whole session per read:
/// log in, list the doors, read each port, log out, close.
///
/// READ-ONLY: the frames come from four named encoders, and none of them can
/// build SET_STATE. A read is only ever started by the user, because the
/// gateway resets a connection polled too fast.
///
/// The password is a parameter of [read] and is kept nowhere here. The login
/// frame carries it in clear, so that frame is never logged.
class BiSecurGatewayClient implements BiSecurClient {
  final String host;
  final int port;
  final String gatewayMac;
  final BiSecurTransport Function() transportFactory;
  final Duration timeout;

  /// About 100 ms between any two commands, per the spec's source.
  final Duration commandGap;

  /// Position polls no faster than about every 2 s, or the gateway resets the
  /// connection.
  final Duration positionGap;

  var _tag = 0;

  BiSecurGatewayClient({
    required this.host,
    required this.port,
    required this.gatewayMac,
    BiSecurTransport Function()? transportFactory,
    this.timeout = const Duration(seconds: 8),
    this.commandGap = const Duration(milliseconds: 150),
    this.positionGap = const Duration(milliseconds: 2100),
  }) : transportFactory = transportFactory ?? SocketBiSecurTransport.new;

  /// 1..254. 0xFF is the gateway's own tag on a stale-session LOGOUT.
  int _nextTag() => _tag = (_tag % 254) + 1;

  @override
  Future<List<BiSecurPortReading>> read({
    required String user,
    required String password,
  }) async {
    final transport = transportFactory();
    try {
      try {
        await transport.open(host, port, timeout);
      } on Object catch (e) {
        Log.net.debug('BiSecur connect to $host:$port failed', error: e);
        throw BiSecurException('Could not reach the gateway at $host:$port.');
      }
      final session = _Session(transport, timeout);
      final token = await _login(session, user, password);
      try {
        return await _readDoors(session, token);
      } finally {
        await _logout(transport, token);
      }
    } on BiSecurException {
      rethrow;
    } on TimeoutException {
      throw const BiSecurException(
        'The gateway did not answer in time. It can stop answering for a '
        'while after being read too often, so wait and try again.',
      );
    } on Object catch (e) {
      // Logged without the frame: the session's bytes may hold a login.
      Log.net.debug('BiSecur read failed: ${e.runtimeType}');
      throw const BiSecurException(
        'The gateway answered, but not in a form this app can read.',
      );
    } finally {
      await transport.close();
    }
  }

  Future<int> _login(_Session session, String user, String password) async {
    final tag = _nextTag();
    final BiSecurReplyDto reply;
    try {
      await session.transport.write(
        await bisecurEncodeLogin(
          gatewayMac: gatewayMac,
          tag: tag,
          user: user,
          password: password,
        ),
      );
      reply = await session.answer(tag, BiSecurExchangeKind.login);
    } on TimeoutException {
      rethrow;
    } on Object catch (e) {
      // Never `e` in a message: an encoder's error could echo what it was given.
      Log.net.debug('BiSecur login failed: ${e.runtimeType}');
      throw const BiSecurException(
        'The gateway answered the login, but not in a form this app can read.',
      );
    }
    if (reply.kind == BiSecurReplyKind.error) {
      throw BiSecurException(
        reply.errorCode == 2
            ? 'The gateway refused that user name and password.'
            : 'The gateway refused the login: '
                  '${bisecurErrorMeaning(code: reply.errorCode ?? 255)}.',
      );
    }
    return bisecurDecodeLogin(payload: reply.payload);
  }

  Future<List<BiSecurPortReading>> _readDoors(
    _Session session,
    int token,
  ) async {
    await Future<void>.delayed(commandGap);
    final tag = _nextTag();
    await session.transport.write(
      await bisecurEncodeGetGroups(
        gatewayMac: gatewayMac,
        tag: tag,
        token: token,
      ),
    );
    final reply = await session.answer(tag, BiSecurExchangeKind.getGroups);
    if (reply.kind == BiSecurReplyKind.error) {
      throw BiSecurException(
        'The gateway refused the door list: '
        '${bisecurErrorMeaning(code: reply.errorCode ?? 255)}.',
      );
    }
    final groups = await bisecurDecodeGroups(payload: reply.payload);
    final readings = <BiSecurPortReading>[];
    for (final group in groups) {
      for (final port in group.ports) {
        await Future<void>.delayed(readings.isEmpty ? commandGap : positionGap);
        readings.add(await _readPort(session, token, group, port));
      }
    }
    return readings;
  }

  Future<BiSecurPortReading> _readPort(
    _Session session,
    int token,
    BiSecurGroupDto group,
    BiSecurPortDto port,
  ) async {
    final tag = _nextTag();
    await session.transport.write(
      await bisecurEncodeGetTransition(
        gatewayMac: gatewayMac,
        tag: tag,
        token: token,
        port: port.id,
      ),
    );
    final reply = await session.answer(tag, BiSecurExchangeKind.getTransition);
    if (reply.kind == BiSecurReplyKind.error) {
      return BiSecurPortReading(
        groupName: group.name,
        port: port,
        note: reply.errorCode == _portError
            ? 'The gateway gave no position for this port. That can be a '
                  'passing miss, or a port taught from a hand transmitter, '
                  'which never reports one.'
            : 'The gateway refused this read: '
                  '${bisecurErrorMeaning(code: reply.errorCode ?? 255)}.',
      );
    }
    return BiSecurPortReading(
      groupName: group.name,
      port: port,
      transition: await bisecurDecodeTransition(payload: reply.payload),
    );
  }

  static const _portError = 10;

  /// Best effort. The spec says to send it before closing, or the session
  /// lingers for about 30 minutes, and that it gets no reply.
  Future<void> _logout(BiSecurTransport transport, int token) async {
    try {
      await Future<void>.delayed(commandGap);
      await transport.write(
        await bisecurEncodeLogout(
          gatewayMac: gatewayMac,
          tag: _nextTag(),
          token: token,
        ),
      );
    } on Object catch (e) {
      Log.net.debug('BiSecur logout failed: ${e.runtimeType}');
    }
  }
}

/// The reply half of a session: a byte buffer and the frames cut from it.
class _Session {
  final BiSecurTransport transport;
  final Duration timeout;
  var _buffer = Uint8List(0);
  final _frames = <Uint8List>[];

  _Session(this.transport, this.timeout);

  /// The next frame answering this tag. Stale-session LOGOUTs and anything
  /// else not for it are skipped; the wait is bounded overall, so a gateway
  /// repeating itself cannot hold this forever.
  Future<BiSecurReplyDto> answer(int tag, BiSecurExchangeKind exchange) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      while (_frames.isNotEmpty) {
        final reply = await bisecurDecodeReply(
          frame: _frames.removeAt(0),
          expectedTag: tag,
          exchange: exchange,
        );
        if (reply.kind != BiSecurReplyKind.skip) return reply;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('no answer for tag $tag', timeout);
      }
      final chunk = await transport.read(left);
      final split = await bisecurSplitStream(
        buffer: Uint8List.fromList([..._buffer, ...chunk]),
      );
      _buffer = split.rest;
      _frames.addAll(split.frames);
    }
  }
}
