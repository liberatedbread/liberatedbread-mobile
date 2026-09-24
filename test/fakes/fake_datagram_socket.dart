// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A UDP socket for tests that behaves the way dart:io's does when a send is
// REFUSED — which is not the way a reader would guess, and not the way five
// commits on this repo guessed. `RawDatagramSocket.send` never throws:
// `_NativeSocket.send` catches the native error, returns 0, and a microtask
// later `reportError` delivers the SocketException on the socket's STREAM and
// closes the socket (socket_patch.dart). A try/catch around send() catches
// nothing. Every transport that must tell "this multicast group is refused
// on its own account" from "the OS refused the network" has to meet the
// refusal on the stream, and only a fake that puts it there can prove it did.
//
// Lives in fakes/ so the scan service's tests can bind it through the
// service's injectable binder in place of the real socket.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// What one `send()` asked for, in the order the transport asked, and when
/// (on [FakeDatagramSocket.clock]).
typedef SentDatagram = ({
  List<int> data,
  InternetAddress address,
  int port,
  Duration at,
});

class FakeDatagramSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  @override
  final InternetAddress address;
  @override
  final int port;

  /// Decides, per destination, whether a send is refused. Null refuses none.
  final bool Function(InternetAddress address, int port)? refuse;

  /// The errno the refusal carries. 65 is EHOSTUNREACH, which is what a
  /// denied Local Network permission on Apple looks like, and also what a
  /// multicast group with no route looks like — the two this fake exists to
  /// let a test tell apart by DESTINATION rather than by errno.
  final int refuseErrno;

  /// Called after each send the socket did not refuse, so a test can answer
  /// a probe on the socket it left from — the way a device on the network
  /// would — without watching the clock.
  void Function(FakeDatagramSocket socket, SentDatagram datagram)? onSend;

  final List<SentDatagram> sent = [];
  bool closed = false;

  /// One clock for sends and the listen, so a test can say which came first.
  final Stopwatch clock = Stopwatch()..start();

  /// When the transport subscribed to this socket's stream, or null if it
  /// never did. A transport that sleeps between its sends and only then
  /// listens has this AFTER its second send; one that listens from the first
  /// send has it before.
  Duration? listenedAt;

  final StreamController<RawSocketEvent> _events = StreamController();
  final Queue<Datagram> _inbox = Queue();

  FakeDatagramSocket({
    InternetAddress? address,
    this.port = 0,
    this.refuse,
    this.refuseErrno = 65,
  }) : address = address ?? InternetAddress.anyIPv4;

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenedAt ??= clock.elapsed;
    return _events.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    // `if (isClosing || isClosed) return 0;` — a closed socket swallows the
    // send silently, which is what the second attempt after a refusal meets.
    if (closed) return 0;
    sent.add((
      data: List.of(buffer),
      address: address,
      port: port,
      at: clock.elapsed,
    ));
    if (refuse?.call(address, port) ?? false) {
      scheduleMicrotask(() {
        if (closed) return;
        _events.addError(
          SocketException(
            'Send failed',
            osError: OSError('No route to host', refuseErrno),
            address: this.address,
            port: this.port,
          ),
        );
        // "For all errors we close the socket."
        close();
      });
      return 0;
    }
    onSend?.call(this, sent.last);
    return buffer.length;
  }

  /// A datagram arriving from the network: queued, and the read event raised
  /// so an `await for` over the socket wakes up to `receive()` it.
  void deliver(List<int> data, {InternetAddress? from, int fromPort = 0}) {
    if (closed) return;
    _inbox.add(
      Datagram(
        Uint8List.fromList(data),
        from ?? InternetAddress('192.0.2.7'),
        fromPort,
      ),
    );
    _events.add(RawSocketEvent.read);
  }

  @override
  Datagram? receive() => _inbox.isEmpty ? null : _inbox.removeFirst();

  @override
  void close() {
    if (closed) return;
    closed = true;
    _events.add(RawSocketEvent.closed);
    unawaited(_events.close());
  }

  // Options the transports set on their way to sending. Accepted and ignored:
  // nothing here routes, so there is nothing for them to change.
  @override
  bool broadcastEnabled = false;
  @override
  bool readEventsEnabled = true;
  @override
  bool writeEventsEnabled = true;
  @override
  bool multicastLoopback = true;
  @override
  int multicastHops = 1;
  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) {}
  @override
  void leaveMulticast(InternetAddress group, [NetworkInterface? interface]) {}
  @override
  void setRawOption(RawSocketOption option) {}
  @override
  Uint8List getRawOption(RawSocketOption option) => Uint8List(0);

  // Anything the interface grows that no transport here calls. Declared so a
  // new SDK member cannot break the build; reached only by a test that calls
  // something this fake has no answer for, which should fail loudly.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
