// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers a device's REAL panel resolution, keyed by its id (MAC), so a
/// reconnect that carries no advertisement — and where a DeviceInfo query
/// fails or is not attempted — still sizes the canvas correctly.
///
/// Written whenever a live source (the advertisement, or a DeviceInfo push)
/// resolves a size; read as the reconnect fallback between them. Small and
/// best-effort: a missing or malformed entry just means "fall back to the
/// default the user can adjust".
class PanelResolutionCache {
  static const _keyPrefix = 'panel_res_';
  final SharedPreferences _prefs;

  const PanelResolutionCache(this._prefs);

  /// The cached `(width, height)` for [deviceId], or null if absent/malformed.
  ({int width, int height})? get(String deviceId) {
    final raw = _prefs.getString('$_keyPrefix$deviceId');
    if (raw == null) return null;
    final parts = raw.split('x');
    if (parts.length != 2) return null;
    final w = int.tryParse(parts[0]);
    final h = int.tryParse(parts[1]);
    if (w == null || h == null || w < 1 || h < 1) return null;
    return (width: w, height: h);
  }

  /// Remember [deviceId]'s panel size for next time.
  Future<void> set(String deviceId, int width, int height) =>
      _prefs.setString('$_keyPrefix$deviceId', '${width}x$height');
}
