// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/core/constants.dart';
import 'package:opengreeniot_mobile/providers/spec_pack_provider.dart';
import 'package:opengreeniot_mobile/screens/spec_pack_settings_screen.dart';
import 'package:opengreeniot_mobile/services/spec_pack_service.dart';

import '../fakes/fake_spec_pack_service.dart';
import '../fakes/in_memory_settings_store.dart';

SpecPack _pack({
  String name = 'Demo Pack',
  String version = '3.1.0',
  int specCount = 1,
}) =>
    SpecPack(
      name: name,
      version: version,
      sourceUrl: 'https://specs.example.com/pack.json',
      specFiles: [for (var i = 0; i < specCount; i++) 'spec$i.yaml'],
      installedAt: DateTime(2026, 7, 11, 9, 30),
    );

Widget _wrap(FakeSpecPackService service) => ProviderScope(
      overrides: [
        prefsSettingsStoreProvider
            .overrideWith((ref) async => InMemorySettingsStore()),
        specPackServiceProvider.overrideWithValue(service),
      ],
      child: const MaterialApp(home: SpecPackSettingsScreen()),
    );

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

  testWidgets('shows a validation error for a non-http URL', (tester) async {
    await tester.pumpWidget(_wrap(FakeSpecPackService()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('valid http'), findsOneWidget);
  });

  testWidgets('installs a pack, then lists it', (tester) async {
    final service = FakeSpecPackService(
      nextResult: InstallOk(_pack(name: 'Fresh Pack', version: '2.0.0')),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField), 'https://specs.example.com/pack.json');
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(service.installedUrls, ['https://specs.example.com/pack.json']);
    expect(find.textContaining('Installed "Fresh Pack"'), findsOneWidget);
    expect(find.textContaining('Fresh Pack'), findsWidgets);
    expect(find.textContaining('v2.0.0'), findsWidgets);
  });

  testWidgets('surfaces a friendly error when the manifest is malformed',
      (tester) async {
    final service = FakeSpecPackService(
      nextResult: const InstallFailed(
          SpecPackError(SpecPackErrorKind.malformedManifest, 'bad manifest')),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField), 'https://specs.example.com/pack.json');
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('did not return a valid'), findsOneWidget);
  });

  testWidgets('reports partial failures after a successful install',
      (tester) async {
    final service = FakeSpecPackService(
      nextResult: InstallOk(
        _pack(name: 'Partial', specCount: 2),
        partialFailures: const [SpecDownloadFailure('missing.yaml', '404')],
      ),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField), 'https://specs.example.com/pack.json');
    await tester.tap(find.text('Install / Refresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 file(s) were skipped'), findsOneWidget);
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

  testWidgets('refresh button re-downloads from the pack\'s own source URL',
      (tester) async {
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

  testWidgets('surfaces an error state when installed packs cannot be read',
      (tester) async {
    // A service whose listInstalledPacks throws must produce a visible error,
    // not an indistinguishable "No packs installed yet."
    final service = _ThrowingListService();
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not read the installed packs'),
        findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('No packs installed yet.'), findsNothing);
  });

  testWidgets('clear-all removes every pack after confirmation',
      (tester) async {
    final service = FakeSpecPackService(packs: [_pack(), _pack(name: 'Two')]);
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Cleared all'), findsOneWidget);
    expect(find.text('No packs installed yet.'), findsOneWidget);
  });
}

/// A fake whose pack listing fails, to exercise the settings error branch.
class _ThrowingListService extends FakeSpecPackService {
  @override
  Future<List<SpecPack>> listInstalledPacks() async =>
      throw Exception('cache unreadable');
}
