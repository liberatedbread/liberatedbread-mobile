// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/baofeng_ble_programmer.dart';
import '../services/mock_radio_programmer.dart';
import '../services/radio_programmer.dart';
import 'ble_provider.dart';

/// The radio programmer: the real one, or the mock in demo mode.
///
/// Mirrors [bleServiceProvider] exactly, and for the same reason -- demo mode
/// is a shipped feature, not a test double, and the Radio tab has to work in
/// it without a radio anywhere near.
final radioProgrammerProvider = Provider<RadioProgrammer>((ref) {
  if (isMockMode) return MockRadioProgrammer();
  return BaofengBleProgrammer(ref.watch(bleServiceProvider));
});
