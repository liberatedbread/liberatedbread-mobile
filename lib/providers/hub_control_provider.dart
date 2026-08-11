// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/hub_credential_store.dart';
import '../services/hub_http_client.dart';
import '../services/hue_pairing_service.dart';
import 'settings_store_provider.dart';
import 'spec_codec_provider.dart';

/// Pairing credentials, TLS pins and scheme memory, on the same secure
/// settings store the HA config uses. Tests override [settingsStoreProvider]
/// with an in-memory fake and get an isolated store for free.
final hubCredentialStoreProvider = Provider<HubCredentialStore>(
    (ref) => HubCredentialStore(ref.watch(settingsStoreProvider)));

/// The hub transport. A provider so widget tests substitute a client that
/// answers from canned JSON instead of a network — and so every screen
/// shares one scheme/pin memory.
final hubHttpClientProvider = Provider<HubHttpClient>(
    (ref) => HubHttpClient(credentials: ref.watch(hubCredentialStoreProvider)));

/// The link-button pairing flow.
final huePairingServiceProvider = Provider<HuePairingService>(
  (ref) => HuePairingService(
    codec: ref.watch(specCodecProvider),
    client: ref.watch(hubHttpClientProvider),
  ),
);

/// Whether (and as whom) the app is paired with one bridge, by bridgeid.
///
/// autoDispose + family so a screen watching it re-reads after pairing or
/// forgetting — callers invalidate it after either.
final hubCredentialsProvider = FutureProvider.autoDispose
    .family<HubCredentials?, String>((ref, bridgeId) =>
        ref.watch(hubCredentialStoreProvider).credentials(bridgeId));
