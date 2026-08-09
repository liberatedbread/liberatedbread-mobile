// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Audits ios/Runner/Info.plist against the capabilities the Dart code needs.
//
// iOS is unusually unforgiving here. A missing usage-description string does
// not produce a warning — CoreBluetooth simply refuses to prompt (and UIKit
// terminates the process on some API paths), while App Transport Security
// silently rejects http:// requests. None of that is reachable from a Dart
// test that only exercises logic, and none of it reproduces in the simulator
// paths CI runs.
import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _plistPath = 'ios/Runner/Info.plist';
const String _pbxprojPath = 'ios/Runner.xcodeproj/project.pbxproj';
const String _expectedBundleId = 'ca.pigscanfly.liberatedbread';

void main() {
  late Map<String, Object?> plist;

  setUpAll(() {
    plist = parsePlist(
      readRepoFile(
        _plistPath,
        consequence: 'Without it the iOS app has no bundle metadata and '
            'cannot launch.',
      ),
      label: _plistPath,
    );
  });

  void expectNonEmptyString(String key, {required String reason}) {
    final value = plistValue(plist, [key]);
    expect(value, isA<String>(), reason: reason);
    expect((value as String? ?? '').trim(), isNotEmpty, reason: reason);
  }

  group('iOS Info.plist grants Bluetooth', () {
    // After this session's fix, RealBleService.requestPermissions() returns
    // true on iOS and lets CoreBluetooth raise the system prompt natively
    // (permission_handler's iOS Bluetooth strategy is compiled out without a
    // Podfile — see permission_handler_ios_test.dart). That makes these
    // strings the ONLY thing standing between the user and a prompt: there is
    // no longer a plugin layer that would fail first and produce a
    // recognisable error.
    test('NSBluetoothAlwaysUsageDescription is present and non-empty', () {
      expectNonEmptyString(
        'NSBluetoothAlwaysUsageDescription',
        reason: 'NSBluetoothAlwaysUsageDescription must be a non-empty string '
            'in $_plistPath. Without it iOS never shows the Bluetooth '
            'permission prompt: the CBCentralManager goes straight to '
            '.unauthorized, adapterStateError() maps that to '
            'BlePermissionDeniedException, and the user is stuck on a '
            'permission-denied screen with no way to grant anything. Apple '
            'also rejects the build at App Store submission.',
      );
    });

    test('NSBluetoothPeripheralUsageDescription is present and non-empty', () {
      expectNonEmptyString(
        'NSBluetoothPeripheralUsageDescription',
        reason: 'NSBluetoothPeripheralUsageDescription must be a non-empty '
            'string in $_plistPath. It is the key iOS 12 and earlier consult, '
            'and the one App Store review checks for any binary linking '
            'CoreBluetooth; omitting it means no Bluetooth prompt on older '
            'devices and a submission rejection.',
      );
    });
  });

  group('iOS Info.plist allows LAN Home Assistant over http', () {
    test('NSLocalNetworkUsageDescription is present and non-empty', () {
      expectNonEmptyString(
        'NSLocalNetworkUsageDescription',
        reason: 'NSLocalNetworkUsageDescription must be a non-empty string in '
            '$_plistPath. iOS 14+ requires it before an app may talk to a '
            'device on the local network; without it the local-network prompt '
            'never appears and every request to a LAN Home Assistant '
            '(http://192.168.x.x:8123 or http://homeassistant.local:8123 — '
            'both first-class in lib/core/ha_url.dart) fails, so HA setup can '
            'never complete.',
      );
    });

    test('NSBonjourServices declares the mDNS types the scan asks for', () {
      final services = plistValue(plist, ['NSBonjourServices']);
      expect(
        services,
        isA<List<Object?>>(),
        reason: 'NSBonjourServices must be an array in $_plistPath. iOS 14+ '
            'will not deliver an mDNS answer for a service type absent from '
            'it, and does so SILENTLY -- the scan just returns nothing.',
      );
      expect(
        services as List<Object?>,
        contains('_services._dns-sd._udp'),
        reason: 'The DNS-SD meta-query is how the Wi-Fi scan enumerates '
            'service types it has no spec for (see the enumeration query in '
            'lib/services/real_network_scan_service.dart). Without it '
            'declared, iOS discovers only the specific types listed and the '
            'scan can never find unknown hardware.',
      );
    });

    test('NSAppTransportSecurity enables NSAllowsLocalNetworking', () {
      expect(
        plistValue(
            plist, ['NSAppTransportSecurity', 'NSAllowsLocalNetworking']),
        isTrue,
        reason: 'NSAppTransportSecurity > NSAllowsLocalNetworking must be '
            '<true/> in $_plistPath. App Transport Security blocks plain '
            'http:// by default, so without this exemption every POST to a '
            'LAN Home Assistant is refused before it leaves the device and HA '
            'registration fails with a connection error the user cannot fix.',
      );
    });

    test('NSAppTransportSecurity does NOT set NSAllowsArbitraryLoads', () {
      // NSAllowsLocalNetworking is the scoped exemption: it re-enables
      // cleartext for LAN destinations only. NSAllowsArbitraryLoads disables
      // ATS for the whole internet, buys nothing extra for this app's use
      // case, and triggers an App Store justification review.
      expect(
        plistHasKey(
            plist, ['NSAppTransportSecurity', 'NSAllowsArbitraryLoads']),
        isFalse,
        reason: 'NSAppTransportSecurity > NSAllowsArbitraryLoads must not be '
            'set in $_plistPath. NSAllowsLocalNetworking already covers the '
            'LAN Home Assistant case; NSAllowsArbitraryLoads additionally '
            'disables transport security for every public host — so a '
            'user\'s remote HA token could be sent over unencrypted http to '
            'the internet — and it forces an App Store review justification.',
      );
    });
  });

  group('iOS bundle identity matches ca.pigscanfly.liberatedbread', () {
    test('CFBundleIdentifier resolves to the app id', () {
      final identifier = plistValue(plist, ['CFBundleIdentifier']);
      expect(
        identifier,
        isA<String>(),
        reason: 'CFBundleIdentifier must be present in $_plistPath; iOS will '
            'not install a bundle without one.',
      );
      final value = identifier! as String;

      if (value != r'$(PRODUCT_BUNDLE_IDENTIFIER)') {
        // Hard-coded in the plist: assert it directly.
        expect(
          value,
          _expectedBundleId,
          reason: 'CFBundleIdentifier in $_plistPath is hard-coded to "$value" '
              'rather than "$_expectedBundleId". A bundle id mismatch breaks '
              'provisioning-profile matching (the build fails to sign) and, '
              'once shipped, orphans every existing install\'s keychain items '
              '— users would silently lose their stored Home Assistant token.',
        );
        return;
      }

      // The Flutter template indirects through the build setting, so the
      // assertable truth lives in the Xcode project instead. Test targets get
      // their own suffixed id; only the app target must match.
      final pbxproj = readRepoFile(
        _pbxprojPath,
        consequence: 'CFBundleIdentifier in $_plistPath expands '
            r'$(PRODUCT_BUNDLE_IDENTIFIER), which is defined there, so the '
            'app id cannot be verified without it.',
      );
      final ids = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;\s]+)\s*;')
          .allMatches(pbxproj)
          .map((m) => m.group(1)!)
          .where((id) => !id.endsWith('.RunnerTests'))
          .toSet();

      expect(
        ids,
        isNotEmpty,
        reason: 'CFBundleIdentifier in $_plistPath expands '
            r'$(PRODUCT_BUNDLE_IDENTIFIER), but no PRODUCT_BUNDLE_IDENTIFIER '
            'build setting was found in $_pbxprojPath, so the shipped bundle '
            'id is unverifiable and could be anything.',
      );
      expect(
        ids,
        {_expectedBundleId},
        reason: 'The iOS app target must build as "$_expectedBundleId" '
            '(found: $ids in $_pbxprojPath). A bundle id mismatch breaks '
            'provisioning-profile matching at signing time and, once shipped, '
            'changes the keychain service scope — every existing install '
            'silently loses its stored Home Assistant token and has to '
            're-register.',
      );
    });
  });
}
