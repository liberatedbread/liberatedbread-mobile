// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:liberated_bread_mobile/services/ws_control_service.dart';

/// A scripted device on the far end of the [WsSocket] seam.
///
/// The ONE fake for every suite that drives a WebSocket session: three test
/// files each carried a near-verbatim copy, and the first change to the
/// socket surface (the pingInterval hook) already had to be patched into
/// all three — a fake that misses the next member would silently pin a
/// stale contract.
///
/// Single-subscription, like `dart:io`'s WebSocket: it BUFFERS what the
/// device sends until something listens. A broadcast controller here would
/// drop the first frame — and dropping the first frame is precisely the
/// case the session's listener ordering exists to survive, so a fake that
/// could not deliver it would test nothing.
class ScriptedWsSocket implements WsSocket {
  /// The last [pingInterval] the session set — the protocol keepalive.
  Duration? pings;
  @override
  set pingInterval(Duration? interval) => pings = interval;

  final _out = StreamController<dynamic>();

  /// Every frame the session wrote, in order.
  final List<String> written = [];

  var closed = false;

  @override
  Stream<dynamic> get stream => _out.stream;

  @override
  void add(String frame) => written.add(frame);

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) await _out.close();
  }

  /// The DEVICE speaks: deliver one frame to the session.
  void send(String frame) => _out.add(frame);

  /// The DEVICE hangs up: the stream ends without the session closing it.
  Future<void> hangUp() async {
    if (!_out.isClosed) await _out.close();
  }
}
