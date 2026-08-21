// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/error_text.dart';
import '../core/group_actions.dart';
import '../core/log.dart';
import '../core/stop_signal.dart';
import '../models/ble_discovered_service.dart';
import '../models/network_device.dart';
import 'ble_service.dart';
import 'json_fields.dart';
import 'network_command_sender.dart';
import 'saved_network_device_store.dart';
import 'soap_control_service.dart';
import 'spec_codec.dart';

/// One device taking part in a group run. [spec]/[specYaml] come from the
/// saved match when the app has one; a member without them still runs — the
/// runner asks [GroupSpecResolver] after discovery, and the battery op's SIG
/// path needs no spec at all.
class GroupMember {
  final String id;
  final String name;
  final DeviceSpecDto? spec;
  final String? specYaml;

  /// What [spec] supports, derived once at construction. The detail screen
  /// re-renders every row on every run event and the runner checks each
  /// member again, and none of them should walk the spec's entity tree per
  /// look. Empty when [spec] is null — which means "unknown until connect",
  /// not "nothing works": the runner can still resolve a spec after
  /// discovery, and the battery read needs none at all.
  final Set<GroupOp> specOps;

  GroupMember({
    required this.id,
    required this.name,
    this.spec,
    this.specYaml,
  }) : specOps = spec == null ? const {} : supportedGroupOps(spec);
}

/// One Wi-Fi device taking part in a group run — the network counterpart of
/// [GroupMember]. Everything a run needs is resolved before it starts:
/// [record] carries the cached address, [specYaml]/[entities] the resolved
/// controls (null/empty when the spec no longer resolves — the member still
/// appears, and the runner reports the honest skip), and [ops] what those
/// entities support, from the same [supportedNetworkGroupOps] the op
/// buttons read.
class NetworkGroupMember {
  /// The namespaced member id (`net:<store id>`), which is how this member
  /// is keyed in [DeviceGroup.deviceIds] and in [GroupRunEvent.deviceId].
  final String memberId;
  final String name;
  final String? category;
  final SavedNetworkDevice record;
  final String? specYaml;
  final List<NetworkEntityDto> entities;
  final Set<GroupOp> ops;

  NetworkGroupMember({
    required this.memberId,
    required this.name,
    required this.record,
    this.category,
    this.specYaml,
    this.entities = const [],
  }) : ops = supportedNetworkGroupOps(entities);
}

/// Where one member is in the run. `queued` is the UI's initial row state;
/// the runner itself starts reporting at `connecting`.
enum GroupDeviceStatus {
  queued,
  connecting,
  discovering,
  running,
  ok,
  skipped,
  failed,
}

/// One completed reading for a member row ("Battery" -> "87 %").
class GroupReading {
  final String label;
  final String value;

  const GroupReading({required this.label, required this.value});
}

/// Progress report for one member. [detail] carries the skip/failure reason
/// or a completion summary; [readings] carry what a read op decoded.
class GroupRunEvent {
  final String deviceId;
  final GroupDeviceStatus status;
  final String? detail;
  final List<GroupReading> readings;

  const GroupRunEvent({
    required this.deviceId,
    required this.status,
    this.detail,
    this.readings = const [],
  });
}

/// Resolves a spec for a member the app has no stored match for, from what
/// discovery found — the same matching the device screen would do on connect.
typedef GroupSpecResolver = Future<({DeviceSpecDto spec, String yaml})?>
    Function(GroupMember member, List<BleDiscoveredService> services);

/// Executes one group operation across a group's members, one device at a
/// time, reporting per-device progress as a stream.
///
/// Strictly sequential on purpose: flutter_blue_plus serializes all BLE work
/// behind one process-wide mutex whose waits are untimed, so "parallel"
/// connections would only queue invisibly — and a wedged one would stall the
/// queue with no way to say which device is at fault. Sequential-with-timeouts
/// keeps every stall attributable and every step cancellable between devices.
///
/// Every connection is closed in a `finally`, which async* also runs when the
/// listener cancels mid-run — leaving a group member connected in the
/// background would block the next thing that wants the radio.
class GroupRunner {
  final BleService _ble;
  final SpecCodec _codec;
  final GroupSpecResolver? _resolveSpec;

  /// A belt over [BleService.connect]'s own internal 15s timeout, so a
  /// platform call that never returns cannot wedge the whole run.
  static const connectTimeout = Duration(seconds: 20);
  static const discoverTimeout = Duration(seconds: 10);

  /// Per read/write. Generous for one GATT round trip; short enough that a
  /// dead link fails one member, not the evening.
  static const ioTimeout = Duration(seconds: 8);

  GroupRunner({
    required BleService ble,
    required SpecCodec codec,
    GroupSpecResolver? resolveSpec,
  })  : _ble = ble,
        _codec = codec,
        _resolveSpec = resolveSpec;

  Stream<GroupRunEvent> run(
    GroupOp op,
    List<GroupMember> members, {
    double? brightnessPercent,
    required StopSignal stop,
  }) async* {
    // A scan may still be running behind the shell (the Nearby tab pauses
    // off-tab only after a grace period), and connecting mid-scan is flaky on
    // both platforms — same reason the saved-devices screen stops it first.
    await _ble.stopScan().catchError((Object _) {});

    for (final member in members) {
      if (stop.stopped) {
        yield GroupRunEvent(
          deviceId: member.id,
          status: GroupDeviceStatus.skipped,
          detail: 'Cancelled',
        );
        continue;
      }

      // Rule a member out from its spec alone before spending radio time on
      // it. Only for command ops with a known spec: read ops always get a
      // chance (the SIG battery path needs no spec), and a member with no
      // stored match may still resolve one after discovery.
      final knownSpec = member.spec;
      if (op.isCommand && knownSpec != null && !member.specOps.contains(op)) {
        yield GroupRunEvent(
          deviceId: member.id,
          status: GroupDeviceStatus.skipped,
          detail: "Not supported by this device's spec",
        );
        continue;
      }

      yield GroupRunEvent(
        deviceId: member.id,
        status: GroupDeviceStatus.connecting,
      );

      GroupRunEvent result;
      try {
        await _ble.connect(member.id).timeout(connectTimeout);
        yield GroupRunEvent(
          deviceId: member.id,
          status: GroupDeviceStatus.discovering,
        );
        final services =
            await _ble.discoverServices(member.id).timeout(discoverTimeout);

        var spec = knownSpec;
        var specYaml = member.specYaml;
        if (spec == null && _resolveSpec != null) {
          try {
            // Timed like every other await in this pipeline: a matcher that
            // hangs (FFI, pack load) must not wedge the generator — an
            // un-timed suspension here can't even be cancelled, because the
            // finally-disconnect only runs when the generator resumes.
            final resolved =
                await _resolveSpec(member, services).timeout(discoverTimeout);
            spec = resolved?.spec;
            specYaml = resolved?.yaml;
          } on TimeoutException {
            // Proceed spec-less: battery still works through the SIG path,
            // and command ops report an honest skip.
          }
        }

        yield GroupRunEvent(
          deviceId: member.id,
          status: GroupDeviceStatus.running,
        );
        result = op.isCommand
            ? await _runCommands(
                op, member, spec, specYaml, services, brightnessPercent)
            : await _runReads(op, member, spec, specYaml, services);
      } catch (e) {
        result = GroupRunEvent(
          deviceId: member.id,
          status: GroupDeviceStatus.failed,
          detail: friendlyErrorText(
            e,
            context: 'group ${op.name} on ${member.id}',
            fallback: 'Could not reach this device.',
            log: Log.ble,
          ),
        );
      } finally {
        // Also reached when the listener cancels mid-member: async* runs
        // enclosing finally blocks on cancel, so no connection outlives a run.
        await _ble.disconnect(member.id).catchError((Object _) {});
      }
      yield result;
    }
  }

  Future<GroupRunEvent> _runCommands(
    GroupOp op,
    GroupMember member,
    DeviceSpecDto? spec,
    String? specYaml,
    List<BleDiscoveredService> services,
    double? brightnessPercent,
  ) async {
    if (spec == null || specYaml == null) {
      return GroupRunEvent(
        deviceId: member.id,
        status: GroupDeviceStatus.skipped,
        detail: 'No spec matched this device',
      );
    }
    final writes = resolveGroupWrites(
      op: op,
      spec: spec,
      services: services,
      brightnessPercent: brightnessPercent,
    );
    if (writes.isEmpty) {
      // The spec promised the verb but this unit doesn't carry the
      // characteristic (family specs describe bigger variants) — say so
      // rather than silently dropping the device from the group.
      return GroupRunEvent(
        deviceId: member.id,
        status: GroupDeviceStatus.skipped,
        detail: supportedGroupOps(spec).contains(op)
            ? 'Not found on this device'
            : "Not supported by this device's spec",
      );
    }
    for (final write in writes) {
      final bytes = await _codec.encodeCommand(
        specYaml: specYaml,
        // The pair, not just the characteristic: UUIDs repeat across
        // services with different command tables, and the codec scopes its
        // lookup to the named service.
        serviceUuid: write.serviceUuid,
        charUuid: write.charUuid,
        commandName: write.commandName,
        params: write.params,
      );
      await _ble
          .writeCharacteristic(
              member.id, write.serviceUuid, write.charUuid, bytes)
          .timeout(ioTimeout);
    }
    return GroupRunEvent(
      deviceId: member.id,
      status: GroupDeviceStatus.ok,
      detail: writes.length == 1
          ? '1 command sent'
          : '${writes.length} commands sent',
    );
  }

  Future<GroupRunEvent> _runReads(
    GroupOp op,
    GroupMember member,
    DeviceSpecDto? spec,
    String? specYaml,
    List<BleDiscoveredService> services,
  ) async {
    final List<GroupRead> reads;
    switch (op) {
      case GroupOp.readBattery:
        reads = resolveBatteryReads(spec: spec, services: services);
        if (reads.isEmpty) {
          return GroupRunEvent(
            deviceId: member.id,
            status: GroupDeviceStatus.skipped,
            detail: 'No battery reading on this device',
          );
        }
      case GroupOp.readSensors:
        if (spec == null || specYaml == null) {
          return GroupRunEvent(
            deviceId: member.id,
            status: GroupDeviceStatus.skipped,
            detail: 'No spec matched this device',
          );
        }
        reads = resolveSensorReads(spec: spec, services: services);
        if (reads.isEmpty) {
          return GroupRunEvent(
            deviceId: member.id,
            status: GroupDeviceStatus.skipped,
            detail: 'No readable sensors on this device',
          );
        }
      default:
        throw StateError('not a read op: $op');
    }

    final readings = <GroupReading>[];
    var succeeded = 0;
    Object? lastError;
    for (final read in reads) {
      try {
        final bytes = await _ble
            .readCharacteristic(member.id, read.serviceUuid, read.charUuid)
            .timeout(ioTimeout);
        final decoded = await _codec.decodeValue(
          // A spec read decodes in the member spec's dialect; the SIG battery
          // fallback decodes through the standard profile, which the codec
          // selects from the service UUID when no spec is given.
          specYaml: read.specBased ? specYaml : null,
          serviceUuid: read.serviceUuid,
          charUuid: read.charUuid,
          bytes: bytes,
        );
        final display = groupReadingDisplay(read, decoded);
        readings.add(GroupReading(
          label: read.label,
          value: display ?? 'Unavailable',
        ));
        if (display != null) succeeded++;
      } catch (e) {
        // One reading failing shouldn't blank the others — degrade this row
        // and keep going. Only a device where nothing read at all fails.
        lastError = e;
        readings.add(GroupReading(label: read.label, value: 'Unavailable'));
      }
    }
    if (succeeded == 0 && lastError != null) {
      throw lastError; // Surfaced by run()'s catch as a per-device failure.
    }
    return GroupRunEvent(
      deviceId: member.id,
      status: GroupDeviceStatus.ok,
      readings: readings,
    );
  }
}

/// Executes one group operation across a group's Wi-Fi members.
///
/// Deliberately CONCURRENT, unlike [GroupRunner]: that runner's strict
/// sequencing exists because flutter_blue_plus serializes all BLE work
/// behind one process-wide untimed mutex, and none of that reasoning
/// applies to independent HTTP exchanges — ten TVs turned off one at a
/// time with generous timeouts would just be slow. A small worker pool
/// bounds the burst instead, and each member is still strictly sequential
/// within itself (its SOAP read-backs demand that much).
class NetworkGroupRunner {
  final SpecCodec _codec;
  final SoapControlClient _soap;
  final NetworkCommandSender Function({
    required NetworkDevice device,
    required String specYaml,
  }) _senderFor;

  /// A ceiling over one member's whole turn — resolve, state read, sends —
  /// so a device that blackholes traffic fails its own row, not the run.
  /// Well above the transports' own per-request timeouts (10 s), because a
  /// member's turn is several exchanges.
  static const memberTimeout = Duration(seconds: 45);

  /// In-flight members at once. Enough to make a room feel instant; small
  /// enough not to burst-flood a home AP with simultaneous TCP opens.
  static const concurrency = 4;

  NetworkGroupRunner({
    required SpecCodec codec,
    required SoapControlClient soap,
    required NetworkCommandSender Function({
      required NetworkDevice device,
      required String specYaml,
    }) senderFor,
  })  : _codec = codec,
        _soap = soap,
        _senderFor = senderFor;

  Stream<GroupRunEvent> run(
    GroupOp op,
    List<NetworkGroupMember> members, {
    double? brightnessPercent,
    required StopSignal stop,
  }) {
    final controller = StreamController<GroupRunEvent>();
    var next = 0;
    var live = 0;

    void pump() {
      while (live < concurrency && next < members.length) {
        final member = members[next++];
        if (stop.stopped) {
          controller.add(GroupRunEvent(
            deviceId: member.memberId,
            status: GroupDeviceStatus.skipped,
            detail: 'Cancelled',
          ));
          continue;
        }
        live++;
        _runMember(op, member, brightnessPercent, stop)
            .timeout(memberTimeout,
                onTimeout: () => GroupRunEvent(
                      deviceId: member.memberId,
                      status: GroupDeviceStatus.failed,
                      detail: 'The device did not answer in time.',
                    ))
            .then(controller.add)
            .whenComplete(() {
          live--;
          pump();
          if (live == 0 && next >= members.length) {
            unawaited(controller.close());
          }
        });
        controller.add(GroupRunEvent(
          deviceId: member.memberId,
          status: GroupDeviceStatus.running,
        ));
      }
      if (live == 0 && next >= members.length && !controller.isClosed) {
        unawaited(controller.close());
      }
    }

    controller.onListen = pump;
    return controller.stream;
  }

  Future<GroupRunEvent> _runMember(
    GroupOp op,
    NetworkGroupMember member,
    double? brightnessPercent,
    StopSignal stop,
  ) async {
    GroupRunEvent skip(String detail) => GroupRunEvent(
          deviceId: member.memberId,
          status: GroupDeviceStatus.skipped,
          detail: detail,
        );

    if (!op.isCommand) {
      // Battery/sensor sweeps are BLE ops today; a Wi-Fi member sits those
      // out with a reason rather than vanishing from the run.
      return skip('Not supported for Wi-Fi devices yet');
    }
    final specYaml = member.specYaml;
    if (specYaml == null) return skip('No spec matched this device');
    if (!member.ops.contains(op)) {
      return skip("Not supported by this device's spec");
    }
    final plan = resolveNetworkGroupPlan(
      op: op,
      entities: member.entities,
      brightnessPercent: brightnessPercent,
    );
    if (plan.isEmpty) return skip('Not found on this device');

    final sender = _senderFor(
      device: member.record.toNetworkDevice(),
      specYaml: specYaml,
    );
    try {
      // The description, only if something in the plan rides SOAP — the
      // same rule the control screen applies: asking a Roku for setup.xml
      // turns a working device into an error.
      SoapDeviceDescription? description;
      if (_needsDescription(plan)) {
        final device = member.record;
        final port = device.toNetworkDevice().controlPort;
        if (port == null) {
          return skip('No control port is known for this device');
        }
        description = await _soap.fetchDescription(
          device.host,
          port,
          path: device.ssdpDescriptionPath ?? '/setup.xml',
        );
      }

      var sent = 0;
      for (final send in plan.direct) {
        if (stop.stopped) break;
        await sender.sendAction(send.action, Map.of(send.values),
            description: description);
        sent++;
      }

      var alreadyOff = 0;
      var stateUnknown = 0;
      for (final toggle in plan.gated) {
        if (stop.stopped) break;
        final isOn = await _readIsOn(toggle.entity, specYaml, sender,
            description: description);
        if (isOn == true) {
          await sender.sendAction(toggle.action, {}, description: description);
          sent++;
        } else if (isOn == false) {
          alreadyOff++;
        } else {
          // Unknown blocks the toggle and nothing else: a failed read is
          // packet loss or a moved lease as often as it is standby, and a
          // blind toggle would turn a sleeping device on.
          stateUnknown++;
        }
      }

      if (sent > 0) {
        return GroupRunEvent(
          deviceId: member.memberId,
          status: GroupDeviceStatus.ok,
          detail: sent == 1 ? '1 command sent' : '$sent commands sent',
        );
      }
      if (alreadyOff > 0 && stateUnknown == 0) return skip('Already off');
      if (stateUnknown > 0) {
        return skip('Power state unknown — the toggle was not sent');
      }
      return skip('Cancelled');
    } catch (e) {
      return GroupRunEvent(
        deviceId: member.memberId,
        status: GroupDeviceStatus.failed,
        detail: friendlyErrorText(
          e,
          context: 'group ${op.name} on ${member.memberId}',
          fallback: 'Could not reach this device.',
          log: Log.net,
        ),
      );
    } finally {
      await sender.close();
    }
  }

  bool _needsDescription(GroupNetworkPlan plan) {
    bool soap(NetworkActionDto action) =>
        action.transport != 'http' && action.transport != 'tcp-json';
    return plan.direct.any((send) => soap(send.action)) ||
        plan.gated.any((toggle) =>
            soap(toggle.action) ||
            toggle.entity.transport == null ||
            toggle.entity.transport == 'soap');
  }

  /// Read one entity's power state and decode it through the same
  /// [SpecCodec.readNetworkEntity] path the device screen uses, so a group
  /// row and the screen cannot disagree about what a reading means. Null —
  /// from a failed exchange as much as an undecodable one — means unknown.
  Future<bool?> _readIsOn(
    NetworkEntityDto entity,
    String specYaml,
    NetworkCommandSender sender, {
    SoapDeviceDescription? description,
  }) async {
    try {
      final Map<String, String> returned;
      if (entity.transport == 'http') {
        final request = await _codec.renderNetworkHttpStateRequest(
          specYaml: specYaml,
          stateCommand: entity.stateCommand,
          values: const {},
        );
        returned = jsonStateFields(await sender.sendHttpRequest(request));
      } else {
        final desc = description;
        if (desc == null) return null;
        final request = await _codec.renderNetworkStateRequest(
          specYaml: specYaml,
          stateCommand: entity.stateCommand,
        );
        final path = desc.controlPathFor(request);
        if (path == null) return null;
        returned = await _soap.send(desc.host, desc.port, path, request);
      }
      final reading = await _codec.readNetworkEntity(
        specYaml: specYaml,
        entityName: entity.name,
        returned: returned,
      );
      return reading?.isOn;
    } catch (e) {
      Log.net.debug('group state read failed for ${entity.name}: $e');
      return null;
    }
  }
}
