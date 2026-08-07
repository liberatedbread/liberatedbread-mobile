// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/ad_banner_service.dart';

const _url = 'https://liberatedbread.com/app/banner.json';

const _validJson = '{"version": 1, "banner": {"id": "promo-1", '
    '"message": "Buy dead devices cheap.", '
    '"url": "https://liberatedbread.com/shop/"}}';

AdBannerService _service(MockClientHandler handler, {Duration? timeout}) =>
    AdBannerService(
      client: MockClient(handler),
      timeout: timeout ?? const Duration(seconds: 10),
    );

void main() {
  test('fetches and parses a valid config', () async {
    Uri? requested;
    final service = _service((request) async {
      requested = request.url;
      return http.Response(_validJson, 200);
    });

    final result = await service.fetch(_url);

    expect(requested, Uri.parse(_url));
    result as AdBannerFetchOk;
    expect(result.config.banner?.id, 'promo-1');
    expect(result.rawJson, _validJson);
  });

  test('refuses to fetch anything but https', () async {
    var called = false;
    final service = _service((_) async {
      called = true;
      return http.Response(_validJson, 200);
    });

    expect(await service.fetch('http://liberatedbread.com/app/banner.json'),
        isA<AdBannerFetchFailed>());
    expect(await service.fetch('not a url'), isA<AdBannerFetchFailed>());
    expect(await service.fetch(''), isA<AdBannerFetchFailed>());
    expect(called, isFalse);
  });

  test('reports non-2xx as a failure', () async {
    final service = _service((_) async => http.Response('gone', 404));

    expect(await service.fetch(_url), isA<AdBannerFetchFailed>());
  });

  test('reports a network error as a failure, never throws', () async {
    final service =
        _service((_) => throw http.ClientException('connection refused'));

    expect(await service.fetch(_url), isA<AdBannerFetchFailed>());
  });

  test('times out a stalled request', () async {
    final service = _service(
      (_) => Completer<http.Response>().future,
      timeout: const Duration(milliseconds: 50),
    );

    expect(await service.fetch(_url), isA<AdBannerFetchFailed>());
  });

  test('rejects an oversized body', () async {
    final big = '{"version": 1, "pad": "${'x' * AdBannerService.maxConfigBytes}"}';
    final service = _service((_) async => http.Response(big, 200));

    expect(await service.fetch(_url), isA<AdBannerFetchFailed>());
  });

  test('rejects a body that is not valid UTF-8', () async {
    final service = _service((_) async =>
        http.Response.bytes([0xff, 0xfe, 0x00, 0x01], 200));

    expect(await service.fetch(_url), isA<AdBannerFetchFailed>());
  });

  test('rejects malformed config JSON', () async {
    final service = _service((_) async => http.Response('{"nope": 1}', 200));

    expect(await service.fetch(_url), isA<AdBannerFetchFailed>());
  });

  test('a valid config with no banner is a successful fetch', () async {
    // The remote kill switch must reach the caller as data, not be mistaken
    // for an error (which would leave the old banner up).
    final disabled = jsonEncode({'version': 1});
    final service = _service((_) async => http.Response(disabled, 200));

    final result = await service.fetch(_url);

    result as AdBannerFetchOk;
    expect(result.config.banner, isNull);
  });
}
