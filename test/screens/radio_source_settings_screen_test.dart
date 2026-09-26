// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart'
    show urlOpenerProvider;
import 'package:liberated_bread_mobile/providers/radio_source_settings_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/radio_source_settings_screen.dart';
import 'package:liberated_bread_mobile/services/repeaterbook_client.dart';

import '../fakes/in_memory_settings_store.dart';

/// RepeaterBook's real refusal bodies. See test/fixtures/radio/README.md.
const _authInvalid =
    '{"ok":false,"error_code":"auth_invalid",'
    '"message":"Invalid user app token format."}';
const _authUnknown =
    '{"ok":false,"error_code":"auth_unknown",'
    '"message":"Unknown token."}';

class _Harness {
  final InMemorySettingsStore prefs;
  final InMemorySettingsStore secure;
  final List<Uri> opened;

  _Harness(this.prefs, this.secure, this.opened);
}

/// This screen is a long scrolling walkthrough, and a ListView does not build
/// what is below the fold. An 800x600 surface would leave steps 2 to 4 -- the
/// whole token flow -- unbuilt and unfindable, so the tests run on a tall
/// window instead of scrolling between every assertion.
void _useTallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// There is no clipboard behind a widget test, and Clipboard.setData throws
/// MissingPluginException rather than quietly doing nothing -- which would
/// swallow the snackbar that follows it.
void _stubClipboard(WidgetTester tester) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => null,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

Future<_Harness> _pump(
  WidgetTester tester, {
  Map<String, String> secure = const {},
  MockClient? client,
  bool openSucceeds = true,
}) async {
  _useTallWindow(tester);
  _stubClipboard(tester);
  final prefsStore = InMemorySettingsStore();
  final secureStore = InMemorySettingsStore({...secure});
  final opened = <Uri>[];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsSettingsStoreProvider.overrideWith((ref) async => prefsStore),
        settingsStoreProvider.overrideWithValue(secureStore),
        if (client != null) radioHttpClientProvider.overrideWithValue(client),
        urlOpenerProvider.overrideWithValue((uri) async {
          opened.add(uri);
          return openSucceeds;
        }),
      ],
      child: const MaterialApp(home: RadioSourceSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(prefsStore, secureStore, opened);
}

void main() {
  testWidgets('lists the sources and says the built-ins always work', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('RepeaterBook'), findsWidgets);
    expect(find.text('myGMRS'), findsOneWidget);
    expect(find.textContaining('always available'), findsOneWidget);
    expect(find.textContaining('No account needed'), findsOneWidget);
  });

  testWidgets('a source can be switched off', (tester) async {
    final harness = await _pump(tester);
    await tester.tap(find.widgetWithText(SwitchListTile, 'myGMRS'));
    await tester.pumpAndSettle();

    expect(
      harness.prefs.values[RadioSourceSettingsNotifier.key],
      contains('mygmrs'),
    );
  });

  testWidgets('the radius can be changed', (tester) async {
    final harness = await _pump(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '160 km').first);
    await tester.pumpAndSettle();

    expect(
      harness.prefs.values[RadioSourceSettingsNotifier.key],
      contains('160'),
    );
  });

  group('the token walkthrough', () {
    testWidgets('explains what the token is and where it lives', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.textContaining('free'), findsWidgets);
      expect(
        find.textContaining('not an account you log into here'),
        findsOneWidget,
      );
      expect(find.textContaining('keychain'), findsOneWidget);
    });

    testWidgets('carries all four steps in order', (tester) async {
      await _pump(tester);
      for (final step in ['1.', '2.', '3.', '4.']) {
        expect(find.textContaining(step), findsWidgets, reason: step);
      }
    });

    testWidgets('opens their token-request page', (tester) async {
      final harness = await _pump(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Request a token'));
      await tester.pumpAndSettle();

      expect(harness.opened, hasLength(1));
      expect(
        harness.opened.single.toString(),
        RepeaterBookClient.tokenRequestUrl,
      );
    });

    testWidgets('says so when the page cannot be opened', (tester) async {
      await _pump(tester, openSucceeds: false);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Request a token'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not open'), findsOneWidget);
    });

    testWidgets('copies the app details their form asks for', (tester) async {
      await _pump(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Copy app details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('copied'), findsOneWidget);
    });

    testWidgets('shows a saved token and marks it saved', (tester) async {
      await _pump(
        tester,
        secure: {RepeaterBookTokenNotifier.key: 'rbuapp_saved'},
      );
      expect(find.text('Saved'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'rbuapp_saved'))
            .controller
            ?.text,
        'rbuapp_saved',
      );
    });

    testWidgets('an empty field is refused before any request', (tester) async {
      var requests = 0;
      await _pump(
        tester,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Save and check'));
      await tester.pumpAndSettle();

      expect(requests, 0);
      expect(find.textContaining('Enter a token first'), findsOneWidget);
    });

    testWidgets('a working token is saved and confirmed', (tester) async {
      final harness = await _pump(
        tester,
        client: MockClient((_) async => http.Response('{"results": []}', 200)),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Access token'),
        'rbuapp_good',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save and check'));
      await tester.pumpAndSettle();

      expect(
        harness.secure.values[RepeaterBookTokenNotifier.key],
        'rbuapp_good',
      );
      expect(find.textContaining('That token works'), findsOneWidget);
    });

    testWidgets('a mis-pasted token says to check the paste', (tester) async {
      // RepeaterBook distinguishes these itself, and they are very different
      // problems: one is a bad copy, the other an expired credential.
      await _pump(
        tester,
        client: MockClient((_) async => http.Response(_authInvalid, 401)),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Access token'),
        'rbuapp_short',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save and check'));
      await tester.pumpAndSettle();

      expect(find.textContaining('did not recognise'), findsOneWidget);
      expect(find.textContaining('rbuapp_'), findsWidgets);
    });

    testWidgets('a refused token says to request a new one', (tester) async {
      await _pump(
        tester,
        client: MockClient((_) async => http.Response(_authUnknown, 401)),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Access token'),
        'rbuapp_stale',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save and check'));
      await tester.pumpAndSettle();

      expect(find.textContaining('refused'), findsOneWidget);
      expect(find.textContaining('request a new one'), findsOneWidget);
    });

    testWidgets('an unreachable service still saves what was pasted', (
      tester,
    ) async {
      // Losing a pasted token because a train went into a tunnel would be its
      // own small disaster, so the save happens before the check.
      final harness = await _pump(
        tester,
        client: MockClient((_) async => throw http.ClientException('offline')),
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Access token'),
        'rbuapp_offline',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save and check'));
      await tester.pumpAndSettle();

      expect(
        harness.secure.values[RepeaterBookTokenNotifier.key],
        'rbuapp_offline',
      );
      expect(find.textContaining('has been saved'), findsOneWidget);
    });

    testWidgets('a token can be removed', (tester) async {
      final harness = await _pump(
        tester,
        secure: {RepeaterBookTokenNotifier.key: 'rbuapp_saved'},
      );

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(
        harness.secure.values.containsKey(RepeaterBookTokenNotifier.key),
        isFalse,
      );
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('carries the attribution their terms require', (tester) async {
      await _pump(tester);
      expect(
        find.textContaining(RepeaterBookClient.attributionLine),
        findsOneWidget,
      );
    });
  });

  testWidgets('offers to clear the cached listings', (tester) async {
    await _pump(tester);
    expect(find.text('Clear cached listings'), findsOneWidget);
    expect(find.textContaining('works offline'), findsOneWidget);
  });
}
