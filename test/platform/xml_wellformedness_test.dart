// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The platform config files are XML, and the toolchains that read them are far
// stricter than the lenient readers in platform_config_reader.dart. This file
// guards the gap between the two.
//
// It exists because of a real failure: a permission comment added to
// AndroidManifest.xml contained "power -- so", and `--` is illegal inside an
// XML comment. Every test in this directory passed, because the hand-rolled
// comment stripper simply scans to the next "-->". The Android manifest merger
// does not, and failed the build with "Error parsing AndroidManifest.xml" and
// no line number. A Gradle build is the only other thing that catches this, and
// that runs in CI minutes rather than test seconds.
import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

/// Every platform config file that a build-time XML parser will read.
const _xmlFiles = <String, String>{
  'android/app/src/main/AndroidManifest.xml':
      'the Android manifest merger fails the build outright, naming no line',
  'ios/Runner/Info.plist':
      'Xcode cannot read the app\'s Info.plist, so the build fails and no '
          'usage-description string reaches the OS',
  'ios/Runner/Runner.entitlements':
      'codesign cannot read the entitlements, so the iOS app ships without '
          'the multicast entitlement and the Wi-Fi scan silently finds '
          'nothing',
  'macos/Runner/Info.plist':
      'macOS cannot read the app\'s Info.plist, so no usage-description '
          'string reaches the local-network and Bluetooth prompts',
  'macos/Runner/DebugProfile.entitlements':
      'the debug macOS build loses its entitlements',
  'macos/Runner/Release.entitlements':
      'the release macOS build loses its entitlements',
};

void main() {
  group('platform XML files are well-formed', () {
    _xmlFiles.forEach((path, consequence) {
      test('$path has no "--" inside a comment', () {
        final source = readRepoFile(path, consequence: consequence);
        expect(
          xmlCommentsWithDoubleHyphen(source),
          isEmpty,
          reason: 'XML forbids "--" inside a comment — it is the first half of '
              'the comment terminator. Writing an em-dash as two hyphens in a '
              'prose comment is the usual cause. Consequence if shipped: '
              '$consequence.',
        );
      });

      test('$path tags are balanced', () {
        // A cheap structural check on top of the comment rule: every opening
        // tag is closed, and nothing closes that was never opened. Catches a
        // hand-edit that drops a `</array>` or a `/>`, which the attribute
        // reader in this directory would also happily ignore.
        final source =
            stripXmlComments(readRepoFile(path, consequence: consequence));
        final tags = RegExp(r'<(/?)([\w:.\-]+)([^>]*?)(/?)>')
            .allMatches(source)
            .where((m) => !m.group(2)!.startsWith('?'))
            .where((m) => !m.group(2)!.startsWith('!'));

        final stack = <String>[];
        for (final tag in tags) {
          final isClosing = tag.group(1) == '/';
          final isSelfClosing = tag.group(4) == '/';
          final name = tag.group(2)!;
          if (isSelfClosing) continue;
          if (isClosing) {
            expect(stack, isNotEmpty,
                reason: '$path: </$name> closes a tag that was never opened.');
            expect(stack.removeLast(), name,
                reason: '$path: </$name> does not close the innermost tag.');
          } else {
            stack.add(name);
          }
        }
        expect(stack, isEmpty,
            reason: '$path: unclosed tag(s): ${stack.join(", ")}.');
      });
    });
  });
}
