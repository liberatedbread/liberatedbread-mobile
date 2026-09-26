// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/byte_inbox.dart';

void main() {
  test('takes exactly what was asked for, across pieces', () async {
    final inbox = ByteInbox()
      ..add([1, 2])
      ..add([3, 4, 5]);
    expect(await inbox.take(4, const Duration(seconds: 1)), [1, 2, 3, 4]);
    expect(await inbox.take(1, const Duration(seconds: 1)), [5]);
  });

  test('waits for bytes still on their way', () async {
    final inbox = ByteInbox();
    final taken = inbox.take(3, const Duration(seconds: 5));
    inbox.add([9]);
    await Future<void>.delayed(Duration.zero);
    inbox.add([8, 7]);
    expect(await taken, [9, 8, 7]);
  });

  test('times out, and keeps what did arrive', () async {
    final inbox = ByteInbox()..add([1]);
    await expectLater(
      inbox.take(2, const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    inbox.add([2]);
    expect(
      await inbox.take(2, const Duration(seconds: 1)),
      [1, 2],
      reason: 'clearing is the caller\'s decision',
    );
  });

  test(
    'clear drops leftovers so they cannot answer the next command',
    () async {
      final inbox = ByteInbox()..add([1, 2, 3]);
      inbox.clear();
      inbox.add([4]);
      expect(await inbox.take(1, const Duration(seconds: 1)), [4]);
    },
  );

  test('a zero-byte take returns at once', () async {
    expect(await ByteInbox().take(0, const Duration(seconds: 1)), isEmpty);
  });
}
