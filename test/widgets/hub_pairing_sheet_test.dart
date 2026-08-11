// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The pairing sheet as a view of the pairing service: it pops with the
// credentials on success, offers another window on timeout, and dismissal
// cancels the poll. The polling loop's own rules (101 keeps waiting, real
// errors fail fast) are covered in hue_pairing_service_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/hub_control_provider.dart';
import 'package:liberated_bread_mobile/services/hub_credential_store.dart';
import 'package:liberated_bread_mobile/services/hub_http_client.dart';
import 'package:liberated_bread_mobile/services/hue_pairing_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/hub_pairing_sheet.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _keepWaiting =
    '[{"error":{"type":101,"address":"","description":"link button not pressed"}}]';
const _success = '[{"success":{"username":"issued-user","clientkey":"ABCD"}}]';

class _ScriptedHubClient extends HubHttpClient {
  final List<String> replies;

  _ScriptedHubClient(this.replies)
      : super(credentials: HubCredentialStore(InMemorySettingsStore()));

  @override
  Future<String> sendUnchecked(
    String host,
    String bridgeId,
    HttpRequestDto request,
  ) async =>
      replies.length == 1 ? replies.first : replies.removeAt(0);
}

void main() {
  Widget wrap(List<String> replies, void Function(PairingResult?) onResult) {
    final codec = FakeSpecCodec(
      networkHttpRequest: (name, values) => const HttpRequestDto(
          method: 'POST', path: '/api', body: '{"devicetype":"t"}'),
    );
    final service = HuePairingService(
      codec: codec,
      client: _ScriptedHubClient(replies),
    );
    return ProviderScope(
      overrides: [huePairingServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  final result = await showModalBottomSheet<PairingResult>(
                    context: context,
                    builder: (_) => const HubPairingSheet(
                      specYaml: 'yaml',
                      host: '10.0.0.2',
                      bridgeId: 'BRIDGE',
                      // Small real-time window: the poll deadline runs on the
                      // wall clock, which widget-test pumps do not advance.
                      window: Duration(milliseconds: 200),
                      interval: Duration(milliseconds: 5),
                    ),
                  );
                  onResult(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('pops with the credentials once the button is pressed',
      (tester) async {
    PairingResult? result;
    var resolved = false;
    await tester.pumpWidget(wrap(
      [_keepWaiting, _success],
      (r) {
        result = r;
        resolved = true;
      },
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.textContaining('link button'), findsOneWidget);

    // First poll answers 101; the second, after one interval, succeeds.
    await tester.pump(const Duration(milliseconds: 5));
    await tester.pumpAndSettle();

    expect(resolved, isTrue);
    expect(result?.username, 'issued-user');
    expect(result?.clientKey, 'ABCD');
  });

  testWidgets('a window with no press offers another one', (tester) async {
    var resolved = false;
    await tester.pumpWidget(wrap([_keepWaiting], (_) => resolved = true));

    await tester.tap(find.text('open'));
    await tester.pump();

    // Poll past the 200 ms wall-clock window.
    for (var i = 0; i < 60 && !resolved; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (find.text('Try again').evaluate().isNotEmpty) break;
    }

    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining("Didn't see the button"), findsOneWidget);
    expect(resolved, isFalse, reason: 'the sheet stays open to retry');

    // Dismiss; nothing was issued.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resolved, isTrue);
  });

  testWidgets('dismissing cancels and yields nothing', (tester) async {
    PairingResult? result = const PairingResult(username: 'sentinel');
    await tester.pumpWidget(wrap([_keepWaiting], (r) => result = r));

    await tester.tap(find.text('open'));
    await tester.pump();
    // Let the sheet finish sliding in before aiming at its Cancel button.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
