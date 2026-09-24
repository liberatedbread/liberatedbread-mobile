// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Mock mode must not reach the network on launch.
//
// Every automated device run — iOS simulator, Android emulator, Linux desktop
// — passes --dart-define=LIBERATED_BREAD_MOCK=true, so anything that fires an
// outbound request under that flag makes those jobs depend on a third-party
// host being up. The ad-banner config fetch did, and the way it failed is why
// this test exists rather than a comment:
//
//   adBannerServiceProvider closes its http.Client when the provider is
//   disposed. Closing it while a connect is still in flight makes dart:io
//   deliver `SocketException: Connection attempt cancelled` to the ZONE as
//   well as to the awaiting future. AdBannerService catches its own copy, so
//   the service looks fine; the zone copy has no owner, and flutter_test
//   blames whichever suite most recently finished:
//
//     ❌ error_flow_test.dart retry re-runs a failing connect
//        (failed after test completion)
//
//   — a test that never touched the network, in a file that has nothing to do
//   with banners. It is timing-dependent, so it spent a while as an
//   intermittent red on the emulator before it became reproducible.
//
// A source-level assertion rather than a behavioural one, deliberately:
// `isMockMode` is a compile-time const and the host `flutter test` run does
// not pass the define, so the mock-mode branch is unreachable from a unit test
// by construction. Reading the source is the only way to check it from here,
// and a wrong-but-loud check beats the silent regression it replaces.
//
// WHAT IT TAKES FOR THAT READING TO MEAN ANYTHING
//
// This asked whether the whole comment-stripped file contained the string
// `isMockMode` — and the file's second line of code is
//
//   import 'ble_provider.dart' show isMockMode;
//
// so the assertion was satisfied by the IMPORT. Deleting the guard on line 159
// and leaving the import (which the analyzer would then flag, but flagging is
// not failing) kept this green. The check now strips directives as well as
// comments, and asks where in the file the name appears: it has to guard the
// refresh, not merely be in scope near it.
import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _adBannerProvider = 'lib/providers/ad_banner_provider.dart';

/// [source] with `import`/`export`/`part` directives removed.
///
/// A directive names identifiers without using them, so leaving them in lets
/// an import satisfy a "the code mentions X" assertion — the exact hole this
/// file closes. Same principle as stripping the comments: prose and
/// declarations must not be able to stand in for code.
String withoutDirectives(String source) => source
    .split('\n')
    .where(
      (line) =>
          !RegExp(r'''^\s*(import|export|part)\s+['"]''').hasMatch(line) &&
          !RegExp(r'^\s*part\s+of\b').hasMatch(line),
    )
    .join('\n');

void main() {
  test('the ad-banner refresh is skipped in mock mode', () {
    // Comment-stripped: the explanation above this guard in the source names
    // isMockMode several times, and prose must not be able to satisfy the
    // assertion — the same trap the ci.yml parser was rewritten to avoid.
    // Directive-stripped: nor may the import that brings the name into scope.
    final source = withoutDirectives(
      stripCommentsKeepingStrings(
        readRepoFile(
          _adBannerProvider,
          consequence:
              'It owns the only launch-time network request the app '
              'makes before the user does anything.',
        ),
      ),
    );

    const reason =
        'AdBannerNotifier.build() must not start the background config '
        'fetch when isMockMode is set. Without that guard every device job '
        'reaches liberatedbread.com on launch, and when the provider is '
        'disposed mid-connect dart:io reports the cancelled socket into the '
        'test zone — surfacing as "failed after test completion" against '
        'whichever integration suite happened to finish last, which is a '
        'failure that names the wrong file and the wrong cause. If the fetch '
        'moved somewhere else, move this assertion with it rather than '
        'deleting it.';

    // The two anchors: where the launch path starts, and the fetch it must not
    // start unguarded. Both are asserted to exist, so a rename fails here
    // loudly instead of making the rest vacuous.
    final buildAt = source.indexOf('build()');
    expect(buildAt, isNot(-1), reason: 'no build() in $_adBannerProvider');
    final refreshAt = source.indexOf('_refresh(', buildAt);
    expect(
      refreshAt,
      isNot(-1),
      reason: 'no _refresh( call after build() in $_adBannerProvider. $reason',
    );

    // The guard: a CONDITION mentioning isMockMode — `if (!isMockMode)` today,
    // and an early `if (isMockMode) return` tomorrow would do as well — and it
    // has to come before the fetch it guards.
    final guard = RegExp(r'if\s*\([^)]*\bisMockMode\b[^)]*\)');
    final guardMatch = guard.allMatches(source).where((m) => m.start > buildAt);
    expect(guardMatch, isNotEmpty, reason: reason);
    expect(
      guardMatch.first.start,
      lessThan(refreshAt),
      reason:
          'isMockMode is tested after the refresh has already been started. '
          '$reason',
    );
  });

  test('an import of isMockMode cannot satisfy that check', () {
    // The regression this file had: proof that the stripping is what makes the
    // assertion above mean something, rather than a comment claiming it does.
    const importOnly = """
import 'ble_provider.dart' show isMockMode;
import 'package:flutter/foundation.dart';

class AdBannerNotifier {
  AdBannerState build() {
    unawaited(_refresh(isDisposed: () => disposed));
    return AdBannerState();
  }
}
""";
    expect(importOnly.contains('isMockMode'), isTrue);
    expect(
      withoutDirectives(importOnly).contains('isMockMode'),
      isFalse,
      reason:
          'withoutDirectives must remove the import that brings isMockMode '
          'into scope; otherwise the guard check passes on a file whose guard '
          'has been deleted.',
    );
  });
}
