// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A scripted ECP2 socket for tests: plays the Roku end of the WebSocket —
// records what the client sends, answers from the test's script. Lives in
// fakes/ because both the service's unit tests and the screen's widget tests
// drive the protocol through it.

import 'dart:async';
import 'dart:convert';

import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';

class FakeEcp2Socket implements Ecp2Socket {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  var closed = false;

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  void add(String frame) => sent.add(jsonDecode(frame) as Map<String, dynamic>);

  /// A device frame, as the session's parser sees it.
  void receive(Map<String, dynamic> frame) => incoming.add(jsonEncode(frame));

  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}

/// A fake that needs no scripting: answers the authenticate challenge, then
/// serves canned query payloads and 200s every command. The widget tests'
/// virtual Limited-mode Roku — plain ECP refuses everything, this answers.
class AutoEcp2Socket extends FakeEcp2Socket {
  final Map<String, String> queryPayloads;

  /// [queryPayloads] maps the ECP2 request name (`query-apps`) to the XML the
  /// device would have put in `content-data`.
  AutoEcp2Socket({this.queryPayloads = const {}});

  /// What a real device does on connect: lead with the challenge.
  void begin() => receive({
        'notify': 'authenticate',
        'param-challenge': 'QUJDREVGR0hJSg==',
        'param-methods': ['client-id', 'jwt'],
      });

  @override
  void add(String frame) {
    super.add(frame);
    final decoded = sent.last;
    final id = '${decoded['request-id']}';
    final request = '${decoded['request']}';
    // A microtask, not a synchronous answer: the device's reply can never
    // arrive inside the client's own send call.
    scheduleMicrotask(() {
      final payload = queryPayloads[request];
      receive({
        'response': request,
        'response-id': id,
        'status': '200',
        if (payload != null)
          'content-data': base64.encode(utf8.encode(payload)),
      });
    });
  }
}
