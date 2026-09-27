// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// L2capAttChannel below the ATT layer: the worker's receive loop and the
// descriptor it owns. Two halves.
//
// The loop's decisions, against a scripted socket: what poll() and a
// MSG_DONTWAIT recv() can answer on a Bluetooth socket — pairing's
// ENOTCONN, EAGAIN, EINTR, a zero-length frame, each hang-up bit — and what
// the loop must do with each. The kernel will not produce most of these on
// demand, and the two that matter most (a sleeping recv failing with
// ENOTCONN mid-pairing, and a zero-length frame read as the link ending)
// only ever showed on hardware.
//
// The real thing, over a Unix SOCK_SEQPACKET socketpair: the same worker
// isolate, FFI, poll and recv the production channel runs, on a socket that
// needs no adapter — so the kernel constants, the hand-offs and the send
// path's hang-up check run in every `flutter test` (which also delivers
// SIGPROF to the worker constantly, so EINTR is exercised for free).
@TestOn('linux')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_channel.dart';

// From the kernel headers (asm-generic/poll.h, asm-generic/errno*.h), not
// from att_channel.dart: the loop has to agree with the kernel.
const _pollin = 0x1;
const _pollerr = 0x8;
const _pollhup = 0x10;
const _pollnval = 0x20;
const _pollrdhup = 0x2000;
const _eintr = 4;
const _eagain = 11;
const _enomem = 12;
const _epipe = 32;
const _emsgsize = 90;
const _econnreset = 104;
const _enotconn = 107;

typedef _Recv = ({Uint8List? pdu, int errno});
_Recv _data(List<int> bytes) => (pdu: Uint8List.fromList(bytes), errno: 0);
_Recv _failed(int errno) => (pdu: null, errno: errno);

/// A socket that plays back a script: each call takes the next answer of
/// its kind, and every call is logged. Running past the script throws, so
/// a loop that fails to end fails the test instead of hanging it.
class _Script implements L2capRxSocket {
  final List<int> polls;
  final List<_Recv> recvs;
  final List<int> errors;
  final List<String> calls = [];

  _Script({
    required List<int> polls,
    List<_Recv> recvs = const [],
    List<int> errors = const [0],
  }) : polls = [...polls],
       recvs = [...recvs],
       errors = [...errors];

  @override
  int poll(int timeoutMs) {
    calls.add('poll $timeoutMs');
    if (polls.isEmpty) throw StateError('polled past the script');
    return polls.removeAt(0);
  }

  @override
  _Recv recv() {
    calls.add('recv');
    if (recvs.isEmpty) throw StateError('read past the script');
    return recvs.removeAt(0);
  }

  @override
  int socketError() {
    calls.add('so_error');
    if (errors.isEmpty) throw StateError('SO_ERROR read past the script');
    return errors.removeAt(0);
  }
}

/// Run the loop over [script]: what it delivered and what it ended with.
({List<List<int>> pdus, int errno}) _run(_Script script) {
  final pdus = <List<int>>[];
  final errno = runL2capReceiveLoop(script, pdus.add);
  return (pdus: pdus, errno: errno);
}

// ---- a Unix socketpair, by FFI ----------------------------------------

typedef _SocketpairC = Int32 Function(Int32, Int32, Int32, Pointer<Int32>);
typedef _SocketpairD = int Function(int, int, int, Pointer<Int32>);
typedef _IoC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int32);
typedef _IoD = int Function(int, Pointer<Uint8>, int, int);
typedef _FdC = Int32 Function(Int32);
typedef _FdD = int Function(int);
typedef _ErrnoC = Pointer<Int32> Function();

final _lib = DynamicLibrary.process();
final _socketpair = _lib.lookupFunction<_SocketpairC, _SocketpairD>(
  'socketpair',
);
final _send = _lib.lookupFunction<_IoC, _IoD>('send');
final _recv = _lib.lookupFunction<_IoC, _IoD>('recv');
final _close = _lib.lookupFunction<_FdC, _FdD>('close');
final _errno = _lib.lookupFunction<_ErrnoC, _ErrnoC>('__errno_location');

/// Two connected SOCK_SEQPACKET ends: [ours] for the channel to adopt (it
/// then owns it), [peer] played by the test.
class _Pair {
  final int ours;
  final int peer;
  bool _peerOpen = true;
  _Pair._(this.ours, this.peer);

  factory _Pair.open() {
    final sv = calloc<Int32>(2);
    try {
      // AF_UNIX 1, SOCK_SEQPACKET 5: datagrams on a connection, as L2CAP.
      if (_socketpair(1, 5, 0, sv) != 0) {
        throw StateError('socketpair failed: errno ${_errno().value}');
      }
      return _Pair._(sv[0], sv[1]);
    } finally {
      calloc.free(sv);
    }
  }

  /// One datagram from the peer (an empty list is a zero-length one).
  void send(List<int> bytes) {
    final buf = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      // MSG_NOSIGNAL 0x4000
      if (_send(peer, buf, bytes.length, 0x4000) != bytes.length) {
        throw StateError('peer send failed: errno ${_errno().value}');
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// The next datagram the peer has been sent, waiting up to [within].
  Future<Uint8List> receive({
    Duration within = const Duration(seconds: 5),
  }) async {
    final buf = calloc<Uint8>(2048);
    try {
      final clock = Stopwatch()..start();
      while (true) {
        final n = _recv(peer, buf, 2048, 0x40); // MSG_DONTWAIT
        if (n >= 0) return Uint8List.fromList(buf.asTypedList(n));
        if (clock.elapsed > within) throw TimeoutException('nothing came');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// Hang up the peer's end.
  void hangUp() {
    if (!_peerOpen) return;
    _peerOpen = false;
    _close(peer);
  }
}

Future<void> _until(bool Function() done, String what) async {
  final clock = Stopwatch()..start();
  while (!done()) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('never: $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// What descriptor [fd] is right now ("socket:[inode]"), or null when this
/// process has no such descriptor.
String? _fdTarget(int fd) {
  try {
    return Link('/proc/self/fd/$fd').targetSync();
  } on FileSystemException {
    return null;
  }
}

TypeMatcher<AttChannelException> _sendFailed(int errno) =>
    isA<AttChannelException>()
        .having((e) => e.stage, 'stage', 'send')
        .having((e) => e.errno, 'errno', errno);

void main() {
  group('the receive loop', () {
    test('delivers each PDU, then ends on a hang-up with SO_ERROR', () {
      final script = _Script(
        polls: [_pollin, _pollin, _pollin | _pollerr | _pollhup],
        recvs: [
          _data([0x1b, 0x52, 0, 1]),
          _data([0x1b, 0x52, 0, 2]),
        ],
        errors: [_econnreset],
      );
      final out = _run(script);
      expect(out.pdus, [
        [0x1b, 0x52, 0, 1],
        [0x1b, 0x52, 0, 2],
      ]);
      expect(out.errno, _econnreset);
      expect(
        script.calls,
        ['poll -1', 'recv', 'poll -1', 'recv', 'poll -1', 'so_error'],
        reason: 'blocks only in poll, and reads nothing once hung up',
      );
    });

    test('mid-pairing ENOTCONN with no hang-up is waited out, not the end', () {
      // The socket in BT_CONFIG: a read fails "not connected", yet poll
      // reports no hang-up. A blocking recv turned exactly this into a
      // torn-down link the moment a peer asked for encryption.
      final script = _Script(
        polls: [_pollin, 0, _pollin, _pollrdhup | _pollhup | _pollin],
        recvs: [
          _failed(_enotconn),
          _data([0x0b, 20]),
        ],
      );
      final out = _run(script);
      expect(out.pdus, [
        [0x0b, 20],
      ]);
      expect(out.errno, 0);
      expect(script.calls.take(4), ['poll -1', 'recv', 'poll 0', 'poll -1']);
    });

    test('ENOTCONN on a link that did go ends it, ENOTCONN if SO_ERROR is '
        'empty', () {
      // recv read (and cleared) the teardown's error itself.
      final gone = _Script(
        polls: [_pollin, _pollhup],
        recvs: [_failed(_enotconn)],
        errors: [0],
      );
      expect(_run(gone).errno, _enotconn);
      // SO_ERROR still holding a reason: that one.
      final reason = _Script(
        polls: [_pollin, _pollhup | _pollerr],
        recvs: [_failed(_enotconn)],
        errors: [_econnreset],
      );
      expect(_run(reason).errno, _econnreset);
    });

    test('EAGAIN and EINTR, from poll or recv, only mean poll again', () {
      final script = _Script(
        polls: [-_eintr, _pollin, _pollin, _pollin, _pollhup],
        recvs: [
          _failed(_eagain),
          _failed(_eintr),
          _data([9]),
        ],
      );
      final out = _run(script);
      expect(out.pdus, [
        [9],
      ]);
      expect(out.errno, 0);
    });

    test('a zero-length datagram is nothing to deliver, and not the end', () {
      final script = _Script(
        polls: [_pollin, _pollin, _pollin | _pollrdhup],
        recvs: [
          _data(const []),
          _data([5]),
        ],
      );
      final out = _run(script);
      expect(out.pdus, [
        [5],
      ]);
      expect(out.errno, 0);
    });

    test('every hang-up bit ends it before anything is read', () {
      for (final bit in [_pollerr, _pollhup, _pollrdhup, _pollnval]) {
        for (final revents in [bit, bit | _pollin]) {
          final script = _Script(polls: [revents], errors: [7]);
          expect(
            _run(script).errno,
            7,
            reason: '0x${revents.toRadixString(16)}',
          );
          expect(script.calls, ['poll -1', 'so_error']);
        }
      }
    });

    test('any other failure ends it with that errno', () {
      expect(
        _run(_Script(polls: [_pollin], recvs: [_failed(_econnreset)])).errno,
        _econnreset,
      );
      expect(_run(_Script(polls: [-_enomem])).errno, _enomem);
    });
  });

  group('over a real socket (a Unix socketpair)', () {
    late _Pair pair;
    late L2capAttChannel channel;
    final got = <List<int>>[];
    StreamSubscription<Uint8List>? sub;

    setUp(() async {
      got.clear();
      pair = _Pair.open();
      channel = await L2capAttChannel.adopt(pair.ours);
      sub = channel.incoming.listen(got.add);
    });

    tearDown(() async {
      await channel.close();
      await sub?.cancel();
      pair.hangUp();
    });

    test('PDUs arrive one per datagram; an empty one is skipped', () async {
      pair
        ..send([0x1b, 0x03, 0x00, 1])
        ..send(const [])
        ..send([0x1b, 0x03, 0x00, 2]);
      await _until(() => got.length == 2, 'both PDUs');
      expect(got, [
        [0x1b, 0x03, 0x00, 1],
        [0x1b, 0x03, 0x00, 2],
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(channel.isOpen, isTrue, reason: 'a zero-length frame is no end');
      expect(channel.closeErrno, isNull);
    });

    test('what it sends reaches the peer as one datagram', () async {
      channel.send(Uint8List.fromList([0x0a, 0x03, 0x00]));
      expect(await pair.receive(), [0x0a, 0x03, 0x00]);
    });

    test('the peer hanging up ends it, with no errno named', () async {
      pair.hangUp();
      await channel.closed.timeout(const Duration(seconds: 5));
      expect(channel.isOpen, isFalse);
      expect(channel.closeErrno, 0);
    });

    test('a peer that hangs up on our unread PDU: ECONNRESET', () async {
      channel.send(Uint8List.fromList([0x0a, 0x03, 0x00]));
      // Closing an end with data still queued to it resets the other.
      pair.hangUp();
      await channel.closed.timeout(const Duration(seconds: 5));
      expect(channel.closeErrno, _econnreset);
    });

    test('a send into a socket that is finished says so at once', () async {
      pair.hangUp();
      // Synchronously, before the worker's report can reach this isolate.
      expect(
        () => channel.send(Uint8List.fromList([1])),
        throwsA(_sendFailed(_epipe)),
      );
      expect(channel.isOpen, isFalse, reason: 'the kernel says it is gone');
      // The close() that follows did not end the link, so the kernel's
      // account of it — no reason named — still stands.
      await channel.close();
      expect(channel.closeErrno, 0);
    });

    test('a send the live socket refuses leaves it open', () async {
      // Too big for the socket's buffer: refused, but nothing hung up —
      // as BT_CONFIG refuses a send mid-pairing.
      expect(
        () => channel.send(Uint8List(4 << 20)),
        throwsA(_sendFailed(_emsgsize)),
      );
      expect(channel.isOpen, isTrue);
      channel.send(Uint8List.fromList([2]));
      expect(await pair.receive(), [2]);
    });

    test('close() is ours: no errno, and the worker lets the descriptor '
        'go', () async {
      final target = _fdTarget(pair.ours);
      expect(target, startsWith('socket:'));
      await channel.close();
      expect(channel.isOpen, isFalse);
      expect(channel.closeErrno, isNull);
      // The worker closes it only after this isolate's release.
      await _until(
        () => _fdTarget(pair.ours) != target,
        'the worker closing the descriptor',
      );
      // And the peer sees the hang-up: a zero-length read at end of file.
      expect(await pair.receive(), isEmpty);
    });

    test('the Bluetooth security options fail harmlessly here', () async {
      // setsockopt(BT_SECURITY) fails outright on a non-Bluetooth socket:
      // nothing changed state, so the elevation is false and nothing is
      // closed — unlike one that started and then failed.
      expect(channel.securityLevel, 1);
      expect(await channel.elevateSecurity(2), isFalse);
      expect(channel.isOpen, isTrue);
    });
  });
}
