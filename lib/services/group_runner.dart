// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/error_text.dart';
import '../core/group_actions.dart';
import '../core/hex.dart';
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

  GroupMember({required this.id, required this.name, this.spec, this.specYaml})
    : specOps = spec == null ? const {} : supportedGroupOps(spec);
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

  /// What the spec says about the control path — the declared port, the URL
  /// scheme, the TLS policy, the protocol handler. Carried because the sender
  /// needs it to reach the device the same way the device screen does; a group
  /// run that leaves it out is not the same exchange, whatever the wiring
  /// comment says.
  final NetworkCapabilitiesDto? capabilities;
  final Set<GroupOp> ops;

  NetworkGroupMember({
    required this.memberId,
    required this.name,
    required this.record,
    this.category,
    this.specYaml,
    this.capabilities,
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
typedef GroupSpecResolver =
    Future<({DeviceSpecDto spec, String yaml})?> Function(
      GroupMember member,
      List<BleDiscoveredService> services,
    );

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

  GroupRunner({required this._ble, required this._codec, this._resolveSpec});

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
        final services = await _ble
            .discoverServices(member.id)
            .timeout(discoverTimeout);

        var spec = knownSpec;
        var specYaml = member.specYaml;
        if (spec == null && _resolveSpec != null) {
          try {
            // Timed like every other await in this pipeline: a matcher that
            // hangs (FFI, pack load) must not wedge the generator — an
            // un-timed suspension here can't even be cancelled, because the
            // finally-disconnect only runs when the generator resumes.
            final resolved = await _resolveSpec(
              member,
              services,
            ).timeout(discoverTimeout);
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
                op,
                member,
                spec,
                specYaml,
                services,
                brightnessPercent,
              )
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

  /// The variants this member matched, or null when the question cannot be
  /// answered — a codec failure, a spec that declares none.
  ///
  /// Null and empty both read as "do not narrow" downstream, which is the
  /// behaviour that shipped before variant scoping: a device we cannot
  /// identify keeps every control rather than losing all of them.
  Future<List<String>?> _matchedVariants(
    GroupMember member,
    String specYaml,
    List<BleDiscoveredService> services,
  ) async {
    try {
      return await _codec.bleVariantNamesForDevice(
        yaml: specYaml,
        deviceName: member.name,
        serviceUuids: [for (final s in services) normalizeUuid(s.uuid)],
      );
    } catch (e) {
      Log.ble.debug('variant narrowing unavailable for ${member.id}: $e');
      return null;
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
    // Which model this member actually is, judged on what it advertised —
    // the same narrowing the device screen and the treadmill card apply. A
    // family spec can declare two same-named entities on two dialects sharing
    // one writable characteristic, and without this a single "turn on" writes
    // BOTH dialects' frames back to back.
    final matchedVariants = await _matchedVariants(member, specYaml, services);
    final writes = resolveGroupWrites(
      op: op,
      spec: spec,
      services: services,
      brightnessPercent: brightnessPercent,
      matchedVariants: matchedVariants,
    );
    if (writes.isEmpty) {
      // The spec promised the verb but this unit doesn't carry the
      // characteristic (family specs describe bigger variants) — say so
      // rather than silently dropping the device from the group.
      return GroupRunEvent(
        deviceId: member.id,
        status: GroupDeviceStatus.skipped,
        detail:
            supportedGroupOps(
              spec,
              matchedVariants: matchedVariants,
            ).contains(op)
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
            member.id,
            write.serviceUuid,
            write.charUuid,
            bytes,
          )
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
        readings.add(
          GroupReading(label: read.label, value: display ?? 'Unavailable'),
        );
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

  /// The same factory the device screen uses — INCLUDING `capabilities`,
  /// which this type used to omit.
  ///
  /// Dropping an optional argument from a function type is silent: the call
  /// compiled, and every sender a group built came out with
  /// `capabilities == null`. Three things followed. The spec's `default_port`
  /// stopped being the fallback, so the fix that made a hand-added device
  /// sendable was a no-op here. A Roku in a group sent to whatever port its
  /// SSDP LOCATION advertised instead of the 8060 its spec pins, and opened no
  /// signed session. And the TLS policy registered on the app-wide HTTP client
  /// as `policy: null`, overwriting the device screen's pinned registration
  /// and downgrading the Envoy and the SmartCast to blanket trust for the rest
  /// of the session.
  final NetworkCommandSenderFactory _senderFor;

  /// A ceiling over one member's whole turn — resolve, state read, sends —
  /// so a device that blackholes traffic fails its own row, not the run.
  /// Well above the transports' own per-request timeouts (10 s), because a
  /// member's turn is several exchanges.
  static const memberTimeout = Duration(seconds: 45);

  /// In-flight members at once. Enough to make a room feel instant; small
  /// enough not to burst-flood a home AP with simultaneous TCP opens.
  static const concurrency = 4;

  /// The credentials stored for one device, for the members whose spec names
  /// any. Null in a fixture, which reads as "none stored" — the same thing a
  /// device that needs none gets.
  final CredentialReader Function(NetworkDevice device)? _credentialsFor;

  NetworkGroupRunner({
    required this._codec,
    required this._soap,
    required this._senderFor,
    this._credentialsFor,
  });

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
          controller.add(
            GroupRunEvent(
              deviceId: member.memberId,
              status: GroupDeviceStatus.skipped,
              detail: 'Cancelled',
            ),
          );
          continue;
        }
        live++;
        // The timeout reports; it does not release the slot. `.timeout` only
        // completes the future you are holding — the work behind it keeps
        // running, keeps its sender open and keeps talking to the network.
        // Freeing the slot on it let `pump` start a fifth member while four
        // were still in flight, which is precisely what `concurrency` exists
        // to prevent (a burst of simultaneous TCP opens at a home AP). So the
        // event goes out at the deadline and the slot is held until the work
        // genuinely settles.
        //
        // A per-member stop is tripped at the same moment, so the abandoned
        // run unwinds at its next checkpoint instead of finishing an
        // operation nobody is waiting for. Every underlying step has its own
        // ceiling (connect, discover, io), so "settles" is bounded even for a
        // device that has stopped answering.
        final memberStop = StopSignal();
        unawaited(stop.whenStopped.then((_) => memberStop.stop()));
        var reported = false;
        void report(GroupRunEvent event) {
          if (reported || controller.isClosed) return;
          reported = true;
          controller.add(event);
        }

        final deadline = Timer(memberTimeout, () {
          report(
            GroupRunEvent(
              deviceId: member.memberId,
              status: GroupDeviceStatus.failed,
              detail: 'The device did not answer in time.',
            ),
          );
          memberStop.stop();
        });

        _runMember(op, member, brightnessPercent, memberStop)
            .then(
              report,
              onError: (Object e, StackTrace st) {
                // Without this, a throw anywhere in the member — plan resolution,
                // sender construction, a credential reader — became an unhandled
                // zone error while the row rendered "running" forever: report
                // never fired, and whenComplete below had already cancelled the
                // deadline that was the only other way out.
                Log.net.warning(
                  'group member ${member.memberId} failed',
                  error: e,
                  stackTrace: st,
                );
                report(
                  GroupRunEvent(
                    deviceId: member.memberId,
                    status: GroupDeviceStatus.failed,
                    detail: friendlyErrorText(
                      e,
                      fallback: 'Something went wrong driving this device.',
                      log: Log.net,
                    ),
                  ),
                );
              },
            )
            .whenComplete(() {
              deadline.cancel();
              live--;
              pump();
              if (live == 0 && next >= members.length) {
                unawaited(controller.close());
              }
            });
        controller.add(
          GroupRunEvent(
            deviceId: member.memberId,
            status: GroupDeviceStatus.running,
          ),
        );
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

    final device = member.record.toNetworkDevice();
    final sender = _senderFor(
      device: device,
      specYaml: specYaml,
      capabilities: member.capabilities,
    );
    // A group-built sender never had these, so its state reads rendered with
    // an empty map and a Hue bridge's `/api/{username}/lights` failed on a
    // value the app was holding. Wired only when this member's spec names a
    // credential, for the reason the device screen gives: the store is the
    // platform keychain and most of the catalogue needs nothing from it.
    final credentialsFor = _credentialsFor;
    if (credentialsFor != null) {
      // The SPEC's answer, the same question the device screen asks. Reads
      // count too — the Hue bridge's /api/{username}/sensors needs the value
      // with no ACTION declaring it — so the old action-level gate left
      // exactly those reads rendering from an empty map. Still spec-gated,
      // for the reason the screen gives: the store is the platform keychain
      // and most of the catalogue must never touch it.
      final declared = await _codec.credentialsForDevice(specYaml);
      if (declared.isNotEmpty) {
        sender.useCredentials(credentialsFor(device));
      }
    }
    try {
      // The description, only if something in the plan rides SOAP — the
      // same rule the control screen applies: asking a Roku for setup.xml
      // turns a working device into an error.
      SoapDeviceDescription? description;
      if (_needsDescription(plan)) {
        final device = member.record;
        // The sender's rule, not the device's: discovery first, then the port
        // the spec declares. Asking `toNetworkDevice().controlPort` here meant
        // the discovered one alone, so a device added by hand worked from its
        // own screen and was skipped in a group — the same fact, answered two
        // ways, which is what putting the rule on the sender was for.
        final port = sender.controlPort;
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
        await sender.sendAction(
          send.action,
          Map.of(send.values),
          description: description,
        );
        sent++;
      }

      var alreadyOff = 0;
      var stateUnknown = 0;
      for (final toggle in plan.gated) {
        if (stop.stopped) break;
        final isOn = await _readIsOn(
          toggle.entity,
          specYaml,
          sender,
          description: description,
        );
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
    // Asked of the sender, which owns the list. This was a fourth copy of it
    // and the stalest: it treated websocket and mqtt as SOAP, so a television
    // or a Bambu in a group sent the runner off to fetch a /setup.xml the
    // device does not serve, burning the whole 10s HTTP timeout before any
    // send happened. Two other copies were retired to this same call in the
    // change that introduced it; this one is two lines above the hunk that did
    // it. (`lifx` differs from the sender's list too, but inertly: a LIFX
    // action cannot reach a group plan — `kGroupSendableTransports` excludes
    // it — and a LIFX send from the device screen bypasses the sender.)
    bool soap(NetworkActionDto action) =>
        !NetworkCommandSender.isIndependentTransport(action);
    return plan.direct.any((send) => soap(send.action)) ||
        plan.gated.any(
          (toggle) =>
              soap(toggle.action) ||
              toggle.entity.transport == null ||
              toggle.entity.transport == 'soap',
        );
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
          // The screen's sibling read passes these too; a group row that
          // silently could not render its poll would report every paired
          // device as state-unknown.
          values: await sender.currentCredentials(),
        );
        returned = httpStateFields(await sender.sendHttpRequest(request));
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
