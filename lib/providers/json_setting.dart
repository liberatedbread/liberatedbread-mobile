// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A radio setting stored as one JSON object under one key.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import 'spec_pack_provider.dart';

/// The JSON object stored under [key], or null when there is none.
///
/// For a notifier's `build`, which it makes depend on the store. Something
/// stored that does not read as an object counts as nothing stored: a
/// setting nobody can read is not worth failing a screen over. It is logged
/// as a warning all the same, since for some settings — the limits a radio
/// came with — the stored copy is the only one.
Future<Map<String, dynamic>?> readJsonSetting(
  Ref<Object?> ref,
  String key,
) async {
  final store = await ref.watch(prefsSettingsStoreProvider.future);
  final raw = await store.read(key);
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // Unreadable, and reported below with the wrong-shape case.
  }
  Log.radio.warning('setting $key is unreadable; treating it as unset');
  return null;
}

/// Store [value] under [key] as JSON.
Future<void> writeJsonSetting(
  Ref<Object?> ref,
  String key,
  Object value,
) async {
  final store = await ref.read(prefsSettingsStoreProvider.future);
  await store.write(key, jsonEncode(value));
}
