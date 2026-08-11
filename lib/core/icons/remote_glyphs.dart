// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Glyphs for a remote control: power, navigation, playback, inputs. See
// README.md in this directory for why the tables are split by device domain.

import 'package:flutter/material.dart';

/// MDI names the Roku spec's remote buttons ask for, and the vocabulary any
/// other remote would draw from.
const Map<String, IconData> remoteGlyphs = {
  'mdi:power': Icons.power_settings_new,
  'mdi:power-off': Icons.power_off,
  'mdi:arrow-u-left-top': Icons.undo,
  'mdi:home': Icons.home_outlined,
  'mdi:chevron-up': Icons.keyboard_arrow_up,
  'mdi:chevron-down': Icons.keyboard_arrow_down,
  'mdi:chevron-left': Icons.keyboard_arrow_left,
  'mdi:chevron-right': Icons.keyboard_arrow_right,
  'mdi:replay': Icons.replay,
  // The medical asterisk is the one asterisk in the Material font, and an
  // asterisk is exactly what Roku's Options key looks like.
  'mdi:asterisk': Icons.emergency,
  'mdi:rewind': Icons.fast_rewind,
  'mdi:play-pause': Icons.play_arrow,
  'mdi:fast-forward': Icons.fast_forward,
  'mdi:volume-plus': Icons.volume_up,
  'mdi:volume-minus': Icons.volume_down,
  'mdi:volume-mute': Icons.volume_off,
  'mdi:chevron-double-up': Icons.keyboard_double_arrow_up,
  'mdi:chevron-double-down': Icons.keyboard_double_arrow_down,
  'mdi:magnify': Icons.search,
  'mdi:remote': Icons.settings_remote,
  'mdi:apps': Icons.apps,
  'mdi:hdmi-port': Icons.settings_input_hdmi,
  'mdi:video-input-component': Icons.settings_input_component,
  'mdi:antenna': Icons.settings_input_antenna,
};
