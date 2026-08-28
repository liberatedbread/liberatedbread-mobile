// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/models/suggested_channel.dart';
import 'package:liberated_bread_mobile/providers/radio_suggestion_provider.dart';
import 'package:liberated_bread_mobile/services/channel_suggestion_service.dart';
import 'package:liberated_bread_mobile/services/radio_bundled_data.dart';
import 'package:liberated_bread_mobile/services/radio_source_cache.dart';
import 'package:liberated_bread_mobile/services/repeater_source.dart';

import '../fakes/fake_repeater_source.dart';

const _hartford = GeoPoint(41.7658, -72.6734);

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('suggestion_provider_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  ProviderContainer containerWith(FakeRepeaterSource source) {
    final container = ProviderContainer(overrides: [
      channelSuggestionServiceProvider.overrideWithValue(
        ChannelSuggestionService(
          sources: [source],
          cache: RadioSourceCache(cacheDirResolver: () async => temp),
          bundled: RadioBundledData(),
        ),
      ),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  FakeRepeaterSource sourceWithOne() => FakeRepeaterSource(id: 'test', byState: {
        'CT': [
          const RepeaterListing(
            channel: RadioChannel(
              name: 'W1AW',
              rxFreqHz: 146940000,
              txFreqHz: 146340000,
            ),
            category: SuggestionCategory.repeater,
            location: _hartford,
          ),
        ],
      });

  SuggestionRequest request({bool unlock = false, double radiusKm = 40}) =>
      SuggestionRequest(
        where: _hartford,
        radiusKm: radiusKm,
        profile: uv5rProfile,
        enabledSourceIds: const {'test'},
        txUnlockEnabled: unlock,
      );

  test('resolves a result for a request', () async {
    final container = containerWith(sourceWithOne());
    final result =
        await container.read(radioSuggestionProvider(request()).future);
    expect(result.repeaters, hasLength(1));
    expect(result.presets, isNotEmpty);
  });

  test('an equal-but-new request reuses the result rather than refetching',
      () async {
    // This is what the value equality on SuggestionRequest is for. A rebuild
    // that hands over a fresh instance must not re-run every HTTP fetch.
    final source = sourceWithOne();
    final container = containerWith(source);

    await container.read(radioSuggestionProvider(request()).future);
    final afterFirst = source.fetched.length;
    await container.read(radioSuggestionProvider(request()).future);

    expect(source.fetched.length, afterFirst);
    expect(request(), request());
    expect(request().hashCode, request().hashCode);
  });

  test('a different request is a different entry', () async {
    final source = sourceWithOne();
    final container = containerWith(source);

    await container.read(radioSuggestionProvider(request()).future);
    await container
        .read(radioSuggestionProvider(request(radiusKm: 160)).future);

    // Two distinct family keys, so two runs -- though the second may still be
    // served from the disk cache for states the first already fetched.
    expect(request(), isNot(request(radiusKm: 160)));
  });

  test('a failing source surfaces as a result, not as a provider error',
      () async {
    // The screen must render something: the presets are always there, and the
    // failure is a row in the list rather than a red error state.
    final broken = FakeRepeaterSource(
      id: 'test',
      failure: const SourceFailure(
        sourceId: 'test',
        displayName: 'Test',
        kind: SourceFailureKind.network,
        message: 'offline',
      ),
    );
    final container = containerWith(broken);

    final result =
        await container.read(radioSuggestionProvider(request()).future);
    expect(result.sourceFailures, hasLength(1));
    expect(result.presets, isNotEmpty);
  });

  test('the service provider is wired to the real sources by default', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(channelSuggestionServiceProvider),
        isA<ChannelSuggestionService>());
  });
}
