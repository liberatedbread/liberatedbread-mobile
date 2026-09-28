// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';
import 'package:liberated_bread_mobile/screens/spec_pack_settings_screen.dart';
import 'package:liberated_bread_mobile/services/spec_pack_service.dart';

import '../fakes/fake_spec_pack_service.dart';
import '../fakes/in_memory_settings_store.dart';

SpecPack _pack({
  String name = 'Demo Pack',
  String version = '3.1.0',
  int specCount = 1,
}) => SpecPack(
  name: name,
  version: version,
  sourceUrl: 'https://specs.example.com/pack.json',
  specFiles: [for (var i = 0; i < specCount; i++) 'spec$i.yaml'],
  installedAt: DateTime(2026, 7, 11, 9, 30),
);

Widget _wrap(
  FakeSpecPackService service, {
  Map<String, List<String>> shadowed = const {},
}) => ProviderScope(
  overrides: [
    prefsSettingsStoreProvider.overrideWith(
      (ref) async => InMemorySettingsStore(),
    ),
    specPackServiceProvider.overrideWithValue(service),
    // The real catalogue crosses the FFI; the screen only needs the answer.
    packShadowedBuiltInsProvider.overrideWith(
      (ref, name) async => shadowed[name] ?? const [],
    ),
  ],
  child: const MaterialApp(home: SpecPackSettingsScreen()),
);

/// Holds [install] open until [gate] completes, and counts catalogue reads,
/// so a test can leave the screen mid-download and see what happens after.
class _GatedService extends FakeSpecPackService {
  final gate = Completer<void>();
  int cachedReads = 0;

  _GatedService({super.nextResult});

  @override
  Future<InstallResult> install(String manifestUrl) async {
    await gate.future;
    return super.install(manifestUrl);
  }

  @override
  Future<Map<String, String>> loadCachedSpecs() async {
    cachedReads++;
    return const {};
  }
}

void main() {
  testWidgets('seeds the URL field with the default constant', (tester) async {
    await tester.pumpWidget(_wrap(FakeSpecPackService()));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, AppConstants.defaultSpecPackUrl);
    expect(find.text('No packs installed yet.'), findsOneWidget);
  });

  testWidgets('lists an already-installed pack', (tester) async {
    await tester.pumpWidget(_wrap(FakeSpecPackService(packs: [_pack()])));
    await tester.pumpAndSettle();

    expect(find.textContaining('Demo Pack'), findsOneWidget);
    expect(find.textContaining('v3.1.0'), findsOneWidget);
    expect(find.textContaining('1 spec'), findsOneWidget);
  });

  // "updated" was wrong on a first install, and the hh:mm wrapped onto a
  // line of its own beside the two trailing buttons.
  testWidgets('a pack card says "installed" with the date on one line', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(FakeSpecPackService(packs: [_pack()])));
    await tester.pumpAndSettle();

    final subtitle = find.text('1 spec · installed 2026-07-11');
    expect(subtitle, findsOneWidget);
    expect(tester.widget<Text>(subtitle).maxLines, 1);
    expect(find.textContaining('updated'), findsNothing);
  });

  // An enabled clear-all over an empty list confirmed, then printed
  // "Cleared all installed packs." over nothing.
  testWidgets('clear-all is disabled with no packs installed', (tester) async {
    await tester.pumpWidget(_wrap(FakeSpecPackService()));
    await tester.pumpAndSettle();

    IconButton clearAll() => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_sweep_outlined),
    );
    expect(clearAll().onPressed, isNull);

    await tester.pumpWidget(_wrap(FakeSpecPackService(packs: [_pack()])));
    await tester.pumpAndSettle();
    expect(clearAll().onPressed, isNotNull);
  });

  testWidgets('shows a validation error for a non-http URL', (tester) async {
    await tester.pumpWidget(_wrap(FakeSpecPackService()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    // Not "valid http(s)": plain http is refused off the local network, so
    // the prompt says https and names the one place http is allowed.
    expect(
      find.text(
        'Enter a full https:// address (http:// only for a server on your '
        'own network).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('installs a pack, then lists it', (tester) async {
    final service = FakeSpecPackService(
      nextResult: InstallOk(_pack(name: 'Fresh Pack', version: '2.0.0')),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'https://specs.example.com/pack.json',
    );
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(service.installedUrls, ['https://specs.example.com/pack.json']);
    expect(find.textContaining('Installed "Fresh Pack"'), findsOneWidget);
    expect(find.textContaining('Fresh Pack'), findsWidgets);
    expect(find.textContaining('v2.0.0'), findsWidgets);
  });

  testWidgets('surfaces a friendly error when the manifest is malformed', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      nextResult: const InstallFailed(
        SpecPackError(SpecPackErrorKind.malformedManifest, 'bad manifest'),
      ),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'https://specs.example.com/pack.json',
    );
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('did not return a valid'), findsOneWidget);
  });

  testWidgets('reports partial failures after a successful install', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      nextResult: InstallOk(
        _pack(name: 'Partial', specCount: 2),
        partialFailures: const [SpecDownloadFailure('missing.yaml', '404')],
      ),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'https://specs.example.com/pack.json',
    );
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 file(s) were skipped'), findsOneWidget);
  });

  // Before the fix every mutation returned on `!mounted` BEFORE invalidating,
  // so backing out mid-download left the non-autoDispose catalogue serving
  // the old specs until restart.
  testWidgets('leaving mid-install still refreshes the pack catalogue', (
    tester,
  ) async {
    final service = _GatedService(nextResult: InstallOk(_pack(name: 'Late')));
    final container = ProviderContainer(
      overrides: [
        prefsSettingsStoreProvider.overrideWith(
          (ref) async => InMemorySettingsStore(),
        ),
        specPackServiceProvider.overrideWithValue(service),
        packShadowedBuiltInsProvider.overrideWith(
          (ref, name) async => const <String>[],
        ),
      ],
    );
    addTearDown(container.dispose);
    // Keep the catalogue alive the way deviceSpecsProvider does in the app.
    final sub = container.listen(cachedSpecPacksProvider, (_, _) {});
    addTearDown(sub.close);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SpecPackSettingsScreen(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await container.read(cachedSpecPacksProvider.future);
    final before = service.cachedReads;

    await tester.enterText(
      find.byType(TextField),
      'https://specs.example.com/pack.json',
    );
    await tester.tap(find.text('Install / Refresh'));
    await tester.pump();
    // Back out while the download is still running.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(SpecPackSettingsScreen), findsNothing);

    service.gate.complete();
    await tester.pumpAndSettle();
    await container.read(cachedSpecPacksProvider.future);
    expect(service.cachedReads, greaterThan(before));
  });

  testWidgets('an install names the built-in definitions it replaced', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      nextResult: InstallOk(_pack(name: 'Fixes')),
    );
    await tester.pumpWidget(
      _wrap(
        service,
        shadowed: const {
          'Fixes': ['Enphase Envoy', 'iRobot Roomba'],
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'https://specs.example.com/pack.json',
    );
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'replaces the built-in definitions for: Enphase Envoy, iRobot Roomba',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a pack replacing many built-ins counts them, not lists them', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      nextResult: InstallOk(_pack(name: 'Everything')),
    );
    await tester.pumpWidget(
      _wrap(
        service,
        shadowed: {
          'Everything': [for (var i = 1; i <= 203; i++) 'Device $i'],
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'https://specs.example.com/pack.json',
    );
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'replaces the built-in definitions for 203 devices, among them '
        'Device 1, Device 2, Device 3.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Device 4'), findsNothing);
  });

  // Before the fix a pack saved from a public http:// source got only "no
  // valid source URL", with no hint that https is what is required.
  testWidgets('refresh explains why a saved http source is refused', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      packs: [
        SpecPack(
          name: 'Old',
          version: '1.0.0',
          sourceUrl: 'http://example.com/pack.json',
          specFiles: const ['a.yaml'],
          installedAt: DateTime(2026, 7, 11),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(service.refreshedUrls, isEmpty);
    expect(
      find.textContaining('cannot be updated from its saved address'),
      findsOneWidget,
    );
    expect(find.textContaining('https'), findsWidgets);
  });

  testWidgets('removes a pack from the list', (tester) async {
    final service = FakeSpecPackService(packs: [_pack(name: 'Removable')]);
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    expect(find.textContaining('Removable'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.textContaining('Removed "Removable"'), findsOneWidget);
    expect(find.text('No packs installed yet.'), findsOneWidget);
  });

  testWidgets('surfaces an error when removing a pack fails', (tester) async {
    final service = FakeSpecPackService(
      packs: [_pack(name: 'Stuck')],
      removeError: Exception('disk is read-only'),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // No false "Removed" message; the failure is shown and the pack remains.
    expect(find.textContaining('Could not remove "Stuck"'), findsOneWidget);
    expect(find.textContaining('Removed'), findsNothing);
    expect(find.text('No packs installed yet.'), findsNothing);
    expect(find.textContaining('v3.1.0'), findsOneWidget);
  });

  testWidgets('refresh button re-downloads from the pack\'s own source URL', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      packs: [_pack(name: 'Updatable', version: '1.0.0')],
      nextResult: InstallOk(_pack(name: 'Updatable', version: '1.1.0')),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    // refresh was invoked with the pack's stored sourceUrl (not the URL field).
    expect(service.refreshedUrls, ['https://specs.example.com/pack.json']);
    expect(find.textContaining('Updated "Updatable"'), findsOneWidget);
    expect(find.textContaining('v1.1.0'), findsWidgets);
  });

  testWidgets('surfaces an error state when installed packs cannot be read', (
    tester,
  ) async {
    // A service whose listInstalledPacks throws must produce a visible error,
    // not an indistinguishable "No packs installed yet."
    final service = _ThrowingListService();
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not read the installed packs'),
      findsOneWidget,
    );
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('No packs installed yet.'), findsNothing);
    // Clearing is the way out of an unreadable cache, so it stays enabled.
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.delete_sweep_outlined),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('clear-all removes every pack after confirmation', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      packs: [
        _pack(),
        _pack(name: 'Two'),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Cleared all'), findsOneWidget);
    expect(find.text('No packs installed yet.'), findsOneWidget);
  });

  // R-102: clearCache is best-effort and swallows a failed delete, so its
  // normal return is not evidence anything was removed. The screen used to
  // print "Cleared all installed packs." directly above the packs it had not
  // cleared.
  testWidgets('clear-all reports the packs it could not remove', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      packs: [
        _pack(),
        _pack(name: 'Two'),
      ],
      clearCacheSilentlyFails: true,
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Cleared all'), findsNothing);
    expect(find.textContaining('2 packs could not be removed'), findsOneWidget);
  });

  testWidgets('clear-all names the single pack it could not remove', (
    tester,
  ) async {
    final service = FakeSpecPackService(
      packs: [_pack(name: 'Stubborn')],
      clearCacheSilentlyFails: true,
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not remove "Stubborn"'), findsOneWidget);
  });

  // The destructive confirm used to be a plain FilledButton, styled like any
  // primary action.
  testWidgets('the clear-all confirm uses the error colours', (tester) async {
    await tester.pumpWidget(_wrap(FakeSpecPackService(packs: [_pack()])));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();

    final scheme = Theme.of(
      tester.element(find.byType(AlertDialog)),
    ).colorScheme;
    final style = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Clear all'))
        .style!;
    expect(style.backgroundColor!.resolve({}), scheme.error);
    expect(style.foregroundColor!.resolve({}), scheme.onError);
  });
  // F-018 / F-055: the explicitly-padded ListView ignored MediaQuery.padding
  // (so in landscape the field sat under the notch), and the error/success/
  // empty messages used Colors.red/green/grey literals that fail contrast on
  // the light surface and ignore dark mode.
  group('insets and colour roles', () {
    ColorScheme schemeOf(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(Scaffold))).colorScheme;

    Color? colorOf(WidgetTester tester, Finder finder) =>
        tester.widget<Text>(finder).style?.color;

    testWidgets('the form is inset from the notch side in landscape', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(667, 375);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsSettingsStoreProvider.overrideWith(
              (ref) async => InMemorySettingsStore(),
            ),
            specPackServiceProvider.overrideWithValue(FakeSpecPackService()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: const EdgeInsets.only(left: 59)),
                child: const SpecPackSettingsScreen(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The 59 pt inset plus the list's own 16 pt padding.
      expect(tester.getTopLeft(find.byType(TextField)).dx, closeTo(75, 1));
    });

    testWidgets('empty, error and success messages use theme roles', (
      tester,
    ) async {
      final service = FakeSpecPackService(
        nextResult: InstallOk(_pack(name: 'Fresh Pack', version: '2.0.0')),
      );
      await tester.pumpWidget(_wrap(service));
      await tester.pumpAndSettle();
      final scheme = schemeOf(tester);

      expect(
        colorOf(tester, find.text('No packs installed yet.')),
        scheme.onSurfaceVariant,
      );

      await tester.enterText(find.byType(TextField), 'not-a-url');
      await tester.tap(find.text('Install / Refresh'));
      await tester.pumpAndSettle();
      expect(
        colorOf(tester, find.textContaining('full https://')),
        scheme.error,
      );

      await tester.enterText(
        find.byType(TextField),
        'https://specs.example.com/pack.json',
      );
      await tester.tap(find.text('Install / Refresh'));
      await tester.pumpAndSettle();
      expect(
        colorOf(tester, find.textContaining('Installed "Fresh Pack"')),
        scheme.tertiary,
      );
    });
  });
}

/// A fake whose pack listing fails, to exercise the settings error branch.
class _ThrowingListService extends FakeSpecPackService {
  @override
  Future<List<SpecPack>> listInstalledPacks() async =>
      throw Exception('cache unreadable');
}
