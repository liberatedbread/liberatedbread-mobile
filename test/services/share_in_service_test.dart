// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// ShareInService: the Dart half of "Share → Liberated Bread". The native side
// is exercised by the Android build; this pins the channel contract.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/share_in_service.dart';

const _channel = MethodChannel('ca.pigscanfly.liberatedbread/share_in');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test('the launch share is decoded once', () async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'initialShare');
      return {
        'bytes': Uint8List.fromList([1, 2, 3]),
        'mime': 'application/pdf',
        'name': 'label.pdf',
      };
    });
    final service = ShareInService();
    addTearDown(service.dispose);
    final file = await service.initialShare();
    expect(file!.bytes, [1, 2, 3]);
    expect(file.mime, 'application/pdf');
    expect(file.name, 'label.pdf');
  });

  test('no share, an empty share, or no handler is null', () async {
    final service = ShareInService();
    addTearDown(service.dispose);
    // No handler at all (Linux, iOS before "Open in" lands).
    expect(await service.initialShare(), isNull);

    messenger.setMockMethodCallHandler(_channel, (_) async => null);
    expect(await service.initialShare(), isNull);

    messenger.setMockMethodCallHandler(
      _channel,
      (_) async => {'bytes': Uint8List(0)},
    );
    expect(await service.initialShare(), isNull);
  });

  test('a share while running arrives on the stream', () async {
    final service = ShareInService();
    addTearDown(service.dispose);
    final next = service.incoming.first;
    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
        MethodCall('shared', {
          'bytes': Uint8List.fromList([9]),
          'mime': 'image/png',
        }),
      ),
      (_) {},
    );
    final file = await next.timeout(const Duration(seconds: 1));
    expect(file.bytes, [9]);
    expect(file.name, isNull);
  });

  // Before the fix the handler went in when the home shell mounted, so a
  // share while the terms screen was up reached no handler and was lost.
  test('a share with nobody listening is held for the listener', () async {
    final service = ShareInService();
    addTearDown(service.dispose);
    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
        MethodCall('shared', {
          'bytes': Uint8List.fromList([7]),
        }),
      ),
      (_) {},
    );
    final held = service.takeWaiting();
    expect(held!.bytes, [7]);
    expect(service.takeWaiting(), isNull, reason: 'handed over once');
  });
}
