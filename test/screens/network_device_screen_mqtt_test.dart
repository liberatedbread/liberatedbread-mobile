// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The screen's MQTT state-subscription loop: the resubscribe-on-error path and
// the growing, clamped backoff that owns [_mqttRetry]/[_mqttBackoff]. The
// sender's own send/subscribe contract is pinned in
// network_command_sender_test.dart; this pins the SCREEN's retry policy, the
// part that lives entirely in _subscribeMqttState / _scheduleMqttResubscribe.
//
// A fake sender hands back a controllable broadcast stream per subscribe call,
// so the test can error it, deliver on it, or make the subscribe itself throw,
// and the widget's own FakeAsync clock (driven with tester.pump(duration))
// fires the backoff timers — pumpAndSettle is never used, because the 4 s state
// poll and the retry timer never let the tree settle.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/network_device_screen.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/mqtt_session.dart';
import 'package:liberated_bread_mobile/services/network_command_sender.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

/// A sender that stands in for a real MQTT device's: every call the screen's
/// subscribe path makes is answered from memory, and [subscribeMqttState]
/// hands back a fresh single-subscription controller the test drives. Only the
/// methods the MQTT load path touches are overridden — the rest of the base
/// class is never reached, so its transport clients are inert stand-ins.
///
/// Synchronous broadcast: the screen re-subscribes by cancelling the previous
/// subscription and awaiting that cancel before it re-listens. An ordinary
/// controller's cancel future does not complete under the widget test's
/// fake_async (it stalls the re-listen until teardown); a synchronous
/// controller completes cancel synchronously and delivers add/addError
/// synchronously too, so the loop advances on the fake clock. A real
/// MqttSession's stream is likewise a broadcast one.
class _FakeMqttSender extends NetworkCommandSender {
  _FakeMqttSender({required super.codec})
      : super(
          host: 'mqtt.test',
          discoveredControlPort: null,
          devicePort: 1883,
          ssdpTargets: const [],
          specYaml: 'yaml',
          http: HttpControlClient(
              httpClient: MockClient((_) async => http.Response('', 200))),
          soap: SoapControlClient(
              httpClient: MockClient((_) async => http.Response('', 200))),
          kasa: KasaControlClient(codec),
          rabbitAir: RabbitAirControlClient(codec),
          ecp2: Ecp2ControlService(
              connector: (_, __) async =>
                  throw const Ecp2Exception('no ECP2 in this test')),
        );

  /// How many times the screen asked to subscribe — the observable proxy for
  /// "a resubscribe was scheduled AND fired", since [_mqttRetry] is private.
  int subscribeCalls = 0;

  /// One-indexed subscribe attempts that should throw instead of returning a
  /// stream — a broker that is down when the retry dials it.
  final Set<int> throwOnCalls = {};

  /// Once set, every subscribe throws — a broker that stays down. A throw
  /// short-circuits before the screen cancels its previous subscription, so the
  /// original (load) stream stays listened and the whole growing-backoff loop
  /// can be driven from that one stream, without a re-listen whose awaited
  /// cancel would stall the fake clock.
  bool alwaysThrow = false;

  /// The controller handed to each successful subscribe, newest last; the test
  /// errors or delivers on [latest].
  final List<StreamController<MqttMessage>> controllers = [];

  StreamController<MqttMessage> get latest => controllers.last;

  @override
  Future<Map<String, String>> currentCredentials() async => const {};

  // Null keeps the screen off the device-sourced query path (which needs a
  // control port) — this device pushes everything.
  @override
  int? get controlPort => null;

  @override
  Future<Ecp2Session?> openSignedSession() async => null;

  @override
  Future<Stream<MqttMessage>> subscribeMqttState(
      NetworkActionDto? action, List<String> topics) async {
    subscribeCalls++;
    if (alwaysThrow || throwOnCalls.contains(subscribeCalls)) {
      throw const MqttConnectionException('the broker is down');
    }
    final controller = StreamController<MqttMessage>.broadcast(sync: true);
    controllers.add(controller);
    return controller.stream;
  }

  @override
  Future<void> close() async {
    // Not awaited: an awaited close can stall the fake clock, and there is
    // nothing here worth waiting on.
    for (final controller in controllers) {
      unawaited(controller.close());
    }
  }
}

void main() {
  // A readings-only MQTT device: one sensor whose state rides the `mqtt`
  // transport and carries a placeholder-free topic, so declaredTopics is
  // non-empty and the screen actually subscribes.
  const mqttEntity = NetworkEntityDto(
    isInstanced: false,
    name: 'Battery',
    platform: 'sensor',
    transport: NetworkCommandSender.mqttTransport, // 'mqtt'
    stateCommand: 'device/state',
    valueField: 'battery',
    options: [],
    actions: [],
  );

  final device = NetworkDevice(
    host: 'mqtt.test',
    name: 'Push Sensor',
    port: 1883,
    ssdpTargets: const [],
    sources: const {NetworkDiscoverySource.mdns},
    discoveredAt: DateTime.utc(2026),
  );

  late _FakeMqttSender sender;

  /// Mount the screen against the fake sender and let the credential check and
  /// the first load's subscribe resolve — a handful of microtask turns, never a
  /// settle (the state poll and any retry timer never idle).
  Future<void> pumpScreen(WidgetTester tester) async {
    final codec = FakeSpecCodec(networkEntities: (_) => const [mqttEntity]);
    sender = _FakeMqttSender(codec: codec);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(codec),
        networkCommandSenderFactoryProvider.overrideWithValue(({
          required NetworkDevice device,
          required String specYaml,
          NetworkCapabilitiesDto? capabilities,
        }) =>
            sender),
      ],
      child: MaterialApp(
        home: NetworkDeviceScreen(
          device: device,
          controls: const NetworkControls(specYaml: 'yaml', entities: [
            mqttEntity,
          ]),
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  /// Dispose the screen so its state poll and any pending retry timer are
  /// cancelled — a leftover timer fails the test at teardown.
  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
  }

  /// Wait until the screen's listener is actually attached to the newest
  /// stream. A broadcast controller drops an error or message added before a
  /// listener exists, and the re-subscribe attaches its listener a few
  /// microtasks after the subscribe call is counted — so erroring or delivering
  /// without this races the attach and silently loses the event.
  Future<void> awaitListener(WidgetTester tester) async {
    // A non-zero elapse, not a bare pump(): the re-subscribe awaits the
    // previous subscription's cancel(), whose completion the widget test's
    // fake clock only reaches when time actually advances — a zero-duration
    // pump flushes microtasks but never fires that pending completion, so the
    // re-listen would hang.
    for (var i = 0; i < 40 && !sender.latest.hasListener; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(sender.latest.hasListener, isTrue,
        reason: 'the screen never attached its listener to the new stream');
  }

  /// Error the current stream and let the onError handler schedule the retry.
  Future<void> errorStream(WidgetTester tester) async {
    await awaitListener(tester);
    sender.latest.addError(const MqttConnectionException('broker drop'));
    await tester.pump();
    await tester.pump();
  }

  /// Deliver a real reading on the current stream.
  Future<void> deliver(WidgetTester tester, MqttMessage message) async {
    await awaitListener(tester);
    sender.latest.add(message);
    await tester.pump();
    await tester.pump();
  }

  /// Advance the fake clock in small steps up to [backoff], asserting the retry
  /// does not fire early, then confirm it fires at the boundary — proving both
  /// that a retry is pending and that its delay is what the policy says. Small
  /// steps keep the 4 s state poll from sharing an elapse with the retry timer.
  Future<void> expectRetryAt(WidgetTester tester, Duration backoff) async {
    final before = sender.subscribeCalls;
    const step = Duration(milliseconds: 500);
    var elapsed = Duration.zero;
    while (elapsed + step < backoff) {
      await tester.pump(step);
      elapsed += step;
      expect(sender.subscribeCalls, before,
          reason: 'no retry should fire before $backoff (at $elapsed)');
    }
    await tester.pump(backoff - elapsed);
    await tester.pump();
    await tester.pump();
    expect(sender.subscribeCalls, before + 1,
        reason: 'the retry should fire at $backoff');
  }

  /// Assert no retry fires across [window] — the loop has stopped.
  Future<void> expectNoRetryWithin(WidgetTester tester, Duration window) async {
    final before = sender.subscribeCalls;
    await tester.pump(window);
    await tester.pump();
    expect(sender.subscribeCalls, before,
        reason: 'no retry should fire within $window');
  }

  testWidgets('the first load subscribes exactly once', (tester) async {
    await pumpScreen(tester);

    expect(sender.subscribeCalls, 1);
    expect(sender.controllers, hasLength(1));

    await disposeScreen(tester);
  });

  testWidgets('a stream error schedules a resubscribe at the 2 s floor',
      (tester) async {
    await pumpScreen(tester);
    expect(sender.subscribeCalls, 1);
    // The broker stays down so the retry throws rather than re-subscribing —
    // which keeps the load stream listened and avoids a re-listen whose awaited
    // cancel would stall the fake clock. The 2 s scheduling is unaffected.
    sender.alwaysThrow = true;

    await errorStream(tester);
    // The retry has not run yet — only when its 2 s timer fires.
    expect(sender.subscribeCalls, 1);

    await expectRetryAt(tester, const Duration(seconds: 2));

    await disposeScreen(tester);
  });

  testWidgets('the backoff doubles each error and clamps at 30 s',
      (tester) async {
    await pumpScreen(tester);
    // Every retry from here finds the broker still down and throws, which is
    // what re-arms the next attempt — and keeps the load stream listened, so
    // the whole escalation runs without a re-listen.
    sender.alwaysThrow = true;

    // The drop arms the 2 s floor; each throwing retry then doubles it —
    // 2 → 4 → 8 → 16, then 32 clamped to 30, and 30 stays 30.
    await errorStream(tester);
    for (final backoff in const [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
      Duration(seconds: 30),
    ]) {
      await expectRetryAt(tester, backoff);
    }

    await disposeScreen(tester);
  });

  testWidgets('a delivered message resets the backoff to the floor',
      (tester) async {
    await pumpScreen(tester);
    sender.alwaysThrow = true;

    // Grow the backoff: the drop arms 2 s, and the throwing retries take it to
    // 4 then arm 8.
    await errorStream(tester);
    await expectRetryAt(tester, const Duration(seconds: 2)); // throws, arms 4 s
    await expectRetryAt(tester, const Duration(seconds: 4)); // throws, arms 8 s

    // A real reading resets the backoff to zero, even with a retry armed.
    await deliver(
        tester, const MqttMessage('device/state', '{"battery":"77"}'));

    // The armed 8 s retry still fires, but its throw now sees a zero backoff —
    // the first-load case — so it does NOT re-arm, and the escalation stops.
    await expectRetryAt(tester, const Duration(seconds: 8));
    await expectNoRetryWithin(tester, const Duration(seconds: 40));

    // A brand-new drop then starts over at the 2 s floor, not 16 s — the proof
    // the delivery reset the backoff.
    await errorStream(tester);
    await expectRetryAt(tester, const Duration(seconds: 2));

    await disposeScreen(tester);
  });

  testWidgets('a first-load throw does not retry, but a mid-reconnect one does',
      (tester) async {
    // First load throws (backoff still zero): the credentials card is the ask,
    // so the loop must NOT start.
    final codec = FakeSpecCodec(networkEntities: (_) => const [mqttEntity]);
    sender = _FakeMqttSender(codec: codec)..throwOnCalls.add(1);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(codec),
        networkCommandSenderFactoryProvider.overrideWithValue(({
          required NetworkDevice device,
          required String specYaml,
          NetworkCapabilitiesDto? capabilities,
        }) =>
            sender),
      ],
      child: MaterialApp(
        home: NetworkDeviceScreen(
          device: device,
          controls:
              const NetworkControls(specYaml: 'yaml', entities: [mqttEntity]),
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(sender.subscribeCalls, 1,
        reason: 'the throwing first load ran once');

    // No retry is ever scheduled — advancing well past any backoff changes
    // nothing.
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(sender.subscribeCalls, 1,
        reason: 'a first-load throw must not start the retry loop');

    await disposeScreen(tester);
  });

  testWidgets('a mid-reconnect throw keeps the retry loop alive',
      (tester) async {
    await pumpScreen(tester);
    expect(sender.subscribeCalls, 1);

    // The first load succeeded, so every throw from here is mid-reconnect
    // (backoff != zero) — the broker is down when each retry dials it.
    sender.alwaysThrow = true;
    await errorStream(tester); // arms the 2 s retry

    // Each throwing retry re-arms the next instead of the loop dying — the
    // whole point of the mid-reconnect branch of the catch.
    await expectRetryAt(tester, const Duration(seconds: 2)); // throws, arms 4 s
    await expectRetryAt(tester, const Duration(seconds: 4)); // throws, arms 8 s
    await expectRetryAt(tester, const Duration(seconds: 8)); // still alive

    await disposeScreen(tester);
  });

  testWidgets('dispose cancels the pending retry timer', (tester) async {
    await pumpScreen(tester);

    // Leave a retry pending, then tear the screen down. If dispose did not
    // cancel _mqttRetry the leftover timer fails the test at teardown; and the
    // fired-on-a-dead-widget subscribe would push subscribeCalls past 1.
    await errorStream(tester);
    await disposeScreen(tester);

    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(sender.subscribeCalls, 1,
        reason: 'no retry runs once the screen is gone');
    expect(tester.takeException(), isNull);
  });
}
