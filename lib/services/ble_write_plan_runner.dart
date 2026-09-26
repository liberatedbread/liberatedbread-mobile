// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'ble_service.dart';
import 'spec_codec.dart';

/// Usable bytes per BLE write for a given ATT MTU.
///
/// Payload is MTU minus the 3-byte ATT write header, floored at the BLE 4.0
/// minimum of 20 and capped at 512 (the largest attribute value BLE permits,
/// and what vendors' own apps request).
///
/// The reported MTU is trusted as-is. The one platform where the report lies
/// (flutter_blue_plus_linux never updates `mtuNow` from what BlueZ actually
/// negotiates) is corrected inside `RealBleService.mtu()`, next to the
/// `requestMtu` call that owns that platform knowledge — so a genuine 23 from
/// Android sizes to the 20-byte floor here and the image encoder rejects it
/// with an actionable "raise the ATT MTU" message, instead of this helper
/// assuming 512 and firing oversized writes at a link that cannot carry them.
/// Pure so the sizing is unit-testable.
int writePayloadForMtu(int mtu) => (mtu - 3).clamp(20, 512);

/// Send an image-upload write plan to a connected device: every write, in
/// order, each to the characteristic it names. Ordering is part of the
/// protocol (row streams, fragment reassembly), so the writes are awaited one
/// at a time. Throws what the BLE service throws; the caller owns the message.
Future<void> runImageWritePlan(
  BleService ble,
  String deviceId,
  ImageWritePlanDto plan,
) async {
  for (final write in plan.writes) {
    await ble.writeCharacteristic(
      deviceId,
      plan.serviceUuid,
      write.characteristicUuid,
      write.bytes,
    );
  }
}
