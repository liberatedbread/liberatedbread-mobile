// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The ATT bearer as a byte pipe: one PDU in, one PDU out, plus "the link is
// gone". [AttChannel] is the seam the client is tested through (a fake
// channel scripts a peripheral); [L2capAttChannel] is the production one on
// Linux — an L2CAP socket on the ATT fixed channel (CID 4), opened directly
// with the kernel and never touched by bluetoothd.
//
// WHY A RAW SOCKET EXISTS IN A FLUTTER APP
//
// bluetoothd's GATT client sends, before any service discovery, a Read By
// Type for Server Supported Features (0x2b3a) over the whole handle range.
// Some peripherals (the Johnson LDM330 laser meter, 2026-09) answer that
// with silence instead of an ATT error; bluetoothd waits out the 30 s ATT
// transaction timeout, tears the link down as the spec requires, and reports
// the device with no services. The BlueZ maintainers have declined to relax
// that (they consider the peripheral non-compliant, which it is), so every
// client layered on bluetoothd — flutter_blue_plus_linux included — cannot
// use such a device at all. The kernel lets an unprivileged process open the
// ATT channel itself; bluetoothd then sees the connection but attaches no
// GATT client to it ("client fixed channels should override server ones",
// net/bluetooth/l2cap_core.c), so this bearer is ours alone.
//
// The socket work runs on a worker isolate because `connect` and the wait
// for the peer's next PDU block, and Dart's own sockets do not speak
// AF_BLUETOOTH. That wait is a poll(), never a blocking recv() — see
// runL2capReceiveLoop for the two ways a sleeping recv breaks this socket.
// Writes, the security socket options and the shutdown() behind cancel and
// close go straight to the file descriptor from the calling isolate — a
// descriptor is process-wide, and each is a plain syscall. Only the worker
// ever closes it, and only after this isolate has acknowledged the worker's
// last report (see _l2capWorker), so nothing here can touch a number
// already reused.
//
// Holding the ATT channel also means nobody else answers the PEER's ATT
// requests on this link — bluetoothd's GATT server is not attached — which
// is why AttClient carries a minimal server of its own.

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A connected ATT bearer.
abstract class AttChannel {
  /// PDUs from the peer, one per event, in arrival order. Closes when the
  /// link is gone.
  Stream<Uint8List> get incoming;

  /// Completes when the link is gone, however that happened.
  Future<void> get closed;

  /// Whether [send] can still reach the peer.
  bool get isOpen;

  /// Hand one PDU to the peer. Throws [AttChannelException] when the link
  /// is already gone.
  void send(Uint8List pdu);

  /// Tear the link down. Idempotent.
  Future<void> close();

  /// The errno the link died with, when it died on its own: null while it
  /// is open, and null after [close] (we ended it; there is nothing to
  /// report). 0 when the kernel ended it without naming a reason.
  int? get closeErrno;

  /// The link's current security level, in the kernel's BT_SECURITY terms:
  /// 1 low (unencrypted), 2 medium (encrypted, unauthenticated), 3 high
  /// (encrypted with MITM protection), 4 FIPS (LE Secure Connections).
  int get securityLevel;

  /// Raise the link to at least [level] (see [securityLevel]): encrypt with
  /// a stored key, or pair. Completes true once [securityLevel] >= [level],
  /// false when it could not — the peer or the local agent refused, nothing
  /// happened within [timeout], or the link went away. Never throws for
  /// those outcomes.
  ///
  /// When the attempt got under way and failed, the channel is closing
  /// ([isOpen] false) by the time this completes false: the kernel leaves a
  /// socket whose elevation failed without a disconnect stuck refusing every
  /// send (see L2capAttChannel.elevateSecurity). One refused before it
  /// began — the kernel turning the request down at once — leaves the link
  /// as it was.
  ///
  /// Only ever on the peer's say-so (an ATT error asking for it): some
  /// peripherals support no LE encryption at all, and asking one to pair
  /// ends with the kernel dropping the link.
  Future<bool> elevateSecurity(
    int level, {
    Duration timeout = const Duration(seconds: 30),
  });
}

/// Opens [AttChannel]s to peripherals by address.
abstract class AttChannelFactory {
  /// Connect to [address] (`AA:BB:CC:DD:EE:FF`), a public address unless
  /// [randomAddress]. Throws [AttChannelException] when the link cannot be
  /// established within [timeout].
  ///
  /// [cancel]: when it completes before the link is up, the attempt is
  /// aborted and this throws an [AttChannelException] at stage `connect`
  /// with errno [AttErrno.ecanceled]. Completing it later does nothing.
  Future<AttChannel> connect(
    String address, {
    required bool randomAddress,
    Duration timeout = const Duration(seconds: 15),
    Future<void>? cancel,
  });
}

/// The Linux errnos a caller of [AttChannelFactory.connect] can act on
/// (asm-generic/errno.h). What each one means on THIS path is from the
/// kernel's l2cap_chan_connect and its connect-timeout handling.
abstract final class AttErrno {
  /// Encryption or pairing was refused and the kernel dropped the link.
  static const int eacces = 13;

  /// Something (bluetoothd, as a rule) already holds the ATT channel on a
  /// link to this peer. It is released when that owner lets go.
  static const int ebusy = 16;

  /// The request went to the peer as the wrong address type, or the peer
  /// did not advertise within the socket's own timeout.
  static const int econnrefused = 111;

  /// The LE create-connection timed out, or [AttChannelFactory.connect]'s
  /// own timeout ran out first.
  static const int etimedout = 110;

  /// The link failed while connecting without the kernel naming a reason.
  static const int econnaborted = 103;

  /// The attempt was cancelled by the caller.
  static const int ecanceled = 125;

  /// What [AttChannel.send] fails with while the kernel raises the link's
  /// security (the socket is in BT_CONFIG until pairing ends, or until the
  /// peer next sends anything). The link itself is fine.
  static const int enotconn = 107;
}

/// The bearer could not be opened or has failed.
class AttChannelException implements Exception {
  /// What was being attempted: `socket`, `bind`, `connect`, `send`...
  final String stage;

  /// The errno, when the OS gave one.
  final int? errno;

  final String message;

  const AttChannelException(this.stage, this.message, {this.errno});

  /// Whether another owner holds the ATT channel on the link (EBUSY): the
  /// one failure worth retrying once that owner has been asked to let go.
  bool get isBusy => errno == AttErrno.ebusy;

  /// Whether the attempt was cancelled by the caller (ECANCELED).
  bool get isCanceled => errno == AttErrno.ecanceled;

  @override
  String toString() =>
      'AttChannelException($stage): $message'
      '${errno == null ? '' : ' (errno $errno)'}';
}

/// The six bytes of a `AA:BB:CC:DD:EE:FF` address in the little-endian
/// order the kernel's `bdaddr_t` wants.
Uint8List bdaddrBytes(String address) {
  final parts = address.split(':');
  if (parts.length != 6) {
    throw ArgumentError.value(address, 'address', 'not a Bluetooth address');
  }
  final bytes = Uint8List(6);
  for (var i = 0; i < 6; i++) {
    final octet = int.tryParse(parts[i], radix: 16);
    if (octet == null || parts[i].length != 2) {
      throw ArgumentError.value(address, 'address', 'not a Bluetooth address');
    }
    bytes[5 - i] = octet;
  }
  return bytes;
}

// Kernel constants (linux/socket.h, bluetooth/bluetooth.h, bluetooth/l2cap.h).
const int _afBluetooth = 31;
const int _sockSeqpacket = 5;
const int _btprotoL2cap = 0;
const int _solBluetooth = 274;
const int _btSecurity = 4;
const int _bdaddrLePublic = 1;
const int _bdaddrLeRandom = 2;
const int _l2capCidAtt = 4;
const int _sockaddrL2Size = 14;
const int _solSocket = 1;
const int _soError = 4;
const int _fGetfl = 3;
const int _fSetfl = 4;
const int _oNonblock = 0x800;
const int _pollin = 0x1;
const int _pollout = 0x4;
const int _pollerr = 0x8;
const int _pollhup = 0x10;
const int _pollnval = 0x20;
const int _pollrdhup = 0x2000;
const int _msgDontwait = 0x40;
const int _msgNosignal = 0x4000;
const int _shutRdwr = 2;
const int _einprogress = 115;
const int _eintr = 4;
const int _eagain = 11;
const int _einval = 22;

/// The poll() bits that mean the socket is finished: an error is pending
/// (POLLERR — the kernel's teardown sets one with the link's reason), the
/// channel closed or both directions shut down (POLLHUP), the receive side
/// shut down (POLLRDHUP), or no socket at all (POLLNVAL). The kernel
/// reports all but POLLRDHUP whether asked or not.
const int _hangUp = _pollerr | _pollhup | _pollrdhup | _pollnval;

/// One ATT PDU per recv on a SOCK_SEQPACKET socket; sized above the
/// channel's 672-byte receive MTU, so nothing is ever truncated.
const int _recvBufferSize = 1024;

/// The largest ATT MTU (Vol 3 Part F, 3.2.8): what the client offers in the
/// MTU exchange. No socket option is needed to receive PDUs this big — the
/// kernel's ATT fixed channel already has a 672-byte receive MTU; the ATT
/// MTU itself is negotiated only by the Exchange MTU PDUs.
const int attMaxMtu = 517;

typedef _SocketC = Int32 Function(Int32, Int32, Int32);
typedef _SocketD = int Function(int, int, int);
typedef _SockaddrC = Int32 Function(Int32, Pointer<Uint8>, Uint32);
typedef _SockaddrD = int Function(int, Pointer<Uint8>, int);
typedef _SetsockoptC =
    Int32 Function(Int32, Int32, Int32, Pointer<Uint8>, Uint32);
typedef _SetsockoptD = int Function(int, int, int, Pointer<Uint8>, int);
typedef _GetsockoptC =
    Int32 Function(Int32, Int32, Int32, Pointer<Uint8>, Pointer<Uint32>);
typedef _GetsockoptD =
    int Function(int, int, int, Pointer<Uint8>, Pointer<Uint32>);
typedef _IoC = IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int32);
typedef _IoD = int Function(int, Pointer<Uint8>, int, int);
typedef _FdIntC = Int32 Function(Int32, Int32);
typedef _FdIntD = int Function(int, int);
typedef _FcntlC = Int32 Function(Int32, Int32, VarArgs<(Int32,)>);
typedef _FcntlD = int Function(int, int, int);
typedef _PollC = Int32 Function(Pointer<Uint8>, UintPtr, Int32);
typedef _PollD = int Function(Pointer<Uint8>, int, int);
typedef _FdC = Int32 Function(Int32);
typedef _FdD = int Function(int);
typedef _ErrnoC = Pointer<Int32> Function();
typedef _ErrnoD = Pointer<Int32> Function();

/// libc entry points, looked up once per isolate.
class _Libc {
  final DynamicLibrary _lib = DynamicLibrary.process();
  late final socket = _lib.lookupFunction<_SocketC, _SocketD>('socket');
  late final bind = _lib.lookupFunction<_SockaddrC, _SockaddrD>('bind');
  late final connect = _lib.lookupFunction<_SockaddrC, _SockaddrD>('connect');
  late final setsockopt = _lib.lookupFunction<_SetsockoptC, _SetsockoptD>(
    'setsockopt',
  );
  late final getsockopt = _lib.lookupFunction<_GetsockoptC, _GetsockoptD>(
    'getsockopt',
  );
  late final send = _lib.lookupFunction<_IoC, _IoD>('send');
  late final recv = _lib.lookupFunction<_IoC, _IoD>('recv');
  late final shutdown = _lib.lookupFunction<_FdIntC, _FdIntD>('shutdown');
  late final fcntl = _lib.lookupFunction<_FcntlC, _FcntlD>('fcntl');
  late final poll = _lib.lookupFunction<_PollC, _PollD>('poll');
  late final close = _lib.lookupFunction<_FdC, _FdD>('close');
  late final _errnoLocation = _lib.lookupFunction<_ErrnoC, _ErrnoD>(
    '__errno_location',
  );

  int get errno => _errnoLocation().value;

  /// getsockopt(SOL_BLUETOOTH, BT_SECURITY): the link's level, or null when
  /// the call fails. struct bt_security is {u8 level; u8 key_size}.
  int? securityLevel(int fd) {
    final sec = calloc<Uint8>(2);
    final len = calloc<Uint32>()..value = 2;
    try {
      if (getsockopt(fd, _solBluetooth, _btSecurity, sec, len) < 0) {
        return null;
      }
      return sec[0];
    } finally {
      calloc.free(sec);
      calloc.free(len);
    }
  }

  /// setsockopt(SOL_BLUETOOTH, BT_SECURITY, {level, key_size: 0}): 0, or the
  /// errno it failed with.
  int requestSecurity(int fd, int level) {
    final sec = calloc<Uint8>(2);
    try {
      sec[0] = level;
      sec[1] = 0;
      return setsockopt(fd, _solBluetooth, _btSecurity, sec, 2) < 0 ? errno : 0;
    } finally {
      calloc.free(sec);
    }
  }
}

/// What the worker isolate is told to open — or, with [adoptedFd], the
/// already-connected socket it takes over instead ([L2capAttChannel.adopt]).
class _WorkerConfig {
  final SendPort toMain;
  final Uint8List bdaddr;
  final int addressType;
  final int timeoutMs;
  final int? adoptedFd;
  const _WorkerConfig(
    this.toMain,
    this.bdaddr,
    this.addressType,
    this.timeoutMs, {
    this.adoptedFd,
  });
}

/// Worker isolate body: open the socket, connect, then run the receive loop
/// until the link closes. Every outcome is reported to the main isolate as a
/// list whose first element names it:
///
///   ['fd', fd, SendPort]   right after socket(), so the main isolate can
///                          abort a connect in flight with shutdown()
///   ['connected']          the link is up
///   ['data', Uint8List]    one PDU from the peer
///   ['closed', errno]      the socket hung up (errno: what it ended with,
///                          0 for no reason given)
///   ['error', stage, errno] the socket could not be opened or connected
///
/// THE DESCRIPTOR IS CLOSED HERE AND NOWHERE ELSE, and only once the main
/// isolate has answered the final report ('closed' or 'error') with a
/// release message. Until it has seen that report the main isolate may
/// still call shutdown() or send() on the descriptor — to cancel, to close,
/// to write — and a descriptor number closed under it could by then belong
/// to anything else the process opened. The release wait is bounded so a
/// main isolate that has gone away cannot pin the socket.
Future<void> _l2capWorker(_WorkerConfig config) async {
  final libc = _Libc();
  final out = config.toMain;
  final adopted = config.adoptedFd;

  final fd =
      adopted ?? libc.socket(_afBluetooth, _sockSeqpacket, _btprotoL2cap);
  if (fd < 0) {
    out.send(['error', 'socket', libc.errno]);
    return;
  }
  final fromMain = ReceivePort();
  out.send(['fd', fd, fromMain.sendPort]);

  Future<void> releaseAndClose() async {
    final released = Completer<void>();
    fromMain.listen((_) {
      if (!released.isCompleted) released.complete();
    });
    await released.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    fromMain.close();
    libc.close(fd);
  }

  if (adopted == null) {
    final failure = _connectSocket(libc, fd, config);
    if (failure != null) {
      out.send(['error', failure.stage, failure.errno]);
      return releaseAndClose();
    }
  }
  out.send(['connected']);

  final socket = _LibcRxSocket(libc, fd);
  final int closeErrno;
  try {
    closeErrno = runL2capReceiveLoop(socket, (pdu) => out.send(['data', pdu]));
  } finally {
    socket.dispose();
  }
  out.send(['closed', closeErrno]);
  return releaseAndClose();
}

/// The three syscalls [runL2capReceiveLoop] makes on the ATT socket. An
/// interface only so the loop's handling of the kernel's corner cases runs
/// in unit tests against a script; production's is a thin libc wrapper.
abstract class L2capRxSocket {
  /// poll() the socket for POLLIN | POLLRDHUP — the kernel adds POLLERR,
  /// POLLHUP and POLLNVAL unasked — waiting up to [timeoutMs] (-1: until
  /// something happens). The revents (0 when the wait ran out), or minus
  /// the errno when poll itself failed.
  int poll(int timeoutMs);

  /// One recv(MSG_DONTWAIT): the datagram (empty when the kernel returned
  /// 0), or a null pdu and the errno it failed with.
  ({Uint8List? pdu, int errno}) recv();

  /// getsockopt(SO_ERROR): the error the socket holds, 0 for none. Reading
  /// it clears it.
  int socketError();
}

/// The ATT socket's receive loop, as the worker isolate runs it: hand each
/// PDU from the peer to [onPdu] until the socket is finished, then return
/// the errno it ended with (0: none named). Public only so its corner cases
/// are unit tested (test/services/direct_att/att_channel_test.dart).
///
/// IT WAITS IN poll(), NEVER IN recv(). A recv() that sleeps goes wrong on
/// this socket twice over:
///
///  * While pairing runs the socket is in BT_CONFIG, and the kernel's
///    datagram wait (__skb_wait_for_more_packets) fails a connection-based
///    socket that is not connected with ENOTCONN each time it wakes. The
///    worker is woken constantly — debug, profile and `flutter test` runs
///    deliver SIGPROF about every millisecond — so the link would be torn
///    down the moment a peer asked for encryption.
///  * On kernels whose bt_sock_recvmsg holds lock_sock across that wait
///    (v6.7, v6.8.0-6.8.1, 6.6.9-6.6.22, 6.1.70-6.1.82; fixed by
///    f7b94bdc1ec1), a sleeping recv owns the socket lock: this isolate's
///    send, shutdown and getsockopt — and the adapter's RX work, and with
///    it every HCI event — queue behind it until the peer sends something.
///
/// bt_sock_poll takes no lock, and in BT_CONFIG reports nothing but the
/// error and hang-up bits, so it just keeps waiting through a pairing. A
/// MSG_DONTWAIT recv holds the lock for microseconds and, with nothing
/// queued, answers EAGAIN before any state check.
///
/// The END is decided by poll's hang-up bits, never by recv returning 0: a
/// peer can send a zero-length frame on the ATT channel, which the kernel
/// queues as an empty datagram — nothing to deliver, but not the link
/// ending either. On a hang-up the error the kernel's teardown left in
/// SO_ERROR is the reason, as a blocking recv would have returned it
/// (sock_error comes before the queue there too).
int runL2capReceiveLoop(
  L2capRxSocket socket,
  void Function(Uint8List pdu) onPdu,
) {
  while (true) {
    final revents = socket.poll(-1);
    if (revents < 0) {
      if (revents == -_eintr) continue;
      return -revents;
    }
    if (revents & _hangUp != 0) return socket.socketError();
    final got = socket.recv();
    final pdu = got.pdu;
    if (pdu != null) {
      if (pdu.isNotEmpty) onPdu(pdu);
      continue;
    }
    switch (got.errno) {
      case _eagain || _eintr:
        continue;
      case AttErrno.enotconn:
        // Not connected, yet poll saw no hang-up: BT_CONFIG, a pairing in
        // progress, on a kernel whose non-blocking read still checks the
        // state. Wait on — unless the link went in the meantime, when the
        // ENOTCONN may itself have been the teardown's error (recv reads
        // and clears it), so it is the reason if SO_ERROR has none.
        final now = socket.poll(0);
        if (now > 0 && now & _hangUp != 0) {
          final error = socket.socketError();
          return error != 0 ? error : AttErrno.enotconn;
        }
        continue;
      default:
        return got.errno;
    }
  }
}

/// [L2capRxSocket] over a real descriptor, with the pollfd and the receive
/// buffer allocated once for the life of the loop.
final class _LibcRxSocket implements L2capRxSocket {
  final _Libc _libc;
  final int _fd;
  // struct pollfd { int fd; short events; short revents; }
  final Pointer<Uint8> _pfd = calloc<Uint8>(8);
  final Pointer<Uint8> _buf = calloc<Uint8>(_recvBufferSize);
  late final ByteData _pollfd = ByteData.sublistView(_pfd.asTypedList(8));

  _LibcRxSocket(this._libc, this._fd) {
    _pollfd
      ..setInt32(0, _fd, Endian.host)
      ..setInt16(4, _pollin | _pollrdhup, Endian.host);
  }

  @override
  int poll(int timeoutMs) {
    final rc = _libc.poll(_pfd, 1, timeoutMs);
    if (rc < 0) return -_libc.errno;
    return rc == 0 ? 0 : _pollfd.getUint16(6, Endian.host);
  }

  @override
  ({Uint8List? pdu, int errno}) recv() {
    final n = _libc.recv(_fd, _buf, _recvBufferSize, _msgDontwait);
    if (n < 0) return (pdu: null, errno: _libc.errno);
    return (pdu: Uint8List.fromList(_buf.asTypedList(n)), errno: 0);
  }

  @override
  int socketError() => _socketError(_libc, _fd);

  void dispose() {
    calloc.free(_pfd);
    calloc.free(_buf);
  }
}

/// bind + a non-blocking connect with OUR timeout rather than the kernel's
/// (SO_SNDTIMEO, 40 s by default), then back to blocking — which the main
/// isolate's send() relies on: a full send buffer waits rather than failing
/// with EAGAIN. (The receive loop reads with MSG_DONTWAIT regardless.) Null
/// on success, else what failed.
({String stage, int errno})? _connectSocket(
  _Libc libc,
  int fd,
  _WorkerConfig config,
) {
  final addr = calloc<Uint8>(_sockaddrL2Size);
  try {
    // struct sockaddr_l2 { sa_family_t family; __le16 psm; bdaddr_t bdaddr;
    // __le16 cid; __u8 bdaddr_type; } — 14 bytes, bdaddr at 4, cid at 10,
    // type at 12.
    //
    // bind: our adapter (BDADDR_ANY), CID 4, LE public source type. The
    // source type has to be LE for the kernel to treat this as an ATT
    // bearer; the peer's type goes in the connect address below.
    final bindAddr = addr.asTypedList(_sockaddrL2Size)..fillRange(0, 14, 0);
    bindAddr[0] = _afBluetooth;
    bindAddr[10] = _l2capCidAtt;
    bindAddr[12] = _bdaddrLePublic;
    if (libc.bind(fd, addr, _sockaddrL2Size) < 0) {
      return (stage: 'bind', errno: libc.errno);
    }

    final flags = libc.fcntl(fd, _fGetfl, 0);
    libc.fcntl(fd, _fSetfl, flags | _oNonblock);
    final peer = addr.asTypedList(_sockaddrL2Size)..fillRange(0, 14, 0);
    peer[0] = _afBluetooth;
    peer.setAll(4, config.bdaddr);
    peer[10] = _l2capCidAtt;
    peer[12] = config.addressType;
    if (libc.connect(fd, addr, _sockaddrL2Size) < 0) {
      final errno = libc.errno;
      if (errno != _einprogress) return (stage: 'connect', errno: errno);
      final failure = _awaitConnected(libc, fd, config.timeoutMs);
      if (failure != null) return (stage: 'connect', errno: failure);
    }
    libc.fcntl(fd, _fSetfl, flags);
    return null;
  } finally {
    calloc.free(addr);
  }
}

/// Wait up to [timeoutMs] for a non-blocking connect to finish: null once
/// the link is up, else the errno. A shutdown() from the main isolate (a
/// cancel) ends the wait with POLLHUP and no socket error.
int? _awaitConnected(_Libc libc, int fd, int timeoutMs) {
  // struct pollfd { int fd; short events; short revents; }
  final pfd = calloc<Uint8>(8);
  try {
    final view = ByteData.sublistView(pfd.asTypedList(8))
      ..setInt32(0, fd, Endian.host)
      ..setInt16(4, _pollout, Endian.host);
    final clock = Stopwatch()..start();
    int rc;
    while (true) {
      final left = timeoutMs - clock.elapsedMilliseconds;
      if (left <= 0) return AttErrno.etimedout;
      rc = libc.poll(pfd, 1, left);
      if (rc < 0 && libc.errno == _eintr) continue;
      break;
    }
    if (rc == 0) return AttErrno.etimedout;
    if (rc < 0) return libc.errno;
    final revents = view.getInt16(6, Endian.host);
    final soError = _socketError(libc, fd);
    if (soError != 0) return soError;
    if (revents & (_pollerr | _pollhup) != 0) return AttErrno.econnaborted;
    return null;
  } finally {
    calloc.free(pfd);
  }
}

int _socketError(_Libc libc, int fd) {
  final err = calloc<Uint8>(4);
  final len = calloc<Uint32>()..value = 4;
  try {
    libc.getsockopt(fd, _solSocket, _soError, err, len);
    return ByteData.sublistView(err.asTypedList(4)).getInt32(0, Endian.host);
  } finally {
    calloc.free(err);
    calloc.free(len);
  }
}

/// An ATT bearer over a Linux L2CAP socket. See the file comment.
class L2capAttChannel implements AttChannel {
  final int _fd;
  final Isolate _worker;
  final ReceivePort _port;
  final SendPort _workerPort;
  final _Libc _libc = _Libc();
  final _incoming = StreamController<Uint8List>();
  final _closed = Completer<void>();

  /// Whether sends may still go out: false from the moment [close] starts,
  /// or a failed send found the socket finished (see [send]).
  bool _open = true;

  /// Whether the worker has reported the end. From then on the descriptor
  /// is the worker's to close, and this isolate must not touch it.
  bool _finished = false;
  bool _closing = false;

  /// Whether [close] is what ended the link — it was still up when close
  /// began — so there is no reason to report (see [closeErrno]).
  bool _closedByUs = false;
  int? _closeErrno;

  L2capAttChannel._(this._fd, this._worker, this._port, this._workerPort);

  /// How often [elevateSecurity] re-reads the level while pairing runs.
  static const Duration securityPollInterval = Duration(milliseconds: 100);

  /// Open the ATT channel to [address]. See [AttChannelFactory.connect].
  static Future<L2capAttChannel> connect(
    String address, {
    required bool randomAddress,
    Duration timeout = const Duration(seconds: 15),
    Future<void>? cancel,
  }) async {
    _ensureLinux();
    final bdaddr = bdaddrBytes(address);
    return _start(
      address,
      (toMain) => _WorkerConfig(
        toMain,
        bdaddr,
        randomAddress ? _bdaddrLeRandom : _bdaddrLePublic,
        timeout.inMilliseconds,
      ),
      cancel: cancel,
    );
  }

  /// Take over [fd], an already-connected SOCK_SEQPACKET socket, as if
  /// [connect] had just opened it: the worker, its receive loop and the
  /// descriptor hand-offs are exactly the production ones, and the worker
  /// closes [fd] when the channel ends. Production opens channels with
  /// [connect]; this exists so that machinery runs in `flutter test` over a
  /// Unix socketpair, with no adapter. (There the Bluetooth socket options
  /// fail: the level reads as 1, and [elevateSecurity] is false.)
  static Future<L2capAttChannel> adopt(int fd) async {
    _ensureLinux();
    return _start(
      'fd $fd',
      (toMain) => _WorkerConfig(toMain, Uint8List(0), 0, 0, adoptedFd: fd),
    );
  }

  static void _ensureLinux() {
    if (!Platform.isLinux) {
      throw const AttChannelException(
        'socket',
        'direct ATT channels exist only on Linux',
      );
    }
  }

  static Future<L2capAttChannel> _start(
    String address,
    _WorkerConfig Function(SendPort toMain) config, {
    Future<void>? cancel,
  }) async {
    final port = ReceivePort();
    final result = Completer<L2capAttChannel>();
    final libc = _Libc();
    L2capAttChannel? channel;
    int? fd;
    SendPort? workerPort;
    var cancelled = false;

    // Everything after the worker's final report goes through here: tell it
    // the descriptor is its to close, and stop listening.
    void release() {
      workerPort?.send('release');
      port.close();
    }

    void onCancel() {
      if (result.isCompleted || cancelled) return;
      cancelled = true;
      // Safe: the worker has not closed the descriptor — it waits for our
      // release, which only follows its final report. shutdown() ends the
      // connect's poll (POLLHUP) and the kernel drops the pending LE
      // connection with the channel. Before the 'fd' report there is no
      // descriptor yet; that handler shuts it down on arrival.
      if (fd != null) libc.shutdown(fd!, _shutRdwr);
    }

    final Isolate worker;
    try {
      // Spawned paused so the exit listener is in place before the worker
      // can possibly exit; on the SAME port, so it queues behind the
      // worker's own reports.
      worker = await Isolate.spawn(
        _l2capWorker,
        config(port.sendPort),
        paused: true,
        debugName: 'att-l2cap $address',
      );
    } catch (e) {
      port.close();
      throw AttChannelException('socket', 'could not start the ATT worker: $e');
    }
    worker.addOnExitListener(port.sendPort, response: const ['exit']);
    if (cancel != null) {
      unawaited(
        cancel.then<void>((_) => onCancel(), onError: (Object _) => onCancel()),
      );
    }

    port.listen((Object? message) {
      if (message is! List<Object?> || message.isEmpty) return;
      switch (message[0]) {
        case 'fd':
          fd = message[1]! as int;
          workerPort = message[2]! as SendPort;
          if (cancelled) libc.shutdown(fd!, _shutRdwr);
        case 'connected':
          if (cancelled) {
            // The link came up in the same instant the cancel shut the
            // socket down; the worker's poll sees that and reports
            // 'closed', which releases it. The caller asked for no link.
            result.completeError(_cancelled(address));
            return;
          }
          channel = L2capAttChannel._(fd!, worker, port, workerPort!);
          result.complete(channel);
        case 'data':
          channel?._incoming.add(message[1]! as Uint8List);
        case 'closed':
          final open = channel;
          if (open != null) {
            open._onClosed(message[1] as int?);
          } else {
            release();
          }
        case 'error':
          release();
          result.completeError(
            cancelled
                ? _cancelled(address)
                : AttChannelException(
                    message[1]! as String,
                    'could not open ATT channel to $address',
                    errno: message[2]! as int,
                  ),
          );
        case 'exit':
          // The worker died without its final report (it should never: a
          // report always queues ahead of the exit, and handling it closes
          // this port). So it never closed the descriptor; reclaim it.
          port.close();
          final open = channel;
          if (open != null) {
            open._onClosed(null, workerGone: true);
            return;
          }
          if (fd != null) libc.close(fd!);
          if (!result.isCompleted) {
            result.completeError(
              AttChannelException(
                'connect',
                'the ATT worker for $address exited unexpectedly',
              ),
            );
          }
      }
    });
    worker.resume(worker.pauseCapability!);
    return result.future;
  }

  static AttChannelException _cancelled(String address) => AttChannelException(
    'connect',
    'connect to $address cancelled',
    errno: AttErrno.ecanceled,
  );

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isOpen => _open;

  @override
  int? get closeErrno => _closeErrno;

  @override
  int get securityLevel => _finished ? 1 : (_libc.securityLevel(_fd) ?? 1);

  @override
  Future<bool> elevateSecurity(
    int level, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (level < 1 || level > 4) {
      throw ArgumentError.value(level, 'level', 'must be 1..4');
    }
    if (!_open) return false;
    // Compare first, as bluetoothd does: the kernel refuses an upgrade the
    // link already satisfies with EINVAL rather than succeeding.
    if (securityLevel >= level) return true;
    final errno = _libc.requestSecurity(_fd, level);
    if (errno != 0) {
      // EINVAL also means "already sufficient" when a concurrent upgrade
      // finished in between; anything else is a refusal.
      return errno == _einval && securityLevel >= level;
    }
    // The setsockopt returned at once and moved the socket to BT_CONFIG
    // while SMP runs (sends fail with ENOTCONN until it ends; the receive
    // loop's poll just keeps waiting). Completion is only visible in
    // getsockopt(BT_SECURITY), which reports the level the link actually
    // reached — POLLOUT is not a signal: any PDU from the peer flips the
    // socket back to connected mid-pairing. A refusal on OUR side (no
    // agent, or the user said no) fails SMP without dropping the link or
    // resuming the socket, hence the timeout.
    final clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      await Future.any([Future<void>.delayed(securityPollInterval), closed]);
      if (!_open || _finished) return false;
      if (securityLevel >= level) return true;
    }
    // Given up. If the socket is still in BT_CONFIG, the kernel offers no
    // way out: nothing resumes it but encryption succeeding after all or
    // the peer happening to send a PDU, and until then every send fails
    // with ENOTCONN on a link that looks connected. A closed link is a
    // disconnect every layer above already handles, and the app can
    // reconnect and pair; a wedged one is not. But a PDU from the peer may
    // already have resumed it (l2cap_chan_ready runs for any frame on the
    // fixed channel), and then the link works at its old level: leave it.
    if (_stillConfiguring()) unawaited(close());
    return false;
  }

  /// Whether the socket is stuck in BT_CONFIG: bt_sock_poll reports neither
  /// POLLOUT nor a hang-up there (it returns early), while a resumed socket
  /// is writable and a finished one hangs up.
  bool _stillConfiguring() {
    if (!_open || _finished) return false;
    final pfd = calloc<Uint8>(8);
    try {
      final view = ByteData.sublistView(pfd.asTypedList(8))
        ..setInt32(0, _fd, Endian.host)
        ..setInt16(4, _pollout, Endian.host);
      if (_libc.poll(pfd, 1, 0) < 0) return false;
      final revents = view.getUint16(6, Endian.host);
      return revents & (_pollout | _pollhup | _pollerr) == 0;
    } finally {
      calloc.free(pfd);
    }
  }

  @override
  void send(Uint8List pdu) {
    if (!_open) {
      throw const AttChannelException('send', 'ATT channel is closed');
    }
    final buf = calloc<Uint8>(pdu.length);
    try {
      buf.asTypedList(pdu.length).setAll(0, pdu);
      var n = _libc.send(_fd, buf, pdu.length, _msgNosignal);
      var errno = n < 0 ? _libc.errno : null;
      // A send waiting for buffer space is interrupted — not restarted —
      // by any signal, because the L2CAP socket has a send timeout (40 s)
      // and the kernel returns EINTR rather than restarting; the Dart
      // profiler's SIGPROF lands every millisecond in debug and profile
      // builds. A failed SEQPACKET send queues nothing, so sending the same
      // PDU again cannot duplicate it.
      while (n < 0 && errno == _eintr) {
        n = _libc.send(_fd, buf, pdu.length, _msgNosignal);
        errno = n < 0 ? _libc.errno : null;
      }
      if (n != pdu.length) {
        // A send fails the instant the kernel tears the channel down, turns
        // before the worker's report of it reaches this isolate. Ask the
        // socket whether it is finished, so [isOpen] tells the truth at
        // once and a caller reads this as a lost link rather than one
        // operation failing. A refusal while pairing runs (BT_CONFIG:
        // ENOTCONN, and no hang-up) leaves the link open. The worker still
        // owns the descriptor and still reports; only that report finishes
        // the channel.
        if (_hungUp()) _open = false;
        throw AttChannelException(
          'send',
          'short or failed send (${n < 0 ? -1 : n}/${pdu.length})',
          errno: errno,
        );
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// poll() with no events and no wait: whether the kernel reports this
  /// socket finished — POLLHUP (closed, or shut down both ways) or POLLERR
  /// (an error pending), both reported unasked. BT_CONFIG shows neither.
  bool _hungUp() {
    final pfd = calloc<Uint8>(8);
    try {
      final view = ByteData.sublistView(pfd.asTypedList(8))
        ..setInt32(0, _fd, Endian.host);
      if (_libc.poll(pfd, 1, 0) <= 0) return false;
      return view.getUint16(6, Endian.host) & (_pollhup | _pollerr) != 0;
    } finally {
      calloc.free(pfd);
    }
  }

  @override
  Future<void> close() async {
    if (_finished || _closing) return _closed.future;
    _closing = true;
    _closedByUs = _open;
    _open = false;
    // shutdown wakes the worker's poll with POLLHUP; the worker reports,
    // which runs _onClosed, which releases the worker to close the
    // descriptor. If it never reports (it should), the fallback below
    // reclaims everything after a grace period.
    _libc.shutdown(_fd, _shutRdwr);
    await _closed.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _worker.kill(priority: Isolate.immediate);
        _onClosed(null, workerGone: true);
      },
    );
  }

  /// The worker reported the end (or is gone, [workerGone]).
  void _onClosed(int? errno, {bool workerGone = false}) {
    if (_finished) return;
    _finished = true;
    _open = false;
    // A close() that began after a send had already found the link gone
    // did not end it, so the kernel's reason still stands.
    if (!_closedByUs) _closeErrno = errno ?? 0;
    if (workerGone) {
      _libc.close(_fd);
    } else {
      _workerPort.send('release');
    }
    _port.close();
    unawaited(_incoming.close());
    if (!_closed.isCompleted) _closed.complete();
  }
}

/// [AttChannelFactory] over [L2capAttChannel].
class L2capAttChannelFactory implements AttChannelFactory {
  const L2capAttChannelFactory();

  @override
  Future<AttChannel> connect(
    String address, {
    required bool randomAddress,
    Duration timeout = const Duration(seconds: 15),
    Future<void>? cancel,
  }) => L2capAttChannel.connect(
    address,
    randomAddress: randomAddress,
    timeout: timeout,
    cancel: cancel,
  );
}
