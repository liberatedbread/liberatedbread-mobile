// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Where channel plans live between launches.

import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel_plan.dart';
import 'prefs_json_list.dart';

/// Persists the user's channel plans.
///
/// Same shape as [SavedDeviceStore]: a JSON array under one key, read through
/// [loadPrefsJsonList] so one corrupt record costs itself and not the list.
/// That policy matters more here than anywhere else in the app -- a plan is
/// minutes of somebody's work assembling channels, not a cached scan result.
class ChannelPlanStore {
  static const _key = 'radio_channel_plans_v1';

  final SharedPreferences _prefs;

  ChannelPlanStore(this._prefs);

  /// Plans, most recently modified first.
  List<ChannelPlan> load() =>
      loadPrefsJsonList(_prefs, _key, ChannelPlan.fromJson)
        ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));

  /// Insert or replace [plan], keeping the list newest-first.
  Future<List<ChannelPlan>> save(ChannelPlan plan) async {
    final plans = load().where((p) => p.id != plan.id).toList()
      ..insert(0, plan);
    await _write(plans);
    return plans;
  }

  Future<List<ChannelPlan>> remove(String id) async {
    final plans = load().where((p) => p.id != id).toList();
    await _write(plans);
    return plans;
  }

  Future<void> _write(List<ChannelPlan> plans) =>
      savePrefsJsonList(_prefs, _key, plans, (p) => p.toJson());
}
