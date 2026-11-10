// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import '../core/error_text.dart';
import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/juicenet.dart';

/// The listener could not start, in words for the person holding the phone.
class JuiceNetException implements UserFacingException {
  @override
  final String message;
  const JuiceNetException(this.message);
  @override
  String toString() => message;
}

/// One datagram as heard: who sent it and what it said.
class JuiceNetHeard {
  final InternetAddress from;
  final JuiceNetFrameDto frame;
  final DateTime at;
  const JuiceNetHeard(this.from, this.frame, this.at);
}

/// Listens for a JuiceBox's status lines (`juicenet_udp`), READ-ONLY.
///
/// The charger is the UDP client and this phone is where one of the spec's
/// setup routes pointed it. This binds a port and reads what arrives; it
/// never sends a byte, so it never answers with the CMD line that sets the
/// charging current. The socket has no code path to `send`.
///
/// Datagrams from any address other than [chargerHost] are dropped, when it
/// is given, so a stray sender on the LAN cannot fill the card.
class JuiceNetListener {
  final int port;
  final String? chargerHost;

  /// Where the socket comes from; tests may bind loopback.
  final Future<RawDatagramSocket> Function(int port) _bind;

  RawDatagramSocket? _socket;
  final _heard = StreamController<JuiceNetHeard>.broadcast();

  JuiceNetListener({
    required this.port,
    this.chargerHost,
    Future<RawDatagramSocket> Function(int port)? bind,
  }) : _bind =
           bind ??
           ((port) => RawDatagramSocket.bind(InternetAddress.anyIPv4, port));

  Stream<JuiceNetHeard> get heard => _heard.stream;

  bool get listening => _socket != null;

  /// The port actually bound, which differs from [port] only when that was 0.
  int? get boundPort => _socket?.port;

  Future<void> start() async {
    if (_socket != null) return;
    final RawDatagramSocket socket;
    try {
      socket = await _bind(port);
    } on SocketException catch (e) {
      throw JuiceNetException(
        'Could not listen on UDP port $port (${e.osError?.message ?? e.message}). '
        'Another app may be using it; pick another and point the charger '
        'there.',
      );
    }
    _socket = socket;
    final expected = chargerHost == null
        ? null
        : InternetAddress.tryParse(chargerHost!);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        if (expected != null && d.address != expected) {
          Log.net.debug(
            'juicenet: dropped a datagram from ${d.address.address}',
          );
          continue;
        }
        _heard.add(
          JuiceNetHeard(
            d.address,
            juicenetParseDatagram(datagram: d.data),
            DateTime.now(),
          ),
        );
      }
    });
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _heard.close();
  }
}
