// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/error_text.dart';
import 'spec_codec.dart';

/// The transport half of rest980 control: HTTP to a
/// [rest980](https://github.com/koalazak/rest980) server the user runs.
///
/// rest980 is koalazak's own REST wrapper around dorita980 — the same author as
/// the protocol itself. When someone points the app at one, dorita980 is
/// literally the thing talking to the robot, and this class is a few HTTP GETs.
///
/// Like every other transport client here it knows nothing device-specific
/// beyond the endpoint names: the state document it fetches goes straight back
/// through the Rust codec that flattens the direct path's MQTT payloads, so
/// both paths hand the entity layer identical dotted keys. That shared decode
/// is what lets one control screen drive either transport.
class Rest980Client {
  final http.Client _client;
  final SpecCodec _codec;

  /// rest980 sits on the user's own LAN, usually on a Pi. Generous enough for a
  /// slow box, short enough that a dead server is obvious.
  static const timeout = Duration(seconds: 10);

  Rest980Client({required SpecCodec codec, http.Client? client})
      : _codec = codec,
        _client = client ?? http.Client();

  /// Our spec's command names → rest980's action endpoints.
  ///
  /// `clean` is rest980's `start`: the spec names the command after what the
  /// robot calls it on the wire, rest980 after what dorita980's method is
  /// called, and this map is where the two spellings meet.
  ///
  /// `find` is deliberately absent. rest980 publishes no locate endpoint — the
  /// robot can beep, but that server offers no way to ask it to. Mapping it to
  /// something adjacent would be inventing an API.
  static const _actions = <String, String>{
    'clean': 'start',
    'pause': 'pause',
    'stop': 'stop',
    'dock': 'dock',
    'resume': 'resume',
  };

  /// Whether rest980 can send this command at all.
  static bool supports(String commandName) => _actions.containsKey(commandName);

  /// Trim a user-typed base URL into something joinable.
  ///
  /// People paste `http://pi.local:3000/` with the slash, or leave the scheme
  /// off entirely. Both are the address they meant; neither joins correctly
  /// without this.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Send one command.
  ///
  /// Throws [Rest980Exception] for anything that is not a 2xx, including the
  /// unsupported-command case — which is checked here as well as in the UI,
  /// because a control that slipped through the gate must fail loudly rather
  /// than quietly GET a 404.
  Future<void> action(String baseUrl, String commandName) async {
    final endpoint = _actions[commandName];
    if (endpoint == null) {
      throw Rest980Exception(
        'rest980 has no endpoint for "$commandName". Talk to the robot '
        'directly for that one — clear the server address in this robot\'s '
        'settings.',
      );
    }
    final response = await _get(
      baseUrl,
      '/api/local/action/$endpoint',
      'the $commandName command',
    );
    _throwForStatus(response, 'the $commandName command');
  }

  /// Read the robot's full state and flatten it the way the direct path does.
  ///
  /// The returned map is keyed by the same dotted paths
  /// (`state.reported.batPct`) the spec's entities bind to, because it is the
  /// same Rust function doing the flattening. rest980's `/api/local/info/state`
  /// answers with dorita980's own state document, which is the `reported` tree
  /// the robot published — so the paths line up once the envelope does.
  Future<Map<String, String>> state(String baseUrl) async {
    final response =
        await _get(baseUrl, '/api/local/info/state', 'robot state');
    _throwForStatus(response, 'robot state');
    // rest980 returns the reported tree at the top level, while the robot
    // publishes it wrapped in {"state":{"reported":{...}}}. Re-wrapping here
    // rather than teaching the codec two shapes keeps one decoder and one set
    // of entity paths — the whole reason both transports share a screen.
    final wrapped = '{"state":{"reported":${response.body}}}';
    return _codec.roombaStateFields(payload: wrapped);
  }

  /// Confirm a server is reachable and is actually rest980, for the settings
  /// screen's "test" button. Returns the robot's reported name when it can.
  Future<String?> probe(String baseUrl) async {
    final response = await _get(baseUrl, '/api/local/info/state', 'the server');
    _throwForStatus(response, 'the server');
    final fields = await state(baseUrl);
    return fields['state.reported.name'];
  }

  Future<http.Response> _get(String baseUrl, String path, String what) async {
    final uri = Uri.parse('${normalizeBaseUrl(baseUrl)}$path');
    try {
      return await _client.get(uri).timeout(timeout);
    } on SocketException catch (e) {
      throw Rest980Exception(
        'Could not reach the rest980 server at ${uri.host} — ${e.message}.',
      );
    } on TimeoutException {
      throw Rest980Exception(
        'The rest980 server did not answer $what within ${timeout.inSeconds}s.',
      );
    } on http.ClientException catch (e) {
      throw Rest980Exception(
          'The rest980 server failed on $what: ${e.message}');
    } on FormatException {
      throw Rest980Exception('"$baseUrl" is not a usable address.');
    }
  }

  void _throwForStatus(http.Response response, String what) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw Rest980Exception(
      'The rest980 server answered $what with HTTP ${response.statusCode}. '
      '${response.statusCode == 404 ? 'Check the address — this looks like a '
          'web server, but not a rest980 one.' : 'Check its logs: it may have '
          'lost the robot.'}',
    );
  }

  void close() => _client.close();
}

/// A rest980 request failed, with a message meant to be shown as-is.
class Rest980Exception implements UserFacingException {
  @override
  final String message;
  const Rest980Exception(this.message);
  @override
  String toString() => message;
}
