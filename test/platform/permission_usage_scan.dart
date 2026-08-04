// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Extracts the permission_handler permissions the Dart code actually asks for,
// so the platform-config tests can assert against what the code DOES rather
// than against a hand-maintained list that drifts.
import 'platform_config_reader.dart';

/// One `Permission.<name>` reference found in real Dart code.
class PermissionUsage {
  const PermissionUsage({
    required this.name,
    required this.line,
    required this.androidGuarded,
  });

  /// The member name, e.g. `bluetoothScan` for `Permission.bluetoothScan`.
  final String name;

  /// 1-based line in the original (un-stripped) source, for failure messages.
  final int line;

  /// Whether the reference sits lexically inside an
  /// `if (Platform.isAndroid) { ... }` block, and therefore cannot run on iOS.
  final bool androidGuarded;

  @override
  String toString() => 'Permission.$name (line $line'
      '${androidGuarded ? ', Android-only' : ''})';
}

final RegExp _permissionRef = RegExp(r'\bPermission\.([A-Za-z_$][\w$]*)');

/// Matches only the simple, unnegated guard. A compound or inverted condition
/// deliberately does NOT match, which makes the scan err towards reporting a
/// usage as iOS-reachable — the safe direction for a test whose job is to catch
/// an iOS-only capability gap.
final RegExp _androidGuard = RegExp(r'if\s*\(\s*Platform\.isAndroid\s*\)\s*\{');

/// Every `Permission.<name>` reference in [source] that is real code.
///
/// Comments and string literals are blanked before scanning, so the explanatory
/// block in `lib/services/real_ble_service.dart` — which names
/// `Permission.bluetooth.request()` precisely to say it must never be called —
/// is correctly NOT reported.
List<PermissionUsage> findPermissionUsages(String source) {
  final code = stripDartCommentsAndStringContents(source);
  final androidBlocks = _androidGuardedRanges(code);
  return [
    for (final match in _permissionRef.allMatches(code))
      PermissionUsage(
        name: match.group(1)!,
        line: lineNumberAt(source, match.start),
        androidGuarded: androidBlocks.any(
          (r) => match.start >= r.start && match.start < r.end,
        ),
      ),
  ];
}

/// Half-open `[start, end)` ranges of [code] enclosed by an
/// `if (Platform.isAndroid) { ... }` block.
///
/// [code] must already have had comments and string contents blanked, so brace
/// counting cannot be thrown off by a brace inside a comment or a literal.
List<({int start, int end})> _androidGuardedRanges(String code) {
  final ranges = <({int start, int end})>[];
  for (final guard in _androidGuard.allMatches(code)) {
    final open = guard.end - 1; // The `{` captured by the guard pattern.
    var depth = 0;
    for (var i = open; i < code.length; i++) {
      if (code[i] == '{') depth++;
      if (code[i] == '}') {
        depth--;
        if (depth == 0) {
          ranges.add((start: open, end: i));
          break;
        }
      }
    }
  }
  return ranges;
}
