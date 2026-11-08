// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'direct_att/att_channel.dart' show bdaddrBytes;

class SppTransportException implements Exception {
  final String stage;
  final int? errno;
  final String message;

  const SppTransportException(this.stage, this.message, {this.errno});

  @override
  String toString() =>
      'SppTransportException($stage): $message'
      '${errno == null ? '' : ' (errno $errno)'}';
}

/// Resolve SPP over SDP, then make one Brother status request over RFCOMM.
/// The blocking socket calls run on a worker isolate and have their own
/// deadlines; Dart sockets have no AF_BLUETOOTH support.
Future<Uint8List> linuxSppProbe(
  String address,
  List<int> payload,
  Duration timeout,
) => Isolate.run(() => _probe(address, payload, timeout));

Uint8List _probe(String address, List<int> payload, Duration timeout) {
  final clock = Stopwatch()..start();
  int left() {
    final ms = timeout.inMilliseconds - clock.elapsedMilliseconds;
    if (ms <= 0) {
      throw const SppTransportException('timeout', 'SPP probe timed out');
    }
    return ms;
  }

  var sdp = -1;
  var serial = -1;
  try {
    sdp = _openSocket(_SocketKind.l2cap, address, 1, left());
    _writeAll(sdp, buildSppSdpRequest(), left);
    final response = _readSome(sdp, left);
    final channel = rfcommChannelFromSdpResponse(response);
    if (channel == null) {
      throw const SppTransportException(
        'sdp',
        'the printer did not publish an SPP RFCOMM channel',
      );
    }
    _close(sdp);
    sdp = -1;

    serial = _openSocket(_SocketKind.rfcomm, address, channel, left());
    _writeAll(serial, payload, left);
    final reply = BytesBuilder();
    while (reply.length < 32) {
      reply.add(_readSome(serial, left));
    }
    final status = reply.takeBytes().sublist(0, 32);
    if (status[0] != 0x80 || status[1] != 0x20 || status[2] != 0x42) {
      throw const SppTransportException(
        'status',
        'the SPP reply was not a Brother status frame',
      );
    }
    return Uint8List.fromList(status);
  } finally {
    if (sdp >= 0) _close(sdp);
    if (serial >= 0) _close(serial);
  }
}

Uint8List buildSppSdpRequest({int transactionId = 1}) => Uint8List.fromList([
  0x04,
  (transactionId >> 8) & 0xff,
  transactionId & 0xff,
  0x00,
  0x0d,
  0x35,
  0x03,
  0x19,
  0x11,
  0x01,
  0x00,
  0xff,
  0x35,
  0x03,
  0x09,
  0x00,
  0x04,
  0x00,
]);

int? rfcommChannelFromSdpResponse(List<int> response) {
  if (response.length < 6) {
    throw const FormatException('short SDP response');
  }
  if (response[0] == 0x06) {
    throw const FormatException('the printer rejected the SDP request');
  }
  if (response[0] != 0x05) {
    throw const FormatException('not an SDP service-search-attribute response');
  }
  final length = (response[3] << 8) | response[4];
  if (length < 1 || response.length < 5 + length) {
    throw const FormatException('truncated SDP response');
  }
  if (response[5 + length - 1] != 0) {
    throw const FormatException(
      'a continued SDP response is not one SPP record',
    );
  }
  final attributes = response.sublist(5, 5 + length - 1);
  final root = _parseElement(attributes, 0).element;
  return _rfcommChannel(root);
}

class _Element {
  final int type;
  final List<int> value;
  final List<_Element> children;

  const _Element(this.type, this.value, this.children);

  int? get unsigned => switch (value.length) {
    1 => value[0],
    2 => (value[0] << 8) | value[1],
    4 => (value[0] << 24) | (value[1] << 16) | (value[2] << 8) | value[3],
    _ => null,
  };

  int? get uuid => type == 3 ? unsigned : null;
}

({_Element element, int next}) _parseElement(List<int> bytes, int offset) {
  if (offset >= bytes.length) throw const FormatException('short SDP element');
  final header = bytes[offset++];
  final type = header >> 3;
  final descriptor = header & 7;
  if (type == 0) return (element: const _Element(0, [], []), next: offset);

  var size = 0;
  if (descriptor <= 4) {
    size = 1 << descriptor;
  } else {
    final lengthBytes = 1 << (descriptor - 5);
    if (offset + lengthBytes > bytes.length) {
      throw const FormatException('short SDP element length');
    }
    for (var i = 0; i < lengthBytes; i++) {
      size = (size << 8) | bytes[offset++];
    }
  }
  final end = offset + size;
  if (end > bytes.length) {
    throw const FormatException('truncated SDP element');
  }
  final value = bytes.sublist(offset, end);
  if (type != 6 && type != 7) {
    return (element: _Element(type, value, const []), next: end);
  }
  final children = <_Element>[];
  var child = 0;
  while (child < value.length) {
    final parsed = _parseElement(value, child);
    children.add(parsed.element);
    child = parsed.next;
  }
  return (element: _Element(type, value, children), next: end);
}

int? _rfcommChannel(_Element element) {
  final children = element.children;
  if (children.length >= 2 &&
      children[0].uuid == 0x0003 &&
      children[1].type == 1) {
    final channel = children[1].unsigned;
    if (channel != null && channel >= 1 && channel <= 30) return channel;
  }
  for (final child in children) {
    final channel = _rfcommChannel(child);
    if (channel != null) return channel;
  }
  return null;
}

enum _SocketKind { l2cap, rfcomm }

const _afBluetooth = 31;
const _sockStream = 1;
const _sockSeqpacket = 5;
const _btprotoL2cap = 0;
const _btprotoRfcomm = 3;
const _fGetfl = 3;
const _fSetfl = 4;
const _oNonblock = 0x800;
const _einprogress = 115;
const _eintr = 4;
const _eagain = 11;
const _etimedout = 110;
const _pollin = 1;
const _pollout = 4;
const _pollerr = 8;
const _pollhup = 0x10;
const _msgDontwait = 0x40;
const _msgNosignal = 0x4000;

typedef _SocketC = Int32 Function(Int32, Int32, Int32);
typedef _SocketD = int Function(int, int, int);
typedef _SockaddrC = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef _SockaddrD = int Function(int, Pointer<Uint8>, int);
typedef _IoC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int32);
typedef _IoD = int Function(int, Pointer<Uint8>, int, int);
typedef _FcntlC = Int32 Function(Int32, Int32, VarArgs<(Int32,)>);
typedef _FcntlD = int Function(int, int, int);
typedef _PollC = Int32 Function(Pointer<Uint8>, UintPtr, Int32);
typedef _PollD = int Function(Pointer<Uint8>, int, int);
typedef _FdC = Int32 Function(Int32);
typedef _FdD = int Function(int);
typedef _ErrnoC = Pointer<Int32> Function();
typedef _ErrnoD = Pointer<Int32> Function();

class _Libc {
  final DynamicLibrary _lib = DynamicLibrary.process();
  late final socket = _lib.lookupFunction<_SocketC, _SocketD>('socket');
  late final bind = _lib.lookupFunction<_SockaddrC, _SockaddrD>('bind');
  late final connect = _lib.lookupFunction<_SockaddrC, _SockaddrD>('connect');
  late final send = _lib.lookupFunction<_IoC, _IoD>('send');
  late final recv = _lib.lookupFunction<_IoC, _IoD>('recv');
  late final fcntl = _lib.lookupFunction<_FcntlC, _FcntlD>('fcntl');
  late final poll = _lib.lookupFunction<_PollC, _PollD>('poll');
  late final closeFd = _lib.lookupFunction<_FdC, _FdD>('close');
  late final _errnoLocation = _lib.lookupFunction<_ErrnoC, _ErrnoD>(
    '__errno_location',
  );

  int get errno => _errnoLocation().value;
}

final _libc = _Libc();

void _close(int fd) => _libc.closeFd(fd);

int _openSocket(_SocketKind kind, String address, int channel, int timeoutMs) {
  final isSdp = kind == _SocketKind.l2cap;
  final fd = _libc.socket(
    _afBluetooth,
    isSdp ? _sockSeqpacket : _sockStream,
    isSdp ? _btprotoL2cap : _btprotoRfcomm,
  );
  if (fd < 0) {
    throw SppTransportException(
      'socket',
      'could not open Bluetooth socket',
      errno: _libc.errno,
    );
  }
  try {
    final size = isSdp ? 14 : 10;
    final addr = calloc<Uint8>(size);
    try {
      final local = addr.asTypedList(size);
      local[0] = _afBluetooth;
      if (_libc.bind(fd, addr, size) < 0) {
        throw SppTransportException(
          'bind',
          'could not bind Bluetooth socket',
          errno: _libc.errno,
        );
      }
      final flags = _libc.fcntl(fd, _fGetfl, 0);
      if (flags < 0 || _libc.fcntl(fd, _fSetfl, flags | _oNonblock) < 0) {
        throw SppTransportException(
          'fcntl',
          'could not make the socket non-blocking',
          errno: _libc.errno,
        );
      }
      local.fillRange(0, size, 0);
      local[0] = _afBluetooth;
      local.setAll(isSdp ? 4 : 2, bdaddrBytes(address));
      if (isSdp) {
        local[2] = channel & 0xff;
        local[3] = (channel >> 8) & 0xff;
      } else {
        local[8] = channel;
      }
      if (_libc.connect(fd, addr, size) < 0) {
        final error = _libc.errno;
        if (error != _einprogress) {
          throw SppTransportException(
            'connect',
            'could not connect to the printer',
            errno: error,
          );
        }
        _wait(fd, _pollout, timeoutMs);
      }
      _libc.fcntl(fd, _fSetfl, flags);
      return fd;
    } finally {
      calloc.free(addr);
    }
  } on Object {
    _close(fd);
    rethrow;
  }
}

void _wait(int fd, int events, int timeoutMs) {
  final pfd = calloc<Uint8>(8);
  try {
    final view = ByteData.sublistView(pfd.asTypedList(8))
      ..setInt32(0, fd, Endian.host)
      ..setInt16(4, events, Endian.host);
    final clock = Stopwatch()..start();
    while (true) {
      final left = timeoutMs - clock.elapsedMilliseconds;
      if (left <= 0) {
        throw const SppTransportException(
          'connect',
          'Bluetooth connect timed out',
          errno: _etimedout,
        );
      }
      final rc = _libc.poll(pfd, 1, left);
      if (rc < 0 && _libc.errno == _eintr) continue;
      if (rc < 0) {
        throw SppTransportException(
          'poll',
          'Bluetooth wait failed',
          errno: _libc.errno,
        );
      }
      if (rc == 0) {
        throw const SppTransportException(
          'connect',
          'Bluetooth connect timed out',
          errno: _etimedout,
        );
      }
      final revents = view.getUint16(6, Endian.host);
      if (revents & (_pollerr | _pollhup) != 0) {
        throw const SppTransportException(
          'connect',
          'the printer dropped the connection',
        );
      }
      return;
    }
  } finally {
    calloc.free(pfd);
  }
}

void _writeAll(int fd, List<int> bytes, int Function() left) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final buffer = calloc<Uint8>(data.length);
  try {
    buffer.asTypedList(data.length).setAll(0, data);
    var offset = 0;
    while (offset < data.length) {
      _wait(fd, _pollout, left());
      final sent = _libc.send(
        fd,
        buffer + offset,
        data.length - offset,
        _msgDontwait | _msgNosignal,
      );
      if (sent < 0) {
        final error = _libc.errno;
        if (error == _eagain || error == _eintr) continue;
        throw SppTransportException(
          'send',
          'could not write to the printer',
          errno: error,
        );
      }
      offset += sent;
    }
  } finally {
    calloc.free(buffer);
  }
}

Uint8List _readSome(int fd, int Function() left) {
  final buffer = calloc<Uint8>(4096);
  try {
    _wait(fd, _pollin, left());
    final count = _libc.recv(fd, buffer, 4096, _msgDontwait);
    if (count < 0) {
      final error = _libc.errno;
      throw SppTransportException(
        'recv',
        'could not read from the printer',
        errno: error,
      );
    }
    if (count == 0) {
      throw const SppTransportException(
        'recv',
        'the printer closed the connection',
      );
    }
    return Uint8List.fromList(buffer.asTypedList(count));
  } finally {
    calloc.free(buffer);
  }
}
