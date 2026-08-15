// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ha_roomba_client.dart';
import '../services/irobot_cloud_service.dart';
import '../services/rest980_client.dart';
import '../services/roomba_control_service.dart';
import '../services/roomba_credential_store.dart';
import 'ha_provider.dart';
import 'spec_codec_provider.dart';

/// Adopted robots' BLIDs and passwords, on the same secure settings store the
/// hub credentials and the HA token use — so in production they land in the
/// platform keychain/keystore, and a test overriding [settingsStoreProvider]
/// gets an isolated in-memory store for free.
final roombaCredentialStoreProvider = Provider<RoombaCredentialStore>(
    (ref) => RoombaCredentialStore(ref.watch(settingsStoreProvider)));

/// The Home Assistant transport, or null when HA is not set up in the app.
///
/// Null rather than throwing, because "no Home Assistant here" is an ordinary
/// state the UI has to render — the transport chooser still offers HA, with a
/// pointer to setting it up, rather than hiding a path the user may well want.
///
/// Reads the config synchronously off [haConfigProvider]'s current value: this
/// is consulted while building a controller, and a robot whose config has not
/// finished loading falls back to the direct path rather than stalling the
/// screen.
final haRoombaClientProvider = Provider<HaRoombaClient?>((ref) {
  final config = ref.watch(haConfigProvider).valueOrNull;
  if (config == null || config.token.isEmpty || config.baseUrl.isEmpty) {
    return null;
  }
  return HaRoombaClient(api: ref.watch(haApiClientProvider), config: config);
});

/// The HOME-button password handshake. A provider so the adoption wizard's
/// widget tests drive it from a scripted socket rather than a real robot.
final roombaPasswordServiceProvider = Provider<RoombaPasswordService>(
    (ref) => RoombaPasswordService(codec: ref.watch(specCodecProvider)));

/// The account route to the same credentials.
///
/// Constructed per use and disposed with the ref: it holds an `http.Client`,
/// and the one thing this service must never do is outlive the sign-in it was
/// created for. Nothing about steady-state control touches it.
final iRobotCloudServiceProvider = Provider<IRobotCloudService>((ref) {
  final service = IRobotCloudService();
  ref.onDispose(service.close);
  return service;
});

/// A live MQTT session with one robot, keyed by BLID.
///
/// `autoDispose` is not a tidiness preference here, it is the protocol: the
/// robot serves ONE local client at a time and a new connection evicts the
/// old, so a session that outlives the screen watching it keeps the owner
/// locked out of their own iRobot app. When the last watcher goes away the
/// client disconnects and the slot is free again.
final roombaClientProvider =
    Provider.autoDispose.family<RoombaMqttClient, String>((ref, blid) {
  final client = RoombaMqttClient(codec: ref.watch(specCodecProvider));
  ref.onDispose(client.dispose);
  return client;
});

/// The rest980 transport, for robots configured to route through a server.
///
/// A provider like every other transport client here, so tests substitute one
/// that answers from canned JSON instead of a Raspberry Pi. It takes the codec
/// because the state document it fetches is flattened by the same Rust
/// function the direct path uses — which is what lets one control screen drive
/// either transport.
final rest980ClientProvider = Provider<Rest980Client>((ref) {
  final client = Rest980Client(codec: ref.watch(specCodecProvider));
  ref.onDispose(client.close);
  return client;
});

/// Whether the app holds credentials for one robot, by BLID.
///
/// autoDispose + family so a screen watching it re-reads after adoption or
/// after forgetting — callers invalidate it after either.
final roombaCredentialsProvider = FutureProvider.autoDispose
    .family<RoombaCredentials?, String>((ref, blid) =>
        ref.watch(roombaCredentialStoreProvider).credentials(blid));
