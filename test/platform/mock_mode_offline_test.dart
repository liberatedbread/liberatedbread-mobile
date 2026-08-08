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
import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _adBannerProvider = 'lib/providers/ad_banner_provider.dart';

void main() {
  test('the ad-banner refresh is skipped in mock mode', () {
    // Comment-stripped: the explanation above this guard in the source names
    // isMockMode several times, and prose must not be able to satisfy the
    // assertion — the same trap the ci.yml parser was rewritten to avoid.
    final source = stripCommentsKeepingStrings(
      readRepoFile(
        _adBannerProvider,
        consequence: 'It owns the only launch-time network request the app '
            'makes before the user does anything.',
      ),
    );

    expect(
      source.contains('isMockMode'),
      isTrue,
      reason: 'AdBannerNotifier.build() must not start the background config '
          'fetch when isMockMode is set. Without that guard every device job '
          'reaches liberatedbread.com on launch, and when the provider is '
          'disposed mid-connect dart:io reports the cancelled socket into the '
          'test zone — surfacing as "failed after test completion" against '
          'whichever integration suite happened to finish last, which is a '
          'failure that names the wrong file and the wrong cause. If the fetch '
          'moved somewhere else, move this assertion with it rather than '
          'deleting it.',
    );
  });
}
