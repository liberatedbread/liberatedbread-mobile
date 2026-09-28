// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

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

/// The device answered a write with a reply the plan names as a refusal
/// (NIIMBOT's print-error or "not supported"). Its bytes are kept for the log.
class DeviceRefusedException implements Exception {
  final List<int> reply;
  const DeviceRefusedException(this.reply);

  @override
  String toString() =>
      'DeviceRefusedException(${reply.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')})';
}

/// Send an image-upload write plan to a connected device: every write, in
/// order, each to the characteristic it names. Ordering is part of the
/// protocol (row streams, fragment reassembly), so the writes are awaited one
/// at a time. Throws what the BLE service throws; the caller owns the message.
///
/// A plan with reply waits (a request/response printer) is run against the
/// notifications on the characteristics it names, subscribed before the
/// first write so no reply can arrive unheard: after each such write the
/// runner waits for its reply, and before the plan's completion-poll write
/// it asks for status until the device says it is done. A reply that does
/// not come is a [TimeoutException]; one the plan names as an error is a
/// [DeviceRefusedException]. A plan without either — every image upload but
/// NIIMBOT's — writes back to back, exactly as before.
Future<void> runImageWritePlan(
  BleService ble,
  String deviceId,
  ImageWritePlanDto plan, {
  Duration subscribeSettle = const Duration(milliseconds: 250),
}) async {
  final poll = plan.completionPoll;
  if (plan.replyWaits.isEmpty && poll == null) {
    for (final write in plan.writes) {
      await ble.writeCharacteristic(
        deviceId,
        plan.serviceUuid,
        write.characteristicUuid,
        write.bytes,
      );
    }
    return;
  }

  final replies = _ReplyBuffer();
  final listened = {
    for (final w in plan.replyWaits) w.characteristicUuid,
    if (poll != null) poll.characteristicUuid,
  };
  final subscriptions = [
    for (final char in listened)
      ble
          .subscribeCharacteristic(deviceId, plan.serviceUuid, char)
          .listen(replies.add, onError: (Object _) {}),
  ];
  try {
    // Subscribing returns before the platform has written the CCCD, so a
    // reply to the very first write could arrive with notifications still
    // off. Give the enable a moment, and (below) resend the first write
    // once if its reply still does not come.
    await Future<void>.delayed(subscribeSettle);
    final waitsAfter = <int, List<ReplyWaitDto>>{};
    for (final w in plan.replyWaits) {
      (waitsAfter[w.afterWrite] ??= []).add(w);
    }
    for (var i = 0; i < plan.writes.length; i++) {
      if (poll != null && poll.beforeWrite == i) {
        await _pollUntilDone(ble, deviceId, plan.serviceUuid, poll, replies);
      }
      final write = plan.writes[i];
      await ble.writeCharacteristic(
        deviceId,
        plan.serviceUuid,
        write.characteristicUuid,
        write.bytes,
      );
      for (final wait in waitsAfter[i] ?? const <ReplyWaitDto>[]) {
        try {
          await replies.take(
            wait.expectPrefix,
            errors: wait.errorPrefixes,
            timeout: Duration(milliseconds: wait.timeoutMs),
          );
        } on TimeoutException {
          if (i != 0) rethrow;
          await ble.writeCharacteristic(
            deviceId,
            plan.serviceUuid,
            write.characteristicUuid,
            write.bytes,
          );
          await replies.take(
            wait.expectPrefix,
            errors: wait.errorPrefixes,
            timeout: Duration(milliseconds: wait.timeoutMs),
          );
        }
      }
    }
  } finally {
    for (final s in subscriptions) {
      await s.cancel();
    }
    replies.close();
  }
}

Future<void> _pollUntilDone(
  BleService ble,
  String deviceId,
  String serviceUuid,
  CompletionPollDto poll,
  _ReplyBuffer replies,
) async {
  final deadline = DateTime.now().add(Duration(milliseconds: poll.timeoutMs));
  while (true) {
    await ble.writeCharacteristic(
      deviceId,
      serviceUuid,
      poll.request.characteristicUuid,
      poll.request.bytes,
    );
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('the device never reported done', remaining);
    }
    final reply = await replies.take(
      poll.replyPrefix,
      // The whole field the verdict is read from, not just the prefix: a
      // reply split across notifications must not be judged half-arrived.
      minLength: poll.doneOffset + poll.doneBytes.length,
      timeout: remaining,
    );
    if (_carries(reply, poll.doneOffset, poll.doneBytes)) return;
    await Future<void>.delayed(Duration(milliseconds: poll.intervalMs));
  }
}

/// Whether [reply] holds [bytes] starting at [offset].
bool _carries(List<int> reply, int offset, List<int> bytes) {
  if (reply.length < offset + bytes.length) return false;
  for (var k = 0; k < bytes.length; k++) {
    if (reply[offset + k] != bytes[k]) return false;
  }
  return true;
}

/// Notification bytes as one rolling stream: a reply can arrive split across
/// notifications at a small MTU, or two in one, so replies are found by
/// prefix in the concatenation rather than per notification.
class _ReplyBuffer {
  final List<int> _bytes = [];
  Completer<void>? _arrived;

  void add(List<int> chunk) {
    _bytes.addAll(chunk);
    final waiting = _arrived;
    _arrived = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  void close() {
    final waiting = _arrived;
    _arrived = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  /// Wait for [prefix] to appear with at least [minLength] bytes from its
  /// start; return those bytes on, and drop everything — each request has
  /// one reply, so what came before it is stale and what came with it is
  /// spent. Whichever of [prefix] and [errors] appears FIRST decides: an
  /// error pattern that happens to occur later, inside other data, is not
  /// a refusal.
  Future<List<int>> take(
    List<int> prefix, {
    List<List<int>> errors = const [],
    int minLength = 0,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final at = _find(prefix);
      var errorAt = -1;
      for (final error in errors) {
        final e = _find(error);
        if (e >= 0 && (errorAt < 0 || e < errorAt)) errorAt = e;
      }
      if (errorAt >= 0 && (at < 0 || errorAt < at)) {
        final reply = _bytes.sublist(errorAt);
        _bytes.clear();
        throw DeviceRefusedException(reply);
      }
      if (at >= 0 && _bytes.length - at >= minLength) {
        final reply = _bytes.sublist(at);
        _bytes.clear();
        return reply;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('no reply from the device', timeout);
      }
      final arrived = _arrived ??= Completer<void>();
      await arrived.future.timeout(remaining, onTimeout: () {});
    }
  }

  int _find(List<int> pattern) {
    if (pattern.isEmpty) return -1;
    outer:
    for (var i = 0; i + pattern.length <= _bytes.length; i++) {
      for (var k = 0; k < pattern.length; k++) {
        if (_bytes[i + k] != pattern[k]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
