// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Cross-checks ios/Runner/Info.plist's NSBonjourServices allow-list against the
// mDNS service types the bundled device catalogue actually names.
//
// This is a sync check, not a config audit, which is why it lives apart from
// ios_info_plist_test.dart: the allow-list is hand-written and the catalogue
// arrives by `git subtree pull`, so the two drift apart every time a Wi-Fi spec
// is added upstream. iOS 14+ withholds mDNS answers for an undeclared type
// SILENTLY, so the drift shows up as "that device just never appears on iOS"
// with nothing in any log — the failure mode this whole directory exists for.
//
// It caught four missing types at the time it was written (_smartthings._tcp,
// _airplay._tcp, _dyson_mqtt._tcp, _ankivector._tcp), i.e. four product
// families whose specs shipped in the app and could never be discovered on iOS.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _plistPath = 'ios/Runner/Info.plist';
const String _devicesDir = 'vendor/protocol-specs/device-specs/devices';

/// `mdns_service_type:` under a spec's `identification` block. Deliberately not
/// `service_type:`, which is the same value nested under `discovery.methods[]`
/// — the scan path reads identification, so that is what has to be declared.
final RegExp _mdnsServiceType =
    RegExp(r'''^\s*mdns_service_type:\s*["']?([^"'\n#]+)''', multiLine: true);

/// Reduce a DNS-SD type to the form NSBonjourServices wants: lowercase, no
/// trailing dot, no `.local` suffix. Mirrors `normalize_service_type` in
/// rust/src/api/device_api.rs, because a mismatch in either direction is a
/// device that does not appear.
String _normalize(String raw) {
  final lower = raw.trim().replaceAll(RegExp(r'\.+$'), '').toLowerCase();
  return lower.endsWith('.local')
      ? lower.substring(0, lower.length - '.local'.length)
      : lower;
}

void main() {
  test('NSBonjourServices covers every mDNS type in the bundled catalogue', () {
    final plist = parsePlist(
      readRepoFile(
        _plistPath,
        consequence: 'Without it the iOS app has no bundle metadata and '
            'cannot launch.',
      ),
      label: _plistPath,
    );
    final declared = (plistValue(plist, ['NSBonjourServices']) as List<Object?>)
        .whereType<String>()
        .map(_normalize)
        .toSet();

    final specsDir = Directory('${repoRoot.path}/$_devicesDir');
    expect(
      specsDir.existsSync(),
      isTrue,
      reason: '$_devicesDir must exist. It is the vendored protocol-specs '
          'subtree, and it is what the app bundles as its catalogue — if it '
          'is missing the app ships no specs at all.',
    );

    final wanted = <String, List<String>>{};
    for (final file in specsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yaml'))) {
      for (final match
          in _mdnsServiceType.allMatches(file.readAsStringSync())) {
        wanted
            .putIfAbsent(_normalize(match.group(1)!), () => <String>[])
            .add(file.uri.pathSegments.last);
      }
    }
    expect(
      wanted,
      isNotEmpty,
      reason: 'No spec in $_devicesDir declares an mdns_service_type, which '
          'means this check is reading the wrong place and is silently '
          'passing rather than checking anything.',
    );

    final missing = wanted.keys.where((t) => !declared.contains(t)).toList()
      ..sort();
    expect(
      missing,
      isEmpty,
      reason: 'These mDNS service types are named by bundled device specs but '
          'are absent from NSBonjourServices in $_plistPath:\n'
          '${missing.map((t) => '  $t  (${wanted[t]!.join(', ')})').join('\n')}\n'
          'iOS 14+ will not deliver an mDNS answer for an undeclared type and '
          'fails SILENTLY, so those devices can never be discovered or matched '
          'on iOS even though their specs ship with the app. Add each type to '
          'the array (no trailing dot, no .local suffix).',
    );
  });
}
