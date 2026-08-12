// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/secure_settings_store.dart';
import '../services/settings_store.dart';

/// Key/value store for settings and secrets, backed by the platform
/// keychain/keystore. Tests override with an in-memory fake so nothing
/// touches the platform channels.
///
/// Lives in its own file because two features now share it: the Home
/// Assistant configuration and the hub pairing credentials — and a secret
/// store owned by one feature's provider file reads as that feature's
/// private property, which is exactly how a second user ends up minting a
/// second store.
final settingsStoreProvider =
    Provider<SettingsStore>((ref) => SecureSettingsStore());
