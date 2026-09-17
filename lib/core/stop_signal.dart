// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

/// A one-shot stop flag whose waits can be cut short.
///
/// This is the "delay that a stop can interrupt" mechanism both network scan
/// services need: a plain `bool` checked between sleeps made `stopScan()` a
/// lie (a stop arriving mid-sleep was not noticed until the sleep ended, so
/// the app-facing stream stayed open long after the scan had been told to
/// stop). The fix — a `Completer` guarded against double-complete plus a
/// `Future.any` race between the delay and the stop future — was hand-rolled
/// once per service before it lived here; a mechanism this easy to get subtly
/// wrong should exist exactly once.
class StopSignal {
  final Completer<void> _stopped = Completer<void>();

  /// Whether [stop] has been called.
  bool get stopped => _stopped.isCompleted;

  /// Completes when [stop] is called, so a wait can be cut short rather than
  /// only checked at its ends.
  Future<void> get whenStopped => _stopped.future;

  /// Idempotent: every path out of a scan may call this, and
  /// cancel-then-finish calls it twice.
  void stop() {
    if (!_stopped.isCompleted) _stopped.complete();
  }

  /// Waits [duration], or until [stop] is called — whichever comes first.
  /// True when the signal was stopped.
  ///
  /// The timer is owned rather than raced as a bare `Future.delayed`, and
  /// cancelled on the way out. `Future.any` abandons the loser, it does not
  /// cancel it: with a plain delayed future a stop arriving one second into a
  /// thirty-second backoff returned immediately and still left a thirty-second
  /// Timer armed, which keeps the event loop alive (a `dart run` that should
  /// have exited sits there instead) and fails any `fakeAsync` body that
  /// asserts no pending timers at the end of a scan.
  Future<bool> sleep(Duration duration) async {
    if (stopped) return true;
    final elapsed = Completer<void>();
    final timer = Timer(duration, () {
      if (!elapsed.isCompleted) elapsed.complete();
    });
    try {
      await Future.any([elapsed.future, _stopped.future]);
    } finally {
      timer.cancel();
    }
    return stopped;
  }
}
