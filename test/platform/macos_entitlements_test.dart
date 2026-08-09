// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Audits the macOS App Sandbox entitlements and Info.plist.
//
// Under the sandbox a missing entitlement is not a build error and not a
// prompt — the API just fails at runtime with an obscure status code. Two
// shipped bugs came from exactly that: no keychain-access-groups meant every
// flutter_secure_storage call returned errSecMissingEntitlement (-34018) so
// the Home Assistant token could neither be saved nor read, and no
// com.apple.security.device.bluetooth meant the Bluetooth radio was invisible
// to the app.
//
// Both entitlement files are checked deliberately: the Debug/Release split is
// precisely how one gets fixed during development and the other ships broken.
import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const Map<String, String> _entitlementFiles = {
  'macos/Runner/DebugProfile.entitlements': 'debug and profile builds '
      '(flutter run -d macos, and every developer\'s local testing)',
  'macos/Runner/Release.entitlements': 'release builds — what users actually '
      'install',
};

const String _macosPlistPath = 'macos/Runner/Info.plist';
const String _appInfoPath = 'macos/Runner/Configs/AppInfo.xcconfig';
const String _expectedBundleId = 'ca.pigscanfly.liberatedbread';

void main() {
  group('macOS entitlements grant what the Dart code needs', () {
    _entitlementFiles.forEach((path, audience) {
      group(path, () {
        late Map<String, Object?> entitlements;

        setUpAll(() {
          entitlements = parsePlist(
            readRepoFile(
              path,
              consequence: 'Xcode signs the macOS app with this file; without '
                  'it the sandboxed app has no Bluetooth, no network and no '
                  'keychain access, so both BLE scanning and Home Assistant '
                  'are dead in $audience.',
            ),
            label: path,
          );
        });

        test('grants com.apple.security.device.bluetooth', () {
          expect(
            entitlements['com.apple.security.device.bluetooth'],
            isTrue,
            reason: 'com.apple.security.device.bluetooth must be <true/> in '
                '$path. The App Sandbox denies Bluetooth hardware to an app '
                'without it, so CBCentralManager reports .unauthorized, '
                'adapterStateError() turns that into '
                'BlePermissionDeniedException, and scanning never finds a '
                'single device in $audience. Nothing warns at build time.',
          );
        });

        test('declares keychain-access-groups', () {
          expect(
            entitlements.containsKey('keychain-access-groups'),
            isTrue,
            reason: 'keychain-access-groups must be declared in $path (an '
                'empty <array/> is enough — it makes the app use its own '
                'default access group). Without the key, flutter_secure_'
                'storage 9.x fails every SecItem* call under the App Sandbox '
                'with errSecMissingEntitlement (-34018): the Home Assistant '
                'long-lived token and webhook id can be neither stored nor '
                'read, so HA setup appears to succeed and then silently '
                'forgets itself on the next launch in $audience. See '
                'lib/services/secure_settings_store.dart.',
          );
          expect(
            entitlements['keychain-access-groups'],
            anyOf(isA<List<Object?>>(), isA<String>()),
            reason: 'keychain-access-groups in $path must be an <array> (or a '
                'string); any other value is not a shape codesign accepts and '
                'the entitlement is dropped, reintroducing the -34018 '
                'keychain failure.',
          );
        });

        test('grants com.apple.security.network.client', () {
          expect(
            entitlements['com.apple.security.network.client'],
            isTrue,
            reason: 'com.apple.security.network.client must be <true/> in '
                '$path. It is what lets a sandboxed app open outbound '
                'connections; without it every Home Assistant request (see '
                'lib/services/http_ha_api_client.dart) fails immediately with '
                'a socket error, so registration and sensor forwarding cannot '
                'work in $audience.',
          );
        });
      });
    });

    test('Debug and Release grant the same capability set', () {
      // The two files legitimately differ (Debug adds allow-jit for the Dart
      // VM service), but a capability the app DEPENDS ON must never be
      // present in only one of them — that is the shape of "worked on my
      // machine, shipped broken".
      //
      // network.server is in this list rather than in the legitimate-drift
      // set, which is where it sat while Release went without it. It is not
      // only the Dart VM service's: the mDNS half of the Wi-Fi scan binds UDP
      // 5353 through `multicast_dns`, and binding a listening socket is
      // exactly what the App Sandbox withholds without it. Debug had it, so
      // discovery worked in `flutter run -d macos` and a release build found
      // only whatever SSDP turned up.
      const required = [
        'com.apple.security.device.bluetooth',
        'com.apple.security.network.client',
        'com.apple.security.network.server',
        'keychain-access-groups',
      ];
      final byFile = {
        for (final path in _entitlementFiles.keys)
          path: parsePlist(
            readRepoFile(path, consequence: 'The macOS app cannot be signed.'),
            label: path,
          ),
      };
      for (final key in required) {
        final missing =
            byFile.entries.where((e) => !e.value.containsKey(key)).map(
                  (e) => e.key,
                );
        expect(
          missing,
          isEmpty,
          reason: '$key is granted in some macOS entitlement files but missing '
              'from $missing. A capability present in only one configuration '
              'is the classic ship-broken bug: it works throughout '
              'development and then fails for every user (or vice versa, '
              'hiding the failure from developers entirely).',
        );
      }
    });
  });

  group('macOS Info.plist carries the usage descriptions', () {
    late Map<String, Object?> plist;

    setUpAll(() {
      plist = parsePlist(
        readRepoFile(
          _macosPlistPath,
          consequence: 'Without it the macOS app has no bundle metadata and '
              'cannot launch.',
        ),
        label: _macosPlistPath,
      );
    });

    void expectNonEmptyString(String key, {required String reason}) {
      final value = plist[key];
      expect(value, isA<String>(), reason: reason);
      expect((value as String? ?? '').trim(), isNotEmpty, reason: reason);
    }

    test('NSBluetoothAlwaysUsageDescription is present and non-empty', () {
      expectNonEmptyString(
        'NSBluetoothAlwaysUsageDescription',
        reason: 'NSBluetoothAlwaysUsageDescription must be a non-empty string '
            'in $_macosPlistPath. macOS 11+ requires it before it will show '
            'the Bluetooth consent alert; without it the app is denied '
            'Bluetooth outright and scanning returns nothing, with the '
            'entitlement looking correct.',
      );
    });

    test('NSBluetoothPeripheralUsageDescription is present and non-empty', () {
      expectNonEmptyString(
        'NSBluetoothPeripheralUsageDescription',
        reason: 'NSBluetoothPeripheralUsageDescription must be a non-empty '
            'string in $_macosPlistPath. It is the key older macOS releases '
            'consult and the one notarisation/App Store review expects from a '
            'CoreBluetooth-linking binary.',
      );
    });

    test('NSLocalNetworkUsageDescription is present and non-empty', () {
      expectNonEmptyString(
        'NSLocalNetworkUsageDescription',
        reason: 'NSLocalNetworkUsageDescription must be a non-empty string in '
            '$_macosPlistPath. macOS Sequoia gates local-network access on '
            'it, so without it requests to a LAN Home Assistant '
            '(http://192.168.x.x:8123 or http://homeassistant.local:8123) are '
            'blocked and HA setup can never complete.',
      );
    });
  });

  group('macOS bundle identity matches ca.pigscanfly.liberatedbread', () {
    test('PRODUCT_BUNDLE_IDENTIFIER is the app id', () {
      // macos/Runner/Info.plist indirects through $(PRODUCT_BUNDLE_IDENTIFIER),
      // so the assertable value lives in the xcconfig.
      final xcconfig = readRepoFile(
        _appInfoPath,
        consequence: 'It defines PRODUCT_BUNDLE_IDENTIFIER, which '
            '$_macosPlistPath expands for CFBundleIdentifier; without it the '
            'macOS app has no bundle id.',
      );
      final match = RegExp(
        r'^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)\s*$',
        multiLine: true,
      ).firstMatch(xcconfig);
      expect(
        match,
        isNotNull,
        reason: '$_appInfoPath must define PRODUCT_BUNDLE_IDENTIFIER; '
            '$_macosPlistPath expands it for CFBundleIdentifier.',
      );
      expect(
        match!.group(1),
        _expectedBundleId,
        reason: 'The macOS bundle id must be "$_expectedBundleId". Changing '
            'it changes the keychain service scope, so every existing install '
            'silently loses its stored Home Assistant token and has to '
            're-register, and it breaks signing against the existing '
            'provisioning profile.',
      );
    });
  });
}
