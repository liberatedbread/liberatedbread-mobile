// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Audits ios/Runner/PrivacyInfo.xcprivacy and the build wiring that ships it.
//
// This one guards an AUTOMATED gate, which is what makes it different from its
// siblings. A wrong Info.plist string is caught by a human reviewer, days in.
// A missing required-reason API declaration is caught by App Store Connect's
// upload scanner, which walks every Mach-O in the bundle looking for symbols
// on Apple's list and answers with ITMS-91053 before the build is ever
// distributed. The whole submission stops there.
//
// The app's own Swift uses none of those APIs, which is exactly why this was
// missed once already: the Rust core does. cargokit links
// liberated_bread_core.framework from a bare podspec with no Resources, so it
// ships NO privacy manifest of its own, and `nm -u` on the release binary
// lists _stat, _fstat, _lstat and _fstatat — pulled in by Rust std's unix fs
// layer and the `backtrace` crate under flutter_rust_bridge, not by any
// deliberate file I/O in rust/src. Every other embedded framework (Flutter,
// flutter_secure_storage, shared_preferences_foundation, url_launcher_ios,
// permission_handler_apple) carries its own manifest, so the app-level list
// here is the only thing that can cover the Rust core.
//
// Two things have to stay true, and the second is the one that rots: the
// category has to be declared, and the file has to remain a member of the
// Runner target's Copy Bundle Resources phase. A manifest that is committed
// but not bundled is not a build error; it is a file Xcode ignores, and the
// upload fails exactly as if it were absent.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _manifestPath = 'ios/Runner/PrivacyInfo.xcprivacy';
const String _pbxprojPath = 'ios/Runner.xcodeproj/project.pbxproj';

/// Apple's category for the `stat` family. The Rust core imports four of them.
const String _fileTimestampCategory =
    'NSPrivacyAccessedAPICategoryFileTimestamp';

/// "Files inside the app container" — the reason Flutter itself declares for
/// the same symbols, and the accurate one here: nothing in the Rust core
/// touches a user-granted file.
const String _containerFilesReason = 'C617.1';

const String _consequence =
    'App Store Connect scans every binary in the bundle on upload and rejects '
    'a missing required-reason declaration with ITMS-91053, so the submission '
    'in docs/APP_STORE_SUBMISSION.md cannot complete without this file.';

void main() {
  group('iOS privacy manifest declares what the bundle actually uses', () {
    late Map<String, Object?> manifest;

    setUpAll(() {
      manifest = parsePlist(
        readRepoFile(_manifestPath, consequence: _consequence),
        label: _manifestPath,
      );
    });

    test('declares no tracking and collects no data', () {
      expect(
        manifest['NSPrivacyTracking'],
        isFalse,
        reason:
            'NSPrivacyTracking must stay <false/> in $_manifestPath. The '
            'app ships no advertising SDK and no analytics; flipping this '
            'would also require App Tracking Transparency and a '
            'NSUserTrackingUsageDescription that do not exist.',
      );
      expect(
        manifest['NSPrivacyCollectedDataTypes'],
        isEmpty,
        reason:
            'NSPrivacyCollectedDataTypes must stay empty in '
            '$_manifestPath. If the app ever does collect something, this '
            'list and the App Privacy answers in App Store Connect have to '
            'move together — and docs/APP_STORE_SUBMISSION.md has to stop '
            'saying no data leaves the device.',
      );
    });

    // The manifest's comment claims to list every connection beyond the
    // user's own devices, and docs/APP_STORE_SUBMISSION.md Step 7 answers
    // "Data Not Collected" on the strength of that list. It drifted once:
    // the RepeaterBook and myGMRS clients shipped with a location-derived
    // request and the list still stopped at iRobot. Every known outbound
    // client, and every service that pins a third-party `host`, must be
    // named in it by source file.
    test('names every outbound client in its connection list', () {
      final text = readRepoFile(_manifestPath, consequence: _consequence);
      final named = <String>{
        'lib/core/constants.dart',
        'lib/services/spec_pack_service.dart',
        'lib/services/irobot_cloud_service.dart',
        'lib/services/mygmrs_client.dart',
        'lib/services/repeaterbook_client.dart',
      };
      final hostPin = RegExp(r"static const String host = '");
      final services = Directory('${repoRoot.path}/lib/services');
      for (final entity in services.listSync()) {
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            hostPin.hasMatch(entity.readAsStringSync())) {
          named.add('lib/services/${entity.uri.pathSegments.last}');
        }
      }
      for (final path in named) {
        expect(
          text,
          contains(path),
          reason:
              '$_manifestPath must name $path in its list of connections '
              "beyond the user's own devices. Add a bullet there, to Step 7 "
              'of docs/APP_STORE_SUBMISSION.md and its store description, '
              'and to the privacy-page list in docs/RELEASE.md, together; '
              'then decide whether NSPrivacyCollectedDataTypes changes.',
        );
      }
    });

    test('declares the file-timestamp APIs the Rust core imports', () {
      final types = manifest['NSPrivacyAccessedAPITypes'];
      expect(
        types,
        isA<List<Object?>>(),
        reason: 'NSPrivacyAccessedAPITypes must be an array in $_manifestPath.',
      );

      final declared = <String, List<Object?>>{
        for (final entry
            in (types! as List<Object?>).cast<Map<String, Object?>>())
          entry['NSPrivacyAccessedAPIType']! as String:
              (entry['NSPrivacyAccessedAPITypeReasons'] ?? const <Object?>[])
                  as List<Object?>,
      };

      expect(
        declared.keys,
        contains(_fileTimestampCategory),
        reason:
            '$_manifestPath must declare $_fileTimestampCategory. '
            'liberated_bread_core.framework (the Rust core, built by cargokit '
            'from rust_builder/ios/liberated_bread_core.podspec) imports '
            '_stat, _fstat, _lstat and _fstatat via Rust std and the '
            '`backtrace` crate, and ships no privacy manifest of its own, so '
            'this app-level list is the only place they can be declared. '
            'Verify with:\n'
            '  nm -u build/ios/iphoneos/Runner.app/Frameworks/'
            'liberated_bread_core.framework/liberated_bread_core '
            r"| grep -E '^_(stat|fstat|lstat|fstatat)\$'"
            '\n'
            '$_consequence',
      );

      expect(
        declared[_fileTimestampCategory],
        contains(_containerFilesReason),
        reason:
            'The $_fileTimestampCategory declaration in $_manifestPath '
            'must carry reason $_containerFilesReason (files inside the app '
            'container) — the same reason Flutter declares for the same '
            'symbols. Apple rejects an unrecognised or absent reason code as '
            'firmly as a missing category.',
      );
    });

    test('is bundled into the app by the Runner target', () {
      final pbxproj = readRepoFile(
        _pbxprojPath,
        consequence: 'Without the Xcode project there is no iOS app to build.',
      );

      // A manifest that is committed but not in Copy Bundle Resources is not a
      // build error — it is simply absent from the .app, and the upload fails
      // exactly as if the file had never been written. Both halves are needed:
      // the file reference, and its membership in the Resources phase.
      expect(
        pbxproj,
        contains('PrivacyInfo.xcprivacy in Resources'),
        reason:
            'PrivacyInfo.xcprivacy must be a member of the Runner '
            "target's Copy Bundle Resources build phase in $_pbxprojPath, or "
            'it never reaches the app bundle. In Xcode: select the file, and '
            'tick Runner under Target Membership. Confirm in a built app '
            'with:\n'
            '  find build/ios/iphoneos/Runner.app -name PrivacyInfo.xcprivacy'
            '\n$_consequence',
      );
    });
  });
}
