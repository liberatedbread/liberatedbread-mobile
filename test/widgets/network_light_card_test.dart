// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/lifx_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/network_light_card.dart';

import '../fakes/fake_spec_codec.dart';

/// A [LifxControlClient] that records sends and never touches a socket, so the
/// card can be driven without a strip on the network. Reads return null (a
/// write-only device), which is the card's own degraded-but-working path.
class _FakeLifxClient extends LifxControlClient {
  final List<({String host, List<int> packet})> sent = [];
  int _seq = 0;

  @override
  int nextSequence() => ++_seq;

  @override
  Future<void> send(String host, Uint8List packet, {int sends = 2}) async {
    sent.add((host: host, packet: packet));
  }

  @override
  Future<Uint8List?> request(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration timeout = const Duration(seconds: 1),
    int retries = 2,
  }) async =>
      null;
}

NetworkActionDto _action(String role, {List<String> params = const []}) =>
    NetworkActionDto(
      role: role,
      commandName: role,
      transport: 'lifx',
      userParams: params,
      readBack: const [],
    );

NetworkEntityDto _lightEntity({bool multizone = false}) => NetworkEntityDto(
      name: 'LIFX Z Multizone Strip',
      platform: 'light',
      stateCommand: '',
      options: const [],
      actions: [
        _action('turn_on'),
        _action('turn_off'),
        _action('set_color',
            params: const ['red', 'green', 'blue', 'brightness']),
        _action('set_color_temperature', params: const ['kelvin']),
        if (multizone)
          _action('set_zone_color',
              params: const ['zone', 'red', 'green', 'blue', 'brightness']),
      ],
    );

Widget _wrap(
        NetworkEntityDto entity, FakeSpecCodec codec, _FakeLifxClient client) =>
    ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(codec),
        lifxControlClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: NetworkLightCard(
            entity: entity,
            specYaml: 'lifx',
            host: '192.168.1.44',
            targetMac: 'd0:73:d5:aa:bb:cc',
          ),
        ),
      ),
    );

void main() {
  testWidgets('power toggle renders turn_on then turn_off over UDP',
      (tester) async {
    final codec = FakeSpecCodec();
    final client = _FakeLifxClient();
    await tester.pumpWidget(_wrap(_lightEntity(), codec, client));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(codec.renderLifxCalls.last.action, 'turn_on');
    expect(codec.renderLifxCalls.last.targetMac, 'd0:73:d5:aa:bb:cc');
    expect(client.sent.single.host, '192.168.1.44');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(codec.renderLifxCalls.last.action, 'turn_off');
    expect(client.sent.length, 2);
  });

  testWidgets('tapping a colour swatch sends set_color with rgb params',
      (tester) async {
    final codec = FakeSpecCodec();
    final client = _FakeLifxClient();
    await tester.pumpWidget(_wrap(_lightEntity(), codec, client));
    await tester.pumpAndSettle();

    // The swatches are the only InkWells on a whole-strip light; tap the first.
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    final call = codec.renderLifxCalls.last;
    expect(call.action, 'set_color');
    expect(call.params.keys,
        containsAll(<String>['red', 'green', 'blue', 'brightness']));
    expect(client.sent, isNotEmpty);
  });

  testWidgets('a brightness slider appears only when set_color carries it',
      (tester) async {
    final codec = FakeSpecCodec();
    final client = _FakeLifxClient();
    await tester.pumpWidget(_wrap(_lightEntity(), codec, client));
    await tester.pumpAndSettle();
    // Two sliders: brightness and colour temperature.
    expect(find.byType(Slider), findsNWidgets(2));
  });
}
