// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/error_text.dart';
import '../core/group_actions.dart';
import '../core/log.dart';
import '../core/stop_signal.dart';
import '../models/ble_discovered_service.dart';
import 'ble_service.dart';
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

  const GroupMember({
    required this.id,
    required this.name,
    this.spec,
    this.specYaml,
  });
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
      if (op.isCommand &&
          knownSpec != null &&
          !supportedGroupOps(knownSpec).contains(op)) {
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
          final resolved = await _resolveSpec(member, services);
          spec = resolved?.spec;
          specYaml = resolved?.yaml;
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
