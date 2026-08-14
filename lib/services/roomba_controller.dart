// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'rest980_client.dart';
import 'roomba_control_service.dart';
import 'roomba_credential_store.dart';
import 'spec_codec.dart';

/// How the app talks to a robot: straight at it, or through a rest980 server.
///
/// # Why there are two
///
/// The direct path is the default and needs nothing but the app. It talks the
/// robot's own MQTT-over-TLS protocol — koalazak/dorita980's work, transcribed
/// into this repo's spec and Rust codec.
///
/// [rest980](https://github.com/koalazak/rest980) is dorita980's own HTTP
/// wrapper, by the same author. Pointing the app at one means dorita980 itself
/// is doing the talking, which is the right answer in two cases:
///
///   * **More than one thing wants the robot.** It serves ONE local client at
///     a time and a new connection evicts the old, so an app and a Home
///     Assistant both talking directly fight over the slot. One rest980
///     holding the connection, with everything else speaking HTTP to it, is
///     the fix rather than a workaround.
///   * **Old firmware.** Some robots only offer the `AES128-SHA256` cipher,
///     which the phone's TLS stack retired and gives no way to request — so
///     the direct path cannot reach them at all. Node can select it, so
///     rest980 running on a computer can.
///
/// Both implementations hand back state as the same flattened dotted paths
/// (`state.reported.batPct`), because both run the reply through the same Rust
/// codec. The control screen cannot tell them apart, and that is the point:
/// one set of entities, one renderer, two transports underneath.
abstract class RoombaController {
  /// Open whatever the transport needs open. Idempotent.
  Future<void> connect();

  /// Send one of the spec's commands by name (`clean`, `dock`, …).
  Future<void> sendCommand(String commandName);

  /// State as it arrives, flattened to the paths the spec's entities bind to.
  Stream<Map<String, String>> get state;

  /// Whether this transport can send [commandName] at all.
  ///
  /// Exists because rest980 publishes no endpoint for `find`: the robot can
  /// beep, but that server offers no way to ask. A control surface that drew
  /// the button anyway would be promising something it cannot do, so the
  /// screen asks first and hides what is unsupported.
  bool supports(String commandName);

  /// Release the robot. Not optional on the direct path — see the class doc.
  Future<void> close();
}

/// The default: the app talks the robot's own protocol.
class DirectRoombaController implements RoombaController {
  final RoombaMqttClient _client;
  final String _specYaml;
  final String _host;
  final RoombaCredentials _credentials;

  DirectRoombaController({
    required RoombaMqttClient client,
    required String specYaml,
    required String host,
    required RoombaCredentials credentials,
  })  : _client = client,
        _specYaml = specYaml,
        _host = host,
        _credentials = credentials;

  @override
  Future<void> connect() => _client.connect(_host, _credentials);

  @override
  Future<void> sendCommand(String commandName) => _client.sendCommand(
        specYaml: _specYaml,
        commandName: commandName,
      );

  @override
  Stream<Map<String, String>> get state => _client.state;

  /// Everything the spec declares. The robot's own protocol is the whole
  /// surface, so there is nothing to gate.
  @override
  bool supports(String commandName) => true;

  @override
  Future<void> close() => _client.close();
}

/// The optional path: dorita980 does the talking, over rest980's HTTP API.
class Rest980Controller implements RoombaController {
  final Rest980Client _client;
  final String _baseUrl;

  /// rest980 holds the robot connection and answers questions about it, so
  /// state is polled rather than pushed. Two seconds is what the mission
  /// display needs to feel live without hammering someone's Raspberry Pi.
  static const pollInterval = Duration(seconds: 2);

  final _state = StreamController<Map<String, String>>.broadcast();
  Timer? _poll;

  Rest980Controller({required Rest980Client client, required String baseUrl})
      : _client = client,
        _baseUrl = baseUrl;

  @override
  Future<void> connect() async {
    if (_poll != null) return;
    // Poll once up front so the screen has state before the first tick, then
    // settle into the interval.
    await _readState();
    _poll = Timer.periodic(pollInterval, (_) => _readState());
  }

  Future<void> _readState() async {
    try {
      final fields = await _client.state(_baseUrl);
      if (fields.isNotEmpty && !_state.isClosed) _state.add(fields);
    } catch (e) {
      // A poll failure is worth surfacing — a rest980 that has stopped
      // answering looks exactly like a robot that has stopped reporting, and
      // the fix is different.
      if (!_state.isClosed) _state.addError(e);
    }
  }

  @override
  Future<void> sendCommand(String commandName) =>
      _client.action(_baseUrl, commandName);

  @override
  Stream<Map<String, String>> get state => _state.stream;

  @override
  bool supports(String commandName) => Rest980Client.supports(commandName);

  @override
  Future<void> close() async {
    _poll?.cancel();
    _poll = null;
  }

  /// Stop polling and close the stream. After this the controller is spent.
  Future<void> dispose() async {
    await close();
    await _state.close();
  }
}

/// Build the controller a robot is configured for.
///
/// A stored `rest980BaseUrl` is the whole switch: set it and the app routes
/// through the server, clear it and the app talks to the robot. Nothing else
/// in the UI branches on the choice.
RoombaController roombaControllerFor({
  required RoombaCredentials credentials,
  required String host,
  required String specYaml,
  required SpecCodec codec,
  required RoombaMqttClient Function() directClient,
  required Rest980Client Function() restClient,
}) {
  final baseUrl = credentials.rest980BaseUrl;
  if (baseUrl != null && baseUrl.isNotEmpty) {
    return Rest980Controller(client: restClient(), baseUrl: baseUrl);
  }
  return DirectRoombaController(
    client: directClient(),
    specYaml: specYaml,
    host: host,
    credentials: credentials,
  );
}
