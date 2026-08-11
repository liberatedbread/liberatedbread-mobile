// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hands out a rolling per-device message sequence for framed DDP commands.
///
/// The SmartDawn controller frames every command with a `[serial][total]
/// [remaining][tag]` header and — as the vendor app does — rolls the serial
/// (and the DNX `sn`) on each write. A firmware that de-duplicates a framed
/// command by serial would drop a byte-identical repeat, which is exactly what
/// made "press Replay again" and "save the same design twice" do nothing. Each
/// call to [next] returns a fresh value so consecutive writes differ on the
/// wire.
///
/// Kept in a `Notifier` rather than widget state so the counter survives the
/// editor being rebuilt or reopened within a connection; the only requirement
/// is monotonic-enough-to-differ, so wrapping at the 16-bit field width the
/// encoder uses is fine.
class CommandSequence extends FamilyNotifier<int, String> {
  @override
  int build(String deviceId) => 0;

  /// The next sequence value for this device. Wraps within the u16 the wire
  /// carries; starts at 1 so the first framed write is distinct from the
  /// encoder's unsupplied-default 0.
  int next() {
    final value = (state % 0xFFFF) + 1;
    state = value;
    return value;
  }
}

/// Per-device rolling command sequence. Family-keyed by device id so two
/// connected devices never share (or reset) each other's counter.
final commandSequenceProvider =
    NotifierProvider.family<CommandSequence, int, String>(
  CommandSequence.new,
);
