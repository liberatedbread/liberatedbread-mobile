// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/roomba_provider.dart';
import '../services/roomba_control_service.dart';
import '../services/roomba_credential_store.dart';
import 'hub_device_screen.dart';
import 'label_printer_screen.dart';
import 'network_device_screen.dart';
import 'roomba_adoption_screen.dart';

/// Open whatever this device's controls need, from wherever the user tapped.
///
/// Shared by the scan list and the saved-devices list because the pre-flight
/// below is not a property of how the device was found. A saved robot reaches
/// this path exactly as often as a scanned one — its credential can be absent
/// because it was adopted on another handset, or because the store was
/// cleared — and pushing the control screen without the pre-flight strands the
/// user on an error with no route to adoption.
Future<void> openNetworkControls({
  required BuildContext context,
  required WidgetRef ref,
  required NetworkDevice device,
  required NetworkControls controls,
  // The matched spec's category (`device.category`) and identity
  // (`specKeyFor`), when the caller knows them — the scan row has them from its
  // guess, a saved device persists them. They drive the device-targeted ad
  // banner (label supplies for a label printer, filters for a Rabbit Air) and
  // are otherwise inert; null just falls back to the global promotion.
  String? category,
  String? specKey,
}) async {
  if (!await _adopted(
    context: context,
    ref: ref,
    device: device,
    controls: controls,
  )) {
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      // A raster label printer resolves no entities — its surface is a byte
      // stream — so it gets its own screen (status + print) rather than the
      // entity panel. A hub (instanced children, link-button pairing) gets the
      // paired screen; everything else — SOAP devices and Roku's plain-HTTP
      // remote alike — keeps the ordinary control screen, whose load path a Hue
      // bridge would not survive.
      builder: (_) => controls.rasterPrintHandler != null
          ? LabelPrinterScreen(
              device: device,
              controls: controls,
              category: category,
              specKey: specKey,
            )
          : controls.isHub
          ? HubDeviceScreen(device: device, controls: controls)
          : NetworkDeviceScreen(
              device: device,
              controls: controls,
              category: category,
              specKey: specKey,
            ),
    ),
  );
}

/// Whether [device] can be driven at all, running the adoption wizard first
/// when it cannot.
///
/// A robot with no stored password cannot be controlled at all, so it goes to
/// the wizard rather than to a screen of buttons that would every one of them
/// fail. Everything that is not a robot is adopted by definition. Returns
/// false when the user backed out, or when the surface that asked went away
/// mid-flow.
Future<bool> _adopted({
  required BuildContext context,
  required WidgetRef ref,
  required NetworkDevice device,
  required NetworkControls controls,
}) async {
  final blid = device.txt['blid'];
  // Keyed on the spec's protocol_handler, as NetworkDeviceScreen and the
  // saved-devices row key it — not on the `mqtt` transport, which Hisense,
  // Dyson and Bambu devices ride too: one of those announcing a `blid` key
  // was sent to the Roomba wizard here, while the control screen (rightly)
  // did not treat it as a robot.
  final isRoomba =
      blid != null &&
      blid.isNotEmpty &&
      controls.capabilities?.protocolHandler == roombaProtocolHandler;
  if (!isRoomba) return true;

  final store = ref.read(roombaCredentialStoreProvider);
  // Both callers fire this from a tap and drop the future, so a keychain
  // fault here used to vanish into the zone handler: the tap did nothing
  // and said nothing. A read failure is NOT "no credential" — sending the
  // user to adoption would overwrite a password that is probably still
  // stored — so say what happened and stop.
  final RoombaCredentials? stored;
  try {
    stored = await store.credentials(blid);
  } catch (e, st) {
    Log.ui.warning(
      'could not read robot credentials',
      error: e,
      stackTrace: st,
    );
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            friendlyErrorText(
              e,
              context: 'keychain',
              fallback:
                  "Could not read this robot's saved password from the "
                  'device keychain.',
            ),
          ),
        ),
      );
    }
    return false;
  }
  if (!context.mounted) return false;
  if (stored == null) {
    final adopted = await Navigator.of(context).push<RoombaCredentials>(
      MaterialPageRoute(
        builder: (_) => RoombaAdoptionScreen(
          blid: blid,
          host: device.host,
          robotName: device.name.isEmpty ? null : device.name,
          sku: device.txt['sku'],
        ),
      ),
    );
    // Dismissed without adopting: there is nothing to control, so do not push
    // a screen that would only show errors.
    return adopted != null && context.mounted;
  }
  // The lease may have moved since the last session; the sighting that got us
  // here just told us where it is now. Best effort: a failed write used to
  // throw out of here and block a robot whose credentials read fine from
  // opening at all, over a convenience for the NEXT session.
  try {
    await store.rememberAddress(blid, device.host);
  } catch (e, st) {
    Log.ui.warning(
      'could not remember the robot address',
      error: e,
      stackTrace: st,
    );
  }
  return context.mounted;
}
