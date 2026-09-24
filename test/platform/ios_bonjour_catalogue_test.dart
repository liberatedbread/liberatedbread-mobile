// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Cross-checks ios/Runner/Info.plist's NSBonjourServices allow-list against the
// mDNS service types the bundled device catalogue actually names.
//
// This is a sync check, not a config audit, which is why it lives apart from
// ios_info_plist_test.dart: the catalogue arrives by `git subtree pull`, and
// iOS 14+ withholds mDNS answers for an undeclared type SILENTLY, so the drift
// shows up as "that device just never appears on iOS" with nothing in any log —
// the failure mode this whole directory exists for.
//
// It caught four missing types at the time it was written (_smartthings._tcp,
// _airplay._tcp, _dyson_mqtt._tcp, _ankivector._tcp), i.e. four product
// families whose specs shipped in the app and could never be discovered on iOS.
// It then caught five more on the wave that added Chromecast, Moonraker,
// Squeezebox, SoundTouch and the Denon — which is when the array stopped being
// hand-written. `scripts/regen-bonjour-services.sh` now derives it from these
// same specs and `update-specs.sh` runs that on every pull, so this test's job
// changed: it no longer tells a human what to type, it asserts the generator
// was run. The two derivations are deliberately independent implementations of
// one rule, in different languages, for that reason.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _plistPath = 'ios/Runner/Info.plist';
const String _devicesDir = 'vendor/protocol-specs/device-specs/devices';
const String _generator = 'scripts/regen-bonjour-services.sh';

/// A spec's `device:` block — the key at column 0 and everything under it.
///
/// The scope is the rule, not an optimisation. A service type under `evidence:`
/// or `protocol_details:` is a record of what a probe once saw, or a note on a
/// protocol the vendor superseded (Caséta's deprecated `_lap._tcp`); neither is
/// an axis anything matches on, and asking iOS for permission on the strength
/// of a footnote is not something to do by accident.
final RegExp _deviceBlock = RegExp(
  r'^device:\n(?:[ \t].*\n|\n)*',
  multiLine: true,
);

/// `mdns_service_type:` (the identification axis) and `service_type:` (each
/// `discovery.methods[].mdns` entry). One value, two spellings, both of them an
/// instruction to go looking — the scan reads identification, and the discovery
/// methods are what the catalogue enumerates.
final RegExp _serviceType = RegExp(
  r'''^\s*(?:mdns_)?service_type:\s*["']?([^"'\n#]+)''',
  multiLine: true,
);

/// Types the app browses that no device spec names, each for a stated reason.
/// Kept in step with `APP_OWNED` in [_generator].
const Set<String> _appOwned = {
  // The DNS-SD meta-query the scan enumerates unknown service types with
  // (`_serviceEnumerationQuery` in lib/services/real_network_scan_service.dart).
  '_services._dns-sd._udp',
  // Home Assistant is a server the app integrates with, not a catalogue
  // device, so no spec declares it.
  '_home-assistant._tcp',
};

/// Reduce a DNS-SD type to the form NSBonjourServices wants: lowercase, no
/// trailing dot, no `.local` suffix. Mirrors `normalize_service_type` in
/// rust/src/spec/types.rs, because a mismatch in either direction is a
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
        consequence:
            'Without it the iOS app has no bundle metadata and '
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
      reason:
          '$_devicesDir must exist. It is the vendored protocol-specs '
          'subtree, and it is what the app bundles as its catalogue — if it '
          'is missing the app ships no specs at all.',
    );

    final wanted = <String, List<String>>{};
    for (final file in specsDir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.yaml'),
    )) {
      final block = _deviceBlock.firstMatch(file.readAsStringSync());
      if (block == null) continue;
      for (final match in _serviceType.allMatches(block.group(0)!)) {
        final type = _normalize(match.group(1)!);
        // A DNS-SD type starts with an underscore; anything else under these
        // keys is a UPnP service URN (wemo and viera write one there).
        if (!type.startsWith('_')) continue;
        wanted
            .putIfAbsent(type, () => <String>[])
            .add(file.uri.pathSegments.last);
      }
    }
    expect(
      wanted,
      isNotEmpty,
      reason:
          'No spec in $_devicesDir declares a service type, which means '
          'this check is reading the wrong place and is silently passing '
          'rather than checking anything.',
    );

    final missing = wanted.keys.where((t) => !declared.contains(t)).toList()
      ..sort();
    expect(
      missing,
      isEmpty,
      reason:
          'These mDNS service types are named by bundled device specs but '
          'are absent from NSBonjourServices in $_plistPath:\n'
          '${missing.map((t) => '  $t  (${wanted[t]!.join(', ')})').join('\n')}\n'
          'iOS 14+ will not deliver an mDNS answer for an undeclared type and '
          'fails SILENTLY, so those devices can never be discovered or matched '
          'on iOS even though their specs ship with the app. Do not add them '
          'by hand: run ./$_generator (or re-run ./scripts/update-specs.sh, '
          'which calls it) and commit the plist.',
    );

    // The other direction. An allow-list that only ever grows accumulates
    // permissions nothing can explain — `_lap._tcp` sat here for months on the
    // strength of a line in another spec's evidence block — and once the array
    // is generated, an entry the generator would not produce is proof the file
    // was edited by hand or the generator was not run.
    final unexplained =
        declared
            .where((t) => !wanted.containsKey(t) && !_appOwned.contains(t))
            .toList()
          ..sort();
    expect(
      unexplained,
      isEmpty,
      reason:
          'NSBonjourServices in $_plistPath declares service types that no '
          'bundled spec names and that are not in the app-owned set:\n'
          '${unexplained.map((t) => '  $t').join('\n')}\n'
          'Either a spec that justified one was removed upstream, or the array '
          'was hand-edited. Re-run ./$_generator and commit the result; if the '
          'type really is one the app browses on its own account, add it to '
          "the generator's APP_OWNED with the reason, and to _appOwned here.",
    );
  });
}
