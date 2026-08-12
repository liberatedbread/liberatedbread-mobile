// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The link-button flow as the spec's create_user command states it: poll one
// rendered POST, treat error 101 as "keep waiting", store nothing (the
// caller persists), and fail visibly on everything that is not the button.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/hub_credential_store.dart';
import 'package:liberated_bread_mobile/services/hub_http_client.dart';
import 'package:liberated_bread_mobile/services/hue_pairing_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _keepWaiting =
    '[{"error":{"type":101,"address":"","description":"link button not pressed"}}]';
const _success =
    '[{"success":{"username":"nUP9k2sQ4vG7xB3f","clientkey":"E39B1C9F76A2D48C"}}]';

/// A hub client whose sends answer from a scripted list — the pairing loop
/// only ever calls [sendUnchecked].
class _ScriptedHubClient extends HubHttpClient {
  final List<String> replies;
  final List<HttpRequestDto> sent = [];

  _ScriptedHubClient(this.replies)
      : super(credentials: HubCredentialStore(InMemorySettingsStore()));

  @override
  Future<String> sendUnchecked(
    String host,
    String bridgeId,
    HttpRequestDto request,
  ) async {
    sent.add(request);
    return replies.length == 1 ? replies.first : replies.removeAt(0);
  }
}

void main() {
  final codec = FakeSpecCodec(
    networkHttpRequest: (name, values) => HttpRequestDto(
      method: 'POST',
      path: '/api',
      body: '{"devicetype":"${values['devicetype']}","generateclientkey":true}',
    ),
  );

  HuePairingService service(_ScriptedHubClient client) =>
      HuePairingService(codec: codec, client: client);

  test('polls through 101 until the button press answers with credentials',
      () async {
    final client = _ScriptedHubClient([_keepWaiting, _keepWaiting, _success]);
    final attempts = <int>[];

    final result = await service(client).pair(
      specYaml: 'yaml',
      host: '10.0.0.2',
      bridgeId: 'BRIDGE',
      interval: Duration.zero,
      onAttempt: attempts.add,
    );

    expect(result.username, 'nUP9k2sQ4vG7xB3f');
    expect(result.clientKey, 'E39B1C9F76A2D48C');
    expect(attempts, [1, 2, 3]);
    // The same rendered request every time, carrying the app's devicetype.
    expect(client.sent, hasLength(3));
    expect(client.sent.first.body, contains(HuePairingService.deviceType));
    expect(client.sent.first.body, contains('generateclientkey'));
  });

  test('a window with no button press times out', () async {
    final client = _ScriptedHubClient([_keepWaiting]);
    await expectLater(
      service(client).pair(
        specYaml: 'yaml',
        host: '10.0.0.2',
        bridgeId: 'BRIDGE',
        window: const Duration(milliseconds: 50),
        interval: const Duration(milliseconds: 5),
      ),
      throwsA(isA<PairingTimeoutException>()),
    );
  });

  test('an error that is not 101 fails the flow immediately', () async {
    final client = _ScriptedHubClient([
      '[{"error":{"type":7,"address":"","description":"invalid value"}}]',
    ]);
    await expectLater(
      service(client).pair(
        specYaml: 'yaml',
        host: '10.0.0.2',
        bridgeId: 'BRIDGE',
        interval: Duration.zero,
      ),
      throwsA(isA<HubApiException>().having((e) => e.type, 'type', 7)),
    );
    expect(client.sent, hasLength(1), reason: 'no retry on a real error');
  });

  test('dismissing the sheet cancels the poll', () async {
    final client = _ScriptedHubClient([_keepWaiting]);
    final cancel = Completer<void>();

    final pairing = service(client).pair(
      specYaml: 'yaml',
      host: '10.0.0.2',
      bridgeId: 'BRIDGE',
      interval: const Duration(milliseconds: 5),
      cancelled: cancel.future,
    );
    // Let a poll or two happen, then dismiss.
    await Future<void>.delayed(const Duration(milliseconds: 15));
    cancel.complete();

    await expectLater(pairing, throwsA(isA<PairingCancelledException>()));
  });
}
