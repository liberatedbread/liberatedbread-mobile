// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../models/ha_config.dart';
import '../models/network_device.dart';
import 'ha_api_client.dart';

/// The transport half of Home-Assistant-mediated Roomba control.
///
/// The robot serves ONE local client at a time and a new connection evicts the
/// old, so an app and a Home Assistant both talking to it directly fight over
/// the slot — the owner's own iRobot app included. If HA is in the house, the
/// honest answer is to let HA hold the robot and ask HA instead, which is what
/// this does. It is the same argument the rest980 path makes, with the server
/// somebody already runs.
///
/// The protocol underneath is still koalazak/dorita980's work: Home Assistant's
/// `roomba` integration speaks it via roombapy, and this app speaks it directly
/// on the other two paths. Nothing here re-derives it.
///
/// Like [Rest980Client], this knows nothing device-specific beyond the mapping
/// below — it hands back the same flattened dotted keys the direct path's MQTT
/// payloads produce, so the control screen cannot tell the transports apart.
class HaRoombaClient {
  final HaApiClient _api;
  final HaConfig _config;

  const HaRoombaClient({required HaApiClient api, required HaConfig config})
      : _api = api,
        _config = config;

  /// Our spec's command names → Home Assistant `vacuum` services.
  ///
  /// `dock` is `return_to_base`, and that mapping carries a rule with it: the
  /// direct path has to send `stop` before `dock`, because the raw protocol
  /// rejects `dock` mid-clean. HA's service makes that transition itself, so
  /// sending a preceding `stop` here would be wrong — see
  /// [HaRoombaController.sendCommand].
  ///
  /// `resume` is absent: HA models resuming as `start` from a paused state,
  /// and there is no separate service to call.
  static const _services = <String, String>{
    'clean': 'start',
    'pause': 'pause',
    'stop': 'stop',
    'dock': 'return_to_base',
    'find': 'locate',
  };

  /// HA's `VacuumEntityFeature` bits, for the commands this app sends.
  ///
  /// An entity advertises what it can do, and integrations differ — not every
  /// vacuum HA knows about can locate, and a robot behind an integration that
  /// cannot pause should not be offered a Pause button.
  /// The values are HA's own, and the ordering of that enum is a trap: `1` is
  /// TURN_ON (a legacy bit the roomba integration never sets), while START —
  /// the bit that actually gates Clean — is 8192, near the end. Getting this
  /// wrong does not error; it silently removes the button.
  static const _featureBits = <String, int>{
    'clean': 8192, // START
    'pause': 4, // PAUSE
    'stop': 8, // STOP
    'dock': 16, // RETURN_HOME
    'find': 512, // LOCATE
  };

  /// Whether this app knows how to ask HA for [commandName] at all.
  static bool knows(String commandName) => _services.containsKey(commandName);

  /// Whether [entity] advertises support for [commandName].
  ///
  /// An entity that reports no `supported_features` at all is taken at its
  /// word for the four core commands rather than being treated as inert: some
  /// integrations omit the attribute, and drawing no buttons would be a worse
  /// failure than offering one HA then refuses.
  static bool supports(HaEntityState entity, String commandName) {
    final bit = _featureBits[commandName];
    if (bit == null) return false;
    final features = entity.attributes['supported_features'];
    if (features is! int) return commandName != 'find';
    return features & bit != 0;
  }

  /// Every vacuum Home Assistant knows about.
  Future<List<HaEntityState>> vacuums() => _api.entitiesInDomain(
        baseUrl: _config.baseUrl,
        token: _config.token,
        domain: 'vacuum',
      );

  /// Every binary_sensor HA knows about — searched for the bin-full sibling.
  ///
  /// Whole-domain rather than a lookup by id because HA's entity id is derived
  /// from the name at creation and does not track later renames, so building
  /// the sibling's id by string surgery is a guess. Matching against the real
  /// list is not.
  Future<List<HaEntityState>> binarySensors() => _api.entitiesInDomain(
        baseUrl: _config.baseUrl,
        token: _config.token,
        domain: 'binary_sensor',
      );

  /// One vacuum's state, or null when HA no longer has that entity.
  Future<HaEntityState?> vacuum(String entityId) => _api.entityState(
        baseUrl: _config.baseUrl,
        token: _config.token,
        entityId: entityId,
      );

  /// Call the `vacuum` service [commandName] maps to.
  Future<void> send(String entityId, String commandName) {
    final service = _services[commandName];
    if (service == null) {
      throw HaServerException(
          400, 'Home Assistant has no vacuum service for "$commandName"');
    }
    return _api.callService(
      baseUrl: _config.baseUrl,
      token: _config.token,
      domain: 'vacuum',
      service: service,
      entityId: entityId,
    );
  }

  /// Present one of HA's vacuums as a device the app can list and open.
  ///
  /// The robot may be somewhere this phone cannot reach — a separate VLAN, a
  /// firewalled subnet — which is exactly why it is worth listing: the
  /// commands go to Home Assistant, not to the robot, so the panel works
  /// regardless. [host] is therefore the Home Assistant host, and is display
  /// and grouping only; nothing on this transport dials it.
  ///
  /// The entity id rides in `txt`, which already exists for discovery-time
  /// key/value facts, rather than in a new field on the model.
  static NetworkDevice asDevice(HaEntityState vacuum, {required String host}) =>
      NetworkDevice(
        host: host,
        name: vacuum.friendlyName,
        sources: const {NetworkDiscoverySource.homeAssistant},
        discoveredAt: DateTime.now(),
        txt: {
          'ha_entity_id': vacuum.entityId,
          // So a robot listed from HA and the same robot found by the UDP
          // probe can be recognised as one device, when both happen.
          if (vacuum.attributes['blid'] is String)
            'blid': vacuum.attributes['blid'] as String,
        },
      );

  /// Translate a vacuum entity into the dotted paths the spec's entities bind
  /// to, so one control screen renders every transport.
  ///
  /// The three bindings are `state.reported.batPct`,
  /// `state.reported.cleanMissionStatus.phase` and `state.reported.bin.full`.
  /// [binFull] is the sibling `binary_sensor` HA's roomba integration exposes
  /// for the bin, when there is one.
  ///
  /// A field with no source is OMITTED rather than defaulted. An absent
  /// reading renders as unknown; a fabricated one renders as a fact — and "bin
  /// empty" is exactly the fact nobody should invent.
  static Map<String, String> stateFields(
    HaEntityState vacuum, {
    HaEntityState? binFull,
  }) {
    final fields = <String, String>{};
    if (!vacuum.isAvailable) return fields;

    final battery = vacuum.attributes['battery_level'];
    if (battery is num) {
      fields['state.reported.batPct'] = battery.round().toString();
    }

    // `status` is the roomba integration's own phase text — the robot's word
    // for what it is doing, which is what the spec's Mission Phase entity
    // means. HA's canonical `state` is the fallback: it is a smaller
    // vocabulary shared by every vacuum integration, so it always exists but
    // says less.
    final status = vacuum.attributes['status'];
    fields['state.reported.cleanMissionStatus.phase'] =
        (status is String && status.isNotEmpty) ? status : vacuum.state;

    final bin = _binFullValue(vacuum, binFull);
    if (bin != null) fields['state.reported.bin.full'] = bin;

    return fields;
  }

  /// "1"/"0" for the binary_sensor's `on_when: nonzero`, or null when nothing
  /// reports it.
  static String? _binFullValue(HaEntityState vacuum, HaEntityState? binFull) {
    // Older roomba integrations put it on the vacuum itself.
    final attribute = vacuum.attributes['bin_full'];
    if (attribute is bool) return attribute ? '1' : '0';

    if (binFull != null && binFull.isAvailable) {
      return binFull.state == 'on' ? '1' : '0';
    }
    return null;
  }

  /// The bin-full binary_sensor that belongs to [vacuum], if HA has one.
  ///
  /// Matched on the object id rather than by name text, because that is the
  /// part HA derives from the same device: `vacuum.dorita` →
  /// `binary_sensor.dorita_bin_full`.
  static HaEntityState? binFullFor(
    HaEntityState vacuum,
    List<HaEntityState> binarySensors,
  ) {
    final wanted = '${vacuum.objectId}_bin_full';
    for (final sensor in binarySensors) {
      if (sensor.objectId == wanted) return sensor;
    }
    return null;
  }
}
