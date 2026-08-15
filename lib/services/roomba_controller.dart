// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'ha_api_client.dart';
import 'ha_roomba_client.dart';
import 'rest980_client.dart';
import 'roomba_control_service.dart';
import 'roomba_credential_store.dart';
import 'spec_codec.dart';

/// The commands a single control actually has to send.
///
/// Almost always one. `dock` is the exception: the robot accepts it only from a
/// paused or stopped state, so a Dock button pressed mid-clean — the moment
/// somebody most wants it — does nothing at all. The spec's own `dock`
/// description says as much: "a consumer offering one 'send home' button sends
/// stop then dock."
///
/// A pure function rather than a branch inside either controller, because both
/// transports owe the same behaviour and a rule implemented twice is a rule
/// that will eventually be implemented once.
List<String> roombaCommandSequence(String commandName) =>
    commandName == 'dock' ? const ['stop', 'dock'] : [commandName];

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
  Future<void> sendCommand(String commandName) async {
    for (final step in roombaCommandSequence(commandName)) {
      await _client.sendCommand(specYaml: _specYaml, commandName: step);
    }
  }

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
  Future<void> sendCommand(String commandName) async {
    for (final step in roombaCommandSequence(commandName)) {
      await _client.action(_baseUrl, step);
    }
  }

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

/// The recommended path: Home Assistant holds the robot, the app asks HA.
///
/// Nothing here talks to the robot. That is the entire point — HA already has
/// the one local connection the robot allows, and a second contender for that
/// slot is what locks people out of their own app.
class HaRoombaController implements RoombaController {
  final HaRoombaClient _client;
  final String _entityId;

  /// HA polls the robot itself (its integration is `local_polling`), so there
  /// is nothing to push here. Matches [Rest980Controller]: live enough for a
  /// mission display, gentle enough for a Pi.
  static const pollInterval = Duration(seconds: 2);

  final _state = StreamController<Map<String, String>>.broadcast();
  Timer? _poll;

  /// What the entity last said it can do. Null until the first read — the
  /// screen asks [supports] before drawing a button, so until HA has answered
  /// the safe reading is "the four core commands", not "nothing".
  HaEntityState? _entity;

  HaRoombaController({
    required HaRoombaClient client,
    required String entityId,
  })  : _client = client,
        _entityId = entityId;

  @override
  Future<void> connect() async {
    if (_poll != null) return;
    await _read();
    _poll = Timer.periodic(pollInterval, (_) => _read());
  }

  Future<void> _read() async {
    try {
      final vacuum = await _client.vacuum(_entityId);
      if (vacuum == null) {
        // HA answered, and it has no such entity. That is a different problem
        // from an unreachable server and must not read as one: the robot was
        // removed or renamed in HA, and re-adopting is the fix.
        if (!_state.isClosed) {
          _state.addError(HaServerException(
            404,
            'Home Assistant no longer has $_entityId. It may have been '
            'removed or renamed there.',
          ));
        }
        return;
      }
      _entity = vacuum;

      // Only fetched when the vacuum does not carry the reading itself, so the
      // common case stays one request per tick.
      HaEntityState? binFull;
      if (vacuum.attributes['bin_full'] is! bool) {
        final sensors = await _client.binarySensors();
        binFull = HaRoombaClient.binFullFor(vacuum, sensors);
      }

      final fields = HaRoombaClient.stateFields(vacuum, binFull: binFull);
      if (fields.isNotEmpty && !_state.isClosed) _state.add(fields);
    } catch (e) {
      if (!_state.isClosed) _state.addError(e);
    }
  }

  /// One service call per command — and deliberately NOT
  /// [roombaCommandSequence].
  ///
  /// Stop-then-dock exists because the robot's own protocol rejects `dock`
  /// mid-clean. `vacuum.return_to_base` performs that transition itself, so
  /// sending `stop` first would be a spurious extra command — and on an
  /// integration that reports the two asynchronously, a race with itself.
  @override
  Future<void> sendCommand(String commandName) =>
      _client.send(_entityId, commandName);

  @override
  Stream<Map<String, String>> get state => _state.stream;

  @override
  bool supports(String commandName) {
    if (!HaRoombaClient.knows(commandName)) return false;
    final entity = _entity;
    // Before the first read, hide only what no vacuum is guaranteed to have.
    if (entity == null) return commandName != 'find';
    return HaRoombaClient.supports(entity, commandName);
  }

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
/// The stored credential is the whole switch — an HA entity id, a rest980 base
/// URL, or neither — and nothing else in the UI branches on the choice.
///
/// Home Assistant wins when both are set. Not arbitrary: both exist to keep
/// exactly one thing holding the robot's single local connection, and if HA is
/// configured then HA is already that thing. Preferring the server would leave
/// two of them contending, which is the failure both settings exist to avoid.
///
/// [haClient] returns null when Home Assistant is not configured in the app at
/// all — a stored entity id is then unusable, and the robot falls back to the
/// path that still works rather than to an error.
RoombaController roombaControllerFor({
  required RoombaCredentials credentials,
  required String host,
  required String specYaml,
  required SpecCodec codec,
  required RoombaMqttClient Function() directClient,
  required Rest980Client Function() restClient,
  HaRoombaClient? Function()? haClient,
}) {
  final entityId = credentials.haEntityId;
  if (entityId != null && entityId.isNotEmpty) {
    final client = haClient?.call();
    if (client != null) {
      return HaRoombaController(client: client, entityId: entityId);
    }
  }
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
