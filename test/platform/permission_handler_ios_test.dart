// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Regression pin for the iOS BLE outage: BLE was permanently broken on real
// iPhones while CI stayed green.
//
// The chain was: this project was scaffolded on Linux, where flutter_tools
// skips CocoaPods setup, so no ios/Podfile was ever created. permission_handler
// _apple compiles its per-permission strategies conditionally —
// PermissionHandlerEnums.h defaults PERMISSION_BLUETOOTH to 0, which makes
// BluetoothPermissionStrategy an UnknownPermissionStrategy, which answers every
// request with PermissionStatusPermanentlyDenied. Only the Podfile's
// post_install hook can define PERMISSION_BLUETOOTH=1. So
// Permission.bluetooth.request() returned false unconditionally, scan() raised
// BlePermissionDeniedException before CoreBluetooth was ever reached, and iOS
// never showed a prompt. Nothing failed to compile and no test noticed.
//
// The fix was to stop asking permission_handler on iOS at all and let
// CoreBluetooth prompt natively (see RealBleService.requestPermissions), which
// is why ios/Runner/Info.plist's usage strings are now load-bearing — see
// ios_info_plist_test.dart.
//
// This file encodes the conditional invariant that survives either choice:
//   IF any iOS-reachable code asks permission_handler for Bluetooth,
//   THEN ios/Podfile must exist AND define PERMISSION_BLUETOOTH=1.
// It passes on the current tree because no such call exists, and fires the
// moment someone "helpfully" re-adds one without the Podfile.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'permission_usage_scan.dart';
import 'platform_config_reader.dart';

const String _podfilePath = 'ios/Podfile';
const String _bleServicePath = 'lib/services/real_ble_service.dart';

/// Every `.dart` file under `lib/`, as (repo-relative path, contents).
///
/// The whole tree is scanned rather than just [_bleServicePath] because the
/// invariant is about the iOS build, not about one file: a Bluetooth
/// permission request added from a provider or a screen breaks it identically.
Map<String, String> _libSources() {
  final lib = Directory('${repoRoot.path}/lib');
  return {
    for (final entity in lib.listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        entity.path.substring(repoRoot.path.length + 1):
            entity.readAsStringSync(),
  };
}

/// iOS-reachable `Permission.bluetooth` references across `lib/`.
List<String> _iosReachableBluetoothRequests() => [
      for (final entry in _libSources().entries)
        for (final usage in findPermissionUsages(entry.value))
          if (usage.name == 'bluetooth' && !usage.androidGuarded)
            '${entry.key}:${usage.line}',
    ];

void main() {
  group('permission_handler iOS Bluetooth invariant', () {
    test(
        'an iOS-reachable Permission.bluetooth request requires ios/Podfile '
        'with PERMISSION_BLUETOOTH=1', () {
      final callSites = _iosReachableBluetoothRequests();
      if (callSites.isEmpty) {
        // Vacuously satisfied: nothing on the iOS path asks permission_handler
        // for Bluetooth, so the compiled-out strategy cannot be hit. The
        // companion test below pins that this is the deliberate current state.
        return;
      }

      final podfile = repoFile(_podfilePath);
      expect(
        podfile.existsSync(),
        isTrue,
        reason: '$callSites asks permission_handler for Bluetooth on a code '
            'path that runs on iOS, but $_podfilePath does not exist. '
            'permission_handler_apple defaults PERMISSION_BLUETOOTH to 0, '
            'which compiles its Bluetooth strategy out and makes it an '
            'UnknownPermissionStrategy — every request is answered '
            'PermanentlyDenied. On a real iPhone requestPermissions() returns '
            'false unconditionally, scan() raises '
            'BlePermissionDeniedException before CoreBluetooth is reached, '
            'and iOS never shows the permission prompt: BLE is dead and the '
            'user has no way to fix it. Either revert the call (let '
            'CoreBluetooth prompt natively, as RealBleService does today) or '
            'add an ios/Podfile whose post_install hook sets '
            "GCC_PREPROCESSOR_DEFINITIONS to include 'PERMISSION_BLUETOOTH=1'.",
      );

      expect(
        podfile.readAsStringSync(),
        matches(RegExp(r'PERMISSION_BLUETOOTH\s*=\s*1')),
        reason: '$callSites asks permission_handler for Bluetooth on iOS, and '
            '$_podfilePath exists but never defines PERMISSION_BLUETOOTH=1. '
            'Without that macro in the post_install '
            'GCC_PREPROCESSOR_DEFINITIONS, permission_handler_apple compiles '
            'its Bluetooth strategy out and answers every request '
            'PermanentlyDenied, so the app can never scan and iOS never '
            'prompts — the exact silent, CI-invisible failure this test '
            'exists to catch.',
      );
    });

    test('RealBleService still lets CoreBluetooth prompt natively on iOS', () {
      // Documents (and defends) the current fix. If this starts failing, the
      // conditional test above becomes live and the Podfile is now mandatory.
      final usages = findPermissionUsages(
        readRepoFile(
          _bleServicePath,
          consequence: 'It is where the iOS Bluetooth permission decision '
              'lives.',
        ),
      );
      expect(
        usages.where((u) => u.name == 'bluetooth' && !u.androidGuarded),
        isEmpty,
        reason: '$_bleServicePath must not ask permission_handler for '
            'Permission.bluetooth outside the Platform.isAndroid branch. iOS '
            'gets its prompt from CoreBluetooth (raised by flutter_blue_plus '
            'on first scan, backed by the Info.plist usage strings), and a '
            'genuine denial still surfaces as '
            'BluetoothAdapterState.unauthorized. Calling permission_handler '
            'here instead reintroduces the outage: its iOS Bluetooth strategy '
            'is compiled out without a Podfile defining '
            'PERMISSION_BLUETOOTH=1, so the request is answered '
            'PermanentlyDenied and BLE never works on device.',
      );
    });
  });

  // These are the proof that the invariant above can actually fail. The
  // matcher has to distinguish real code from a comment that names the very
  // API it forbids — real_ble_service.dart contains exactly such a comment —
  // so it is worth pinning both directions permanently rather than only
  // hand-checking it once.
  group('usage detector self-tests', () {
    test('a comment naming Permission.bluetooth is not a usage', () {
      const source = '''
class S {
  Future<bool> requestPermissions() async {
    // We must NOT ask permission_handler either: calling
    // Permission.bluetooth.request() here returned false unconditionally.
    /* Permission.bluetooth is also named in a block comment. */
    return true;
  }
}
''';
      expect(
        findPermissionUsages(source).where((u) => u.name == 'bluetooth'),
        isEmpty,
        reason: 'Comments that merely name Permission.bluetooth (as the '
            'explanatory block in $_bleServicePath does) must not be reported '
            'as calls, or the invariant test would demand an ios/Podfile that '
            'the code does not need.',
      );
    });

    test('a string literal naming Permission.bluetooth is not a usage', () {
      const source = '''
final log = 'do not call Permission.bluetooth on iOS';
''';
      expect(
        findPermissionUsages(source).where((u) => u.name == 'bluetooth'),
        isEmpty,
        reason: 'A log message or doc string that names the API is not a call.',
      );
    });

    test('a real iOS-reachable call IS reported', () {
      const source = '''
class S {
  Future<bool> requestPermissions() async {
    final status = await Permission.bluetooth.request();
    return status.isGranted;
  }
}
''';
      final found =
          findPermissionUsages(source).where((u) => u.name == 'bluetooth');
      expect(found, hasLength(1),
          reason: 'A genuine Permission.bluetooth call must be detected — '
              'otherwise the Podfile invariant can never fire and the iOS BLE '
              'outage can be reintroduced unnoticed.');
      expect(found.single.androidGuarded, isFalse);
      // Dart drops the newline immediately after ''' , so `class S {` is line 1
      // and the request is on line 3. Pinned so failure messages keep pointing
      // at the right place in the real file.
      expect(found.single.line, 3);
    });

    test('a call inside if (Platform.isAndroid) is not iOS-reachable', () {
      const source = '''
class S {
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final s = await Permission.bluetooth.request();
      return s.isGranted;
    }
    return true;
  }
}
''';
      final found =
          findPermissionUsages(source).where((u) => u.name == 'bluetooth');
      expect(found, hasLength(1));
      expect(
        found.single.androidGuarded,
        isTrue,
        reason: 'An Android-guarded request cannot run on iOS, so it must not '
            'make the Podfile mandatory.',
      );
    });

    test('bluetoothScan and bluetoothConnect are not Permission.bluetooth', () {
      const source = '''
final statuses = await [
  Permission.bluetoothScan,
  Permission.bluetoothConnect,
].request();
''';
      final names = findPermissionUsages(source).map((u) => u.name).toList();
      expect(names, ['bluetoothScan', 'bluetoothConnect']);
      expect(
        names,
        isNot(contains('bluetooth')),
        reason: 'Prefix-matching Permission.bluetooth against '
            'Permission.bluetoothScan would demand an ios/Podfile for the '
            'Android-only scan permissions the app legitimately requests.',
      );
    });

    test('the real real_ble_service.dart exercises both directions', () {
      // Anti-vacuity: the source really does mention Permission.bluetooth (in
      // its explanatory comment) AND really does request the Android
      // permissions, so this file proves the stripper is doing work rather
      // than the scan finding nothing at all.
      final source = readRepoFile(
        _bleServicePath,
        consequence: 'It is the ground truth for BLE permission behaviour.',
      );
      expect(
        source,
        contains('Permission.bluetooth'),
        reason: 'Expected $_bleServicePath to still discuss '
            'Permission.bluetooth somewhere (today: the comment explaining '
            'why it must not be called on iOS). If that text is gone, this '
            'self-test no longer proves the comment-stripping works and '
            'should be re-pointed at whatever now carries it.',
      );
      final usages = findPermissionUsages(source);
      expect(
        usages.map((u) => u.name),
        containsAll(<String>['bluetoothScan', 'bluetoothConnect']),
        reason: 'The scanner must still find the real Android requests in '
            '$_bleServicePath; finding nothing would make every derived '
            'assertion vacuous.',
      );
      expect(
        usages.where((u) => u.name == 'bluetooth'),
        isEmpty,
        reason: 'The Permission.bluetooth mention in $_bleServicePath is '
            'inside a comment and must not be counted as a call.',
      );
    });
  });
}
