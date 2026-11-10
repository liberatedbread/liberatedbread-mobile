// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../core/error_text.dart';
import '../core/log.dart';
import '../src/rust/api/philips_air_api.dart';
import 'json_fields.dart';

/// A Philips purifier could not be read or did not take a write, in words
/// meant for the person holding the phone.
class PhilipsAirException implements UserFacingException {
  @override
  final String message;
  const PhilipsAirException(this.message);
  @override
  String toString() => 'PhilipsAirException: $message';
}

/// The transport half of the Philips encrypted-CoAP purifier
/// (`philips_air_coap`): datagrams to UDP 5683 and the ones that answer them.
///
/// Every CoAP byte, the counter and the envelope are the Rust codec's
/// (`philips_air_api`); this owns the socket and the waiting. Each read and
/// each write is one short session on its own socket, opened with a fresh
/// sync, because the spec does not know whether the device rejects a reused
/// or stale counter: a write always goes under the counter the sync just
/// returned, plus one, and is never retried. Refused is reported as refused.
class PhilipsAirControlClient {
  /// `crate::protocol::philips_air::PORT`, kept here so a device with no
  /// port anywhere still has one without a trip across the bridge.
  static const defaultPort = 5683;

  /// One exchange's ceiling.
  final Duration timeout;

  final Random _random;

  /// Where the session's socket comes from; tests may bind elsewhere.
  final Future<RawDatagramSocket> Function() _bind;

  PhilipsAirControlClient({
    this.timeout = const Duration(seconds: 3),
    Random? random,
    Future<RawDatagramSocket> Function()? bind,
  }) : _random = random ?? Random.secure(),
       _bind =
           bind ?? (() => RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));

  /// Read the status: sync, one GET of `/sys/dev/status`, decrypt, and
  /// flatten to the dotted names the spec's entities read
  /// (`state.reported.pm25`).
  Future<Map<String, String>> readStatus(String host, int port) async {
    final session = await _open(host, port);
    try {
      await _sync(session);
      final token = _token();
      final reply = await session.exchange(
        philipsAirStatusRequest(messageId: _messageId(), token: token),
        token,
        what: 'a status read',
      );
      _requireSuccess(reply, 'the status read');
      final String json;
      try {
        json = philipsAirDecodeStatus(payload: reply.payload);
      } on AnyhowException catch (e) {
        throw PhilipsAirException(
          'The purifier answered with a status this app cannot read '
          '(${e.message}).',
        );
      }
      // The read asked to observe, as every client does; this says it is done
      // so the device need not keep notifying a socket about to close.
      try {
        session.send(
          philipsAirStatusDeregister(messageId: _messageId(), token: token),
        );
      } catch (_) {}
      return jsonStateFields(json);
    } finally {
      session.close();
    }
  }

  /// Send one of the spec's control writes. Rendered and checked before
  /// anything goes on the wire, so a value outside the spec's list never
  /// reaches the device.
  Future<void> sendCommand(
    String host,
    int port, {
    required String specYaml,
    required String commandName,
    required Map<String, String> values,
  }) async {
    final String plaintext;
    try {
      plaintext = await philipsAirRenderControl(
        specYaml: specYaml,
        commandName: commandName,
        values: values,
      );
    } on AnyhowException catch (e) {
      throw PhilipsAirException('Not sent: ${e.message}');
    }
    final session = await _open(host, port);
    try {
      final counter = await _sync(session);
      final token = _token();
      final PhilipsAirControlFrameDto frame;
      try {
        frame = philipsAirControlRequest(
          messageId: _messageId(),
          token: token,
          syncedCounter: counter,
          plaintext: plaintext,
        );
      } on AnyhowException catch (e) {
        throw PhilipsAirException('Not sent: ${e.message}');
      }
      final reply = await session.exchange(
        frame.datagram,
        token,
        what: 'the write',
      );
      _requireSuccess(reply, 'the write');
      if (!philipsAirControlSucceeded(payload: reply.payload)) {
        throw PhilipsAirException(
          'The purifier did not accept that '
          '(it answered ${_preview(reply.payload)}). Nothing was retried.',
        );
      }
    } finally {
      session.close();
    }
  }

  Future<String> _sync(_Session session) async {
    final token = _token();
    final nonce = List.generate(
      4,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join().toUpperCase();
    final PhilipsAirReplyDto reply;
    try {
      reply = await session.exchange(
        philipsAirSyncRequest(
          messageId: _messageId(),
          token: token,
          nonce: nonce,
        ),
        token,
        what: 'the session sync',
      );
    } on PhilipsAirException catch (e) {
      throw PhilipsAirException(
        '${e.message} Some models never answer local CoAP, and some '
        'firmware updates removed it; a power cycle has also brought back '
        'units that stopped answering.',
      );
    }
    _requireSuccess(reply, 'the session sync');
    try {
      return philipsAirParseSyncReply(payload: reply.payload);
    } on AnyhowException {
      throw PhilipsAirException(
        'The device answered the sync with ${_preview(reply.payload)}, not '
        'a counter. It may not be a Philips purifier of this generation.',
      );
    }
  }

  void _requireSuccess(PhilipsAirReplyDto reply, String what) {
    if (!reply.successClass) {
      throw PhilipsAirException(
        'The purifier refused $what (CoAP ${reply.code}).',
      );
    }
  }

  Future<_Session> _open(String host, int port) async {
    final InternetAddress address;
    try {
      address =
          InternetAddress.tryParse(host) ??
          (await InternetAddress.lookup(host)).first;
    } on SocketException catch (e) {
      throw PhilipsAirException('Could not find $host (${e.message}).');
    }
    final socket = await _bind();
    return _Session(socket, address, port, timeout);
  }

  List<int> _token() => List.generate(4, (_) => _random.nextInt(256));

  int _messageId() => _random.nextInt(0x10000);

  static String _preview(List<int> payload) {
    if (payload.isEmpty) return 'nothing';
    final text = String.fromCharCodes(
      payload.take(40).map((b) => b >= 0x20 && b < 0x7F ? b : 0x3F),
    );
    return '"$text${payload.length > 40 ? '…' : ''}"';
  }
}

/// One socket, one peer: datagrams from anywhere else are dropped.
class _Session {
  final RawDatagramSocket _socket;
  final InternetAddress _address;
  final int _port;
  final Duration _timeout;
  final _inbox = <List<int>>[];
  Completer<void>? _arrived;
  late final StreamSubscription<RawSocketEvent> _events;

  _Session(this._socket, this._address, this._port, this._timeout) {
    _events = _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = _socket.receive(); d != null; d = _socket.receive()) {
        if (d.address == _address && d.port == _port) _inbox.add(d.data);
      }
      _arrived?.complete();
      _arrived = null;
    });
  }

  void send(List<int> datagram) {
    _socket.send(datagram, _address, _port);
  }

  /// Send [datagram] and wait for the reply on [token], acknowledging a
  /// confirmable one. Anything else that arrives is read and passed over.
  Future<PhilipsAirReplyDto> exchange(
    List<int> datagram,
    List<int> token, {
    required String what,
  }) async {
    send(datagram);
    final deadline = DateTime.now().add(_timeout);
    while (true) {
      while (_inbox.isEmpty) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) throw _silent(what);
        try {
          await (_arrived ??= Completer<void>()).future.timeout(remaining);
        } on TimeoutException {
          throw _silent(what);
        }
      }
      final reply = philipsAirReadReply(
        datagram: _inbox.removeAt(0),
        token: token,
      );
      final owe = reply.owe;
      if (owe != null) send(owe);
      if (reply.answersRequest) return reply;
      Log.net.debug('philips air: passed over a datagram during $what');
    }
  }

  PhilipsAirException _silent(String what) => PhilipsAirException(
    'The purifier at ${_address.address}:$_port did not answer $what '
    'within ${_timeout.inSeconds} seconds.',
  );

  void close() {
    _events.cancel();
    _socket.close();
  }
}
