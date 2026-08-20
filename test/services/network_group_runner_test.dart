// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Wi-Fi group executor end to end against canned HTTP: a discrete off
// goes out and reports, the toggle policy sends only on a reading that
// says "on", and every no-send outcome is an honest per-member skip. The
// planning rules themselves are pinned in group_actions_network_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/network_command_sender.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/saved_network_device_store.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

NetworkActionDto _action(String role) => NetworkActionDto(
      role: role,
      commandName: 'cmd_$role',
      transport: 'http',
      userParams: const [],
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
    );

NetworkEntityDto _powerEntity({
  bool discrete = true,
  bool toggle = false,
  String stateCommand = '',
}) =>
    NetworkEntityDto(
      name: 'Power',
      platform: 'switch',
      stateCommand: stateCommand,
      transport: 'http',
      isInstanced: false,
      options: const [],
      actions: [
        if (discrete) _action('turn_off'),
        if (toggle) _action('toggle'),
      ],
    );

NetworkGroupMember _member(List<NetworkEntityDto> entities,
        {String? specYaml = 'yaml'}) =>
    NetworkGroupMember(
      memberId: 'net:hn:tv.local',
      name: 'Living Room TV',
      category: 'tv',
      record: SavedNetworkDevice(
        id: 'hn:tv.local',
        name: 'Living Room TV',
        lastSeen: DateTime(2026, 1, 1),
        host: '192.0.2.9',
        ssdpPort: 8060,
        ssdpTargets: const ['roku:ecp'],
      ),
      specYaml: specYaml,
      entities: entities,
    );

void main() {
  NetworkGroupRunner runner(
    FakeSpecCodec codec,
    MockClient httpClient,
  ) =>
      NetworkGroupRunner(
        codec: codec,
        soap: SoapControlClient(
            httpClient: MockClient(
                (request) async => fail('no SOAP exchange in this test'))),
        senderFor: ({required device, required specYaml}) =>
            NetworkCommandSender(
          host: device.host,
          controlPort: device.controlPort,
          devicePort: device.port,
          ssdpTargets: device.ssdpTargets,
          specYaml: specYaml,
          codec: codec,
          http: HttpControlClient(httpClient: httpClient),
          soap: SoapControlClient(
              httpClient: MockClient(
                  (request) async => fail('no SOAP exchange in this test'))),
          kasa: KasaControlClient(codec),
          rabbitAir: RabbitAirControlClient(codec),
          ecp2: Ecp2ControlService(
              connector: (host, port) async =>
                  throw const Ecp2Exception('no ECP2 in this test')),
        ),
      );

  Future<GroupRunEvent> lastEventOf(Stream<GroupRunEvent> events) async {
    final all = await events.toList();
    expect(all, isNotEmpty);
    return all.last;
  }

  test('a discrete off is sent and reported', () async {
    final received = <http.Request>[];
    final codec = FakeSpecCodec();
    final events = runner(
      codec,
      MockClient((request) async {
        received.add(request);
        return http.Response('', 200);
      }),
    ).run(
        GroupOp.turnOff,
        [
          _member([_powerEntity()])
        ],
        stop: StopSignal());

    final last = await lastEventOf(events);
    expect(last.status, GroupDeviceStatus.ok);
    expect(last.detail, '1 command sent');
    expect(received.single.url.path, '/fake/cmd_turn_off');
  });

  test('a gated toggle sends only when the reading says on', () async {
    for (final (isOn, sends, status, detail) in [
      (true, 2, GroupDeviceStatus.ok, '1 command sent'),
      (false, 1, GroupDeviceStatus.skipped, 'Already off'),
      (
        null,
        1,
        GroupDeviceStatus.skipped,
        'Power state unknown — the toggle was not sent'
      ),
    ]) {
      final received = <http.Request>[];
      final codec = FakeSpecCodec()
        ..networkReading = (entityName, returned) => isOn == null
            ? null
            : NetworkReadingDto(
                kind: NetworkReadingKind.onOff, isOn: isOn, raw: '$isOn');
      final events = runner(
        codec,
        MockClient((request) async {
          received.add(request);
          return http.Response('{"power": "$isOn"}', 200);
        }),
      ).run(
        GroupOp.turnOff,
        [
          _member([
            _powerEntity(
                discrete: false, toggle: true, stateCommand: 'power_state')
          ])
        ],
        stop: StopSignal(),
      );

      final last = await lastEventOf(events);
      expect(last.status, status, reason: 'isOn=$isOn');
      expect(last.detail, detail, reason: 'isOn=$isOn');
      expect(received, hasLength(sends),
          reason: 'isOn=$isOn: state read${sends == 2 ? " + toggle" : ""}');
    }
  });

  test('a member whose spec never resolved skips honestly', () async {
    final events = runner(FakeSpecCodec(), MockClient((request) async {
      fail('nothing should be sent');
    })).run(GroupOp.turnOff, [_member(const [], specYaml: null)],
        stop: StopSignal());
    final last = await lastEventOf(events);
    expect(last.status, GroupDeviceStatus.skipped);
    expect(last.detail, 'No spec matched this device');
  });

  test('an op the entities do not support skips honestly', () async {
    final events = runner(FakeSpecCodec(), MockClient((request) async {
      fail('nothing should be sent');
    })).run(
        GroupOp.turnOn,
        [
          _member([_powerEntity()])
        ],
        stop: StopSignal());
    final last = await lastEventOf(events);
    expect(last.status, GroupDeviceStatus.skipped);
    expect(last.detail, "Not supported by this device's spec");
  });

  test('read ops sit Wi-Fi members out with a reason', () async {
    final events = runner(FakeSpecCodec(), MockClient((request) async {
      fail('nothing should be sent');
    })).run(
        GroupOp.readBattery,
        [
          _member([_powerEntity()])
        ],
        stop: StopSignal());
    final last = await lastEventOf(events);
    expect(last.status, GroupDeviceStatus.skipped);
    expect(last.detail, 'Not supported for Wi-Fi devices yet');
  });

  test('a stopped run skips members not yet started', () async {
    final stop = StopSignal()..stop();
    final events = runner(FakeSpecCodec(), MockClient((request) async {
      fail('nothing should be sent');
    })).run(
        GroupOp.turnOff,
        [
          _member([_powerEntity()])
        ],
        stop: stop);
    final last = await lastEventOf(events);
    expect(last.status, GroupDeviceStatus.skipped);
    expect(last.detail, 'Cancelled');
  });

  test('a member that fails does not fail its neighbours', () async {
    final codec = FakeSpecCodec();
    final events = runner(
      codec,
      MockClient((request) async => http.Response('nope', 500)),
    ).run(
      GroupOp.turnOff,
      [
        _member([_powerEntity()]),
        _member([_powerEntity()])
      ],
      stop: StopSignal(),
    );
    final all = await events.toList();
    final outcomes = all.where((e) =>
        e.status == GroupDeviceStatus.failed ||
        e.status == GroupDeviceStatus.ok ||
        e.status == GroupDeviceStatus.skipped);
    expect(outcomes, hasLength(2));
    expect(outcomes.every((e) => e.status == GroupDeviceStatus.failed), isTrue);
  });
}
