// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';

/// Minimal [UserFacingException] whose toString is deliberately noisy, so a
/// pass-through of anything but [message] would be caught.
class _KnownFailure implements UserFacingException {
  @override
  final String message;
  const _KnownFailure(this.message);

  @override
  String toString() => 'Internal(_KnownFailure: $message)';
}

void main() {
  test('a UserFacingException message passes through verbatim', () {
    const error = _KnownFailure('Bluetooth is turned off.');
    expect(
      friendlyErrorText(error, fallback: 'fallback text'),
      'Bluetooth is turned off.',
    );
  });

  test('a StateError becomes exactly the fallback', () {
    expect(
      friendlyErrorText(
        StateError('internal detail'),
        context: 'unit test',
        fallback: 'Something went wrong.',
      ),
      'Something went wrong.',
    );
  });

  test('the raw error toString never leaks into the result', () {
    final error = StateError('secret /data/user/0/path errno=13');
    final text = friendlyErrorText(
      error,
      context: 'unit test',
      fallback: 'Could not do the thing.',
    );
    expect(text, isNot(contains(error.toString())));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('Bad state')));
  });
}
