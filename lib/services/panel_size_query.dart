// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/log.dart';
import 'ble_service.dart';
import 'spec_codec.dart';

/// Ask a connected panel for its size, for a handler that has a query for it
/// (see [SpecCodec.panelProbe]). Null when it has none, or nothing usable came
/// back: a panel that does not answer is not an error here, every caller has a
/// canvas to fall back on.
///
/// Subscribes first, because the answer is a notification and is not repeated.
Future<({int width, int height})?> queryPanelSize(
  BleService ble,
  SpecCodec codec,
  String deviceId,
  String specYaml, {
  Duration settle = const Duration(milliseconds: 250),
  Duration listen = const Duration(milliseconds: 1500),
}) async {
  final PanelProbeDto? probe;
  try {
    probe = await codec.panelProbe(specYaml: specYaml);
  } on Object catch (e) {
    Log.ble.debug('no panel query for $deviceId: $e');
    return null;
  }
  if (probe == null) return null;

  final replies = <List<int>>[];
  StreamSubscription<List<int>>? sub;
  try {
    sub = ble
        .subscribeCharacteristic(
          deviceId,
          probe.serviceUuid,
          probe.notifyCharacteristicUuid,
        )
        .listen(replies.add, onError: (Object _) {});
    await Future<void>.delayed(settle);
    await ble.writeCharacteristic(
      deviceId,
      probe.serviceUuid,
      probe.writeCharacteristicUuid,
      probe.bytes,
    );
    await Future<void>.delayed(listen);
  } on Object catch (e) {
    Log.ble.debug('panel query failed on $deviceId: $e');
    return null;
  } finally {
    await sub?.cancel();
  }
  final size = await codec.panelResolutionFromReply(
    specYaml: specYaml,
    notifications: replies,
  );
  return size == null ? null : (width: size.width, height: size.height);
}
