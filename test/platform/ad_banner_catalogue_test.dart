// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Catalogue-vs-code guard for the bundled targeted ad banners.
//
// AdBanner.bundledTargets hardcodes `specKeyFor` identities
// ("<deviceName>|<manufacturer>") to target promotions at specific devices.
// Those strings are a closed copy of open catalogue data: if a spec's
// device.name or device.manufacturer is renamed upstream, the bundled key
// silently stops matching and the promo goes dark with no test failing — the
// project's recurring closed-table-vs-open-catalogue drift. This asserts every
// bundled spec key still resolves to a real spec in the vendored catalogue,
// except keys explicitly recorded as pending an upstream spec.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ad_banner.dart';

import 'platform_config_reader.dart';

const String _devicesDir = 'vendor/protocol-specs/device-specs/devices';

// The device: block, and the top-level (exactly-two-space-indented) name /
// manufacturer within it — deeper-indented variant names do not match.
final RegExp _deviceBlock =
    RegExp(r'^device:\n(?:[ \t].*\n|\n)*', multiLine: true);
final RegExp _name = RegExp(r'^  name:\s*(.+)$', multiLine: true);
final RegExp _manufacturer =
    RegExp(r'^  manufacturer:\s*(.+)$', multiLine: true);

/// Spec keys deliberately not in the catalogue yet — the promotion ships ahead
/// of the device spec. Each MUST carry a reason; remove the entry once the spec
/// lands (the test then holds it to the real catalogue).
const Map<String, String> _pendingSpecKeys = {
  'eufyMake E1 UV Printer|eufy (Anker Innovations)':
      'No eufy-make-e1 spec in the catalogue yet; the UV-ink promo is staged '
          'for when it lands.',
};

String _unquote(String raw) {
  var v = raw.trim();
  // Strip a trailing unquoted comment.
  if (!v.startsWith('"') && !v.startsWith("'")) {
    final hash = v.indexOf(' #');
    if (hash >= 0) v = v.substring(0, hash).trim();
  }
  if (v.length >= 2 &&
      ((v.startsWith('"') && v.endsWith('"')) ||
          (v.startsWith("'") && v.endsWith("'")))) {
    v = v.substring(1, v.length - 1);
  }
  return v.trim();
}

void main() {
  test('every bundled targeted-banner spec key resolves in the catalogue', () {
    final specsDir = Directory('${repoRoot.path}/$_devicesDir');
    expect(specsDir.existsSync(), isTrue,
        reason: '$_devicesDir (the vendored catalogue) must exist.');

    final catalogueKeys = <String>{};
    for (final file in specsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yaml'))) {
      final text = file.readAsStringSync();
      final block = _deviceBlock.firstMatch(text)?.group(0);
      if (block == null) continue;
      final name = _name.firstMatch(block)?.group(1);
      final manufacturer = _manufacturer.firstMatch(block)?.group(1);
      if (name == null || manufacturer == null) continue;
      catalogueKeys.add('${_unquote(name)}|${_unquote(manufacturer)}');
    }

    // Anti-vacuity: the parse must have found the catalogue, not silently zero.
    expect(catalogueKeys.length, greaterThan(100),
        reason: 'Parsed only ${catalogueKeys.length} specKeys from the '
            'catalogue — the name/manufacturer scan is probably broken.');

    final bundledKeys = <String>{
      for (final banner in AdBanner.bundledTargets) ...?banner.match?.specKeys,
    };
    expect(bundledKeys, isNotEmpty);

    for (final key in bundledKeys) {
      if (_pendingSpecKeys.containsKey(key)) {
        // Guard the guard: a pending key that HAS shipped must be promoted out
        // of the allowlist so it is really checked.
        expect(catalogueKeys.contains(key), isFalse,
            reason: 'Spec key "$key" is on the pending allowlist but now '
                'exists in the catalogue — remove it from _pendingSpecKeys so '
                'it is held to the real spec.');
        continue;
      }
      expect(catalogueKeys.contains(key), isTrue,
          reason: 'Bundled targeted-banner spec key "$key" matches no spec in '
              'the vendored catalogue. A spec was renamed (device.name / '
              'device.manufacturer) and orphaned this promo, or the key is a '
              'typo. Fix the key in AdBanner.bundledTargets (and banner.json), '
              'or add it to _pendingSpecKeys with a reason if the spec is not '
              'in the catalogue yet.');
    }
  });
}
