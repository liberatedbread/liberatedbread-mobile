// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Audits android/app/src/main/AndroidManifest.xml against the capabilities the
// Dart code actually uses.
//
// Android answers a runtime permission request for an UNDECLARED permission
// with permanentlyDenied — no dialog, no user recourse. So a manifest that has
// drifted from `requestPermissions()` produces an app that can never scan,
// while every Dart test still passes.
import 'package:flutter_test/flutter_test.dart';

import 'permission_usage_scan.dart';
import 'package:liberated_bread_mobile/services/multicast_lock.dart';

import 'platform_config_reader.dart';

const String _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const String _bleServicePath = 'lib/services/real_ble_service.dart';

/// permission_handler `Permission.<name>` to the manifest entries Android
/// requires before it will even show the prompt.
///
/// Only the permissions this app requests are listed; an unmapped one fails
/// loudly rather than being skipped (see the coverage test below).
const Map<String, List<String>> _permissionToManifestEntries = {
  'bluetoothScan': ['android.permission.BLUETOOTH_SCAN'],
  'bluetoothConnect': ['android.permission.BLUETOOTH_CONNECT'],
  // permission_handler maps locationWhenInUse to the ACCESS_*_LOCATION pair,
  // and BLE scanning on API 23-30 specifically needs the FINE variant: with
  // only COARSE declared, scan results come back empty on those releases.
  'locationWhenInUse': ['android.permission.ACCESS_FINE_LOCATION'],
};

Set<String> _declaredPermissions(String manifest) => {
      for (final element in xmlElementAttributes(manifest, 'uses-permission'))
        if (element['android:name'] != null) element['android:name']!,
    };

void main() {
  late String manifest;
  late Set<String> declared;
  late List<PermissionUsage> androidRequests;

  setUpAll(() {
    manifest = readRepoFile(
      _manifestPath,
      consequence: 'Without it the Android app cannot be built or installed '
          'at all.',
    );
    declared = _declaredPermissions(manifest);
    androidRequests = findPermissionUsages(
      readRepoFile(
        _bleServicePath,
        consequence: 'It is the ground truth for which runtime permissions '
            'the app requests.',
      ),
    ).where((usage) => usage.androidGuarded).toList();
  });

  group('AndroidManifest declares the runtime permissions the code requests',
      () {
    test('the scan of real_ble_service.dart found the Android request block',
        () {
      // Anti-vacuity guard: every dynamic assertion below is derived from this
      // scan, so if the scanner ever silently returns nothing, they would all
      // pass while checking nothing.
      expect(
        androidRequests.map((usage) => usage.name).toSet(),
        containsAll(<String>{
          'bluetoothScan',
          'bluetoothConnect',
          'locationWhenInUse',
        }),
        reason: 'RealBleService.requestPermissions() is expected to request '
            'bluetoothScan, bluetoothConnect and locationWhenInUse inside its '
            'Platform.isAndroid branch. Not finding them means either the code '
            'stopped requesting them (Android BLE scanning then fails at '
            'runtime with a permanentlyDenied status) or this suite\'s source '
            'scan broke and is no longer checking anything.',
      );
    });

    test('every Permission the Android branch requests is mapped here', () {
      final unmapped = androidRequests
          .where(
              (usage) => !_permissionToManifestEntries.containsKey(usage.name))
          .toList();
      expect(
        unmapped,
        isEmpty,
        reason: 'RealBleService.requestPermissions() now asks Android for '
            '$unmapped, which this test does not know how to check. Add the '
            'permission to _permissionToManifestEntries with the '
            '<uses-permission> entry it needs — otherwise a request for an '
            'undeclared permission returns permanentlyDenied on device, with '
            'no system dialog and no way for the user to grant it.',
      );
    });

    test('each requested permission has a <uses-permission> entry', () {
      for (final usage in androidRequests) {
        for (final entry
            in _permissionToManifestEntries[usage.name] ?? const []) {
          expect(
            declared,
            contains(entry),
            reason: '$_bleServicePath requests Permission.${usage.name} '
                '(line ${usage.line}) but $_manifestPath does not declare '
                '$entry. Android refuses the request outright and reports '
                'permanentlyDenied without showing a dialog, so '
                'requestPermissions() returns false, scan() raises '
                'BlePermissionDeniedException, and the user sees a '
                'permission-denied empty state they cannot resolve from '
                'system settings.',
          );
        }
      }
    });

    test('BLE scan/connect and fine location are declared', () {
      // Pinned independently of the source scan so that gutting
      // requestPermissions() cannot make this group vacuously pass.
      expect(
        declared,
        containsAll(<String>[
          'android.permission.BLUETOOTH_SCAN',
          'android.permission.BLUETOOTH_CONNECT',
          'android.permission.ACCESS_FINE_LOCATION',
        ]),
        reason: 'BLUETOOTH_SCAN, BLUETOOTH_CONNECT and ACCESS_FINE_LOCATION '
            'are what Android 12+ needs to discover and talk to a peripheral '
            '(and ACCESS_FINE_LOCATION is what makes scan results non-empty '
            'on API 23-30). Dropping any of them leaves the scan screen '
            'permanently empty on a real phone.',
      );
    });

    test('INTERNET is declared for the Home Assistant client', () {
      expect(
        declared,
        contains('android.permission.INTERNET'),
        reason: 'The Home Assistant client (lib/services/http_ha_api_client'
            '.dart) POSTs registration and webhook payloads over HTTP. Without '
            'android.permission.INTERNET every socket fails with '
            'SocketException: Permission denied, so HA setup can never '
            'complete and sensor forwarding silently stops.',
      );
    });

    test('local-network discovery permissions are declared', () {
      expect(
        declared,
        containsAll(const [
          'android.permission.ACCESS_WIFI_STATE',
          'android.permission.CHANGE_WIFI_MULTICAST_STATE',
        ]),
        reason: 'The Wi-Fi tab (lib/services/real_network_scan_service.dart) '
            'discovers devices over mDNS and SSDP, both of which are IP '
            'multicast. Without CHANGE_WIFI_MULTICAST_STATE the app cannot '
            'take a multicast lock, and the Wi-Fi driver filters multicast '
            'frames out to save power -- so the scan returns nothing at all, '
            'silently, on a real phone.',
      );
    });

    test('MainActivity actually takes the multicast lock', () {
      // The permission only grants the right to take the lock. Declaring it and
      // never calling createMulticastLock is the same outcome as not declaring
      // it -- an empty Wi-Fi scan with nothing in any log -- and the manifest
      // assertion above passes either way, which is exactly how this shipped.
      final activity = readRepoFile(
        'android/app/src/main/kotlin/ca/pigscanfly/liberatedbread/MainActivity.kt',
        consequence: 'It hosts the Flutter engine; without it the Android app '
            'has no entry point.',
      );
      expect(
        activity,
        contains('createMulticastLock'),
        reason: 'MainActivity must create the multicast lock that '
            'CHANGE_WIFI_MULTICAST_STATE authorises, or Android drops every '
            'mDNS and SSDP reply before the app sees it.',
      );
      expect(
        activity,
        contains(MulticastLock.channel.name),
        reason: 'The method-channel name in MainActivity must match '
            'MulticastLock.channel — asserted against the Dart constant '
            'itself, not a third copy of the string, so the two sides cannot '
            'drift together past this test. A mismatch is silent: the Dart '
            'side logs a MissingPluginException and the scan runs unlocked.',
      );
      expect(
        activity,
        contains(RegExp(r'override fun onDestroy\(\)')),
        reason: 'The lock stops the Wi-Fi chip filtering multicast for the '
            'whole device, so a scan torn down without its release reaching '
            'the platform must not leave it held for the process lifetime. '
            '(A smoke check: it proves the override exists, not that it '
            'releases — the release call is one line away and reviewed.)',
      );
    });
  });

  group('AndroidManifest covers the whole minSdk range', () {
    // BLUETOOTH_SCAN/BLUETOOTH_CONNECT only exist on API 31+. Below that,
    // Android gates the same operations behind the legacy BLUETOOTH and
    // BLUETOOTH_ADMIN permissions. flutter_blue_plus_android ships an
    // intentionally empty library manifest, so nothing merges them in for us:
    // if this app's manifest omits them, BluetoothAdapter throws
    // SecurityException on scan and connect for every device below Android 12,
    // which the declared minSdk of 24 promises to support.
    for (final legacy in const [
      'android.permission.BLUETOOTH',
      'android.permission.BLUETOOTH_ADMIN',
    ]) {
      test('$legacy is declared with maxSdkVersion 30', () {
        final declared = xmlElementAttributes(manifest, 'uses-permission')
            .where((e) => e['android:name'] == legacy)
            .toList();
        expect(
          declared,
          hasLength(1),
          reason: '$legacy must be declared. minSdk is 24 '
              '(android/app/build.gradle), but BLUETOOTH_SCAN/'
              'BLUETOOTH_CONNECT only apply from API 31, and '
              'flutter_blue_plus_android deliberately declares no permissions '
              'of its own. Without $legacy, BLE scanning and connecting fail '
              'with SecurityException on Android 7.0 through 11.',
        );
        expect(
          declared.single['android:maxSdkVersion'],
          '30',
          reason: '$legacy must carry android:maxSdkVersion="30" so it is not '
              'requested on Android 12+, where it was replaced by the '
              'BLUETOOTH_SCAN/BLUETOOTH_CONNECT pair.',
        );
      });
    }

    test('minSdk still matches the legacy-permission ceiling', () {
      // If minSdk ever rises above 30, the legacy permissions become dead
      // weight and this whole group should be deleted rather than updated.
      final gradle = repoFile('android/app/build.gradle').readAsStringSync();
      // Both DSL spellings: the Flutter migrator flipped `minSdk` to
      // `minSdkVersion` when it applied the newDsl opt-out.
      final match =
          RegExp(r'minSdk(?:Version)?\s*=\s*(\d+)').firstMatch(gradle);
      expect(match, isNotNull,
          reason: 'Could not read minSdk from android/app/build.gradle.');
      final minSdk = int.parse(match!.group(1)!);
      expect(
        minSdk,
        lessThanOrEqualTo(30),
        reason: 'minSdk is now $minSdk, above the API 30 ceiling of the legacy '
            'BLUETOOTH/BLUETOOTH_ADMIN permissions. Those declarations are now '
            'dead weight — remove them and delete this group.',
      );
    });
  });

  group('AndroidManifest keeps LAN Home Assistant reachable', () {
    test('android:usesCleartextTraffic stays enabled', () {
      // INTENTIONAL, DO NOT "SECURITY-HARDEN" THIS AWAY.
      //
      // Home Assistant on a home LAN is overwhelmingly plain
      // http://192.168.x.x:8123 or http://homeassistant.local:8123, and
      // lib/core/ha_url.dart explicitly classifies and supports those
      // (HaUrlKind.privateLan / HaUrlKind.mdnsLocal), defaulting a
      // scheme-less entry to http://. Android 9+ blocks cleartext by default,
      // and a network-security-config cannot whitelist RFC1918 ranges or
      // .local names by pattern, so app-wide cleartext is the only way to keep
      // LAN HA working. The setup UI is what warns about public http:// URLs.
      final applications = xmlElementAttributes(manifest, 'application');
      expect(
        applications,
        hasLength(1),
        reason: 'Expected exactly one <application> element in '
            '$_manifestPath.',
      );
      expect(
        applications.single['android:usesCleartextTraffic'],
        'true',
        reason: 'android:usesCleartextTraffic must stay "true". This is a '
            'deliberate product requirement, not an oversight: with cleartext '
            'blocked, every request to a plain-http:// LAN Home Assistant '
            '(the common case — see lib/core/ha_url.dart, which supports '
            'RFC1918 and .local addresses) fails on Android 9+ with '
            'CLEARTEXT communication not permitted. HA setup would then only '
            'work for the minority of users who have TLS in front of their '
            'instance.',
      );
    });
  });

  group('AndroidManifest keeps the app installable without BLE hardware', () {
    test('uses-feature bluetooth_le is declared as not required', () {
      final feature = xmlElementAttributes(manifest, 'uses-feature')
          .where((e) => e['android:name'] == 'android.hardware.bluetooth_le')
          .toList();
      expect(
        feature,
        hasLength(1),
        reason: 'android.hardware.bluetooth_le must be declared in '
            '$_manifestPath so Play Store listings and device filtering '
            'reflect that the app uses BLE.',
      );
      expect(
        feature.single['android:required'],
        'false',
        reason: 'android.hardware.bluetooth_le must be required="false". '
            'Declaring it required (or omitting android:required, which '
            'defaults to true) makes Google Play hide the app from every '
            'device without BLE hardware — including emulators and '
            'Chromebooks — even though the Home Assistant half of the app '
            'works fine there.',
      );
    });
  });
}
