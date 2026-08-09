// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Audits ios/Runner/Runner.entitlements and the build settings that carry it
// into the signed app.
//
// Separate from ios_info_plist_test.dart because the failure is a different
// one. A missing Info.plist string is at least loud somewhere: iOS terminates
// the process, or App Store review rejects the build. A missing multicast
// entitlement produces a working app that simply never finds anything over
// Wi-Fi. The sockets bind, the queries go out, the OS drops them, and
// scanFailureFor() reports the silence as a denied local-network permission,
// pointing the user at a Settings toggle that is already on.
//
// Two things have to be true, and the second is the one that rots: the
// entitlement has to be granted in the file, and the file has to be wired into
// EVERY configuration that builds the app. An entitlements file that is
// committed but not referenced by CODE_SIGN_ENTITLEMENTS is not a build error;
// it is a file Xcode ignores.
import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _entitlementsPath = 'ios/Runner/Runner.entitlements';
const String _pbxprojPath = 'ios/Runner.xcodeproj/project.pbxproj';

/// The value `CODE_SIGN_ENTITLEMENTS` must carry, relative to `ios/` (the
/// directory holding the .xcodeproj), exactly as `INFOPLIST_FILE` is.
const String _entitlementsBuildSetting = 'Runner/Runner.entitlements';

/// Set in precisely the app target's build configurations, and in no other
/// target, which is what makes it a reliable count of "configurations that
/// build the app bundle" without parsing the pbxproj.
const String _infoPlistBuildSetting = 'Runner/Info.plist';

void main() {
  group('iOS entitlements grant raw multicast', () {
    late Map<String, Object?> entitlements;

    setUpAll(() {
      entitlements = parsePlist(
        readRepoFile(
          _entitlementsPath,
          consequence: 'Xcode signs the iOS app with this file. Without it '
              'the app has no multicast entitlement, so iOS 14+ silently '
              'drops every mDNS query and SSDP M-SEARCH the Wi-Fi scan sends '
              'and no network device is ever discovered on iPhone or iPad.',
        ),
        label: _entitlementsPath,
      );
    });

    test('grants com.apple.developer.networking.multicast', () {
      expect(
        entitlements['com.apple.developer.networking.multicast'],
        isTrue,
        reason: 'com.apple.developer.networking.multicast must be <true/> in '
            '$_entitlementsPath. Since iOS 14 an app cannot send to or '
            'receive from a multicast or broadcast address over a raw socket '
            'without it. Both halves of the scan in '
            'lib/services/real_network_scan_service.dart do exactly that: '
            '`multicast_dns` binds UDP 5353 and joins 224.0.0.251, and the '
            'SSDP half sends M-SEARCH to 239.255.255.250. NSBonjourServices '
            'does NOT cover this — that key applies to mDNS performed through '
            'the Bonjour APIs, which this code does not use. The failure is '
            'silent: no error, no prompt, just a scan that finds nothing.',
      );
    });
  });

  group('the entitlements file is wired into the build', () {
    late String pbxproj;

    setUpAll(() {
      pbxproj = readRepoFile(
        _pbxprojPath,
        consequence: 'It is what tells Xcode to sign the app with '
            '$_entitlementsPath; without the project file there is no iOS '
            'build at all.',
      );
    });

    int occurrencesOf(String buildSetting, String value) =>
        RegExp('$buildSetting\\s*=\\s*${RegExp.escape(value)}\\s*;')
            .allMatches(pbxproj)
            .length;

    test('CODE_SIGN_ENTITLEMENTS points at the committed file', () {
      expect(
        occurrencesOf('CODE_SIGN_ENTITLEMENTS', _entitlementsBuildSetting),
        greaterThan(0),
        reason: 'No build configuration in $_pbxprojPath sets '
            'CODE_SIGN_ENTITLEMENTS to "$_entitlementsBuildSetting". The '
            'entitlements file can sit in the repo looking correct while '
            'Xcode never reads it, which produces a signed app with no '
            'multicast entitlement and a Wi-Fi scan that finds nothing.',
      );
    });

    test('every configuration that builds the app sets it', () {
      // INFOPLIST_FILE is set once per app-target configuration (Debug,
      // Release, Profile) and nowhere else, so it counts those configurations
      // without parsing the project file. Wiring entitlements into two of the
      // three is the classic shape: discovery works in development and the
      // shipped build is silently deaf, or the reverse, which hides it from
      // developers entirely.
      final withPlist = occurrencesOf('INFOPLIST_FILE', _infoPlistBuildSetting);
      expect(
        withPlist,
        greaterThan(0),
        reason: 'No INFOPLIST_FILE = $_infoPlistBuildSetting found in '
            '$_pbxprojPath, so the app target\'s build configurations cannot '
            'be counted and this check cannot be trusted. Fix the project '
            'file or this assertion, not this line alone.',
      );
      expect(
        occurrencesOf('CODE_SIGN_ENTITLEMENTS', _entitlementsBuildSetting),
        withPlist,
        reason: 'CODE_SIGN_ENTITLEMENTS = $_entitlementsBuildSetting must '
            'appear in all $withPlist build configurations that set '
            'INFOPLIST_FILE = $_infoPlistBuildSetting (Debug, Release and '
            'Profile). A configuration missing it signs an app with no '
            'multicast entitlement, and the only symptom is a Wi-Fi scan that '
            'finds nothing in that configuration.',
      );
    });
  });
}
