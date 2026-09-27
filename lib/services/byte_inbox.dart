// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Bytes that arrive in pieces, taken off in exact counts.

import 'dart:async';

/// A buffer for a link that delivers bytes in whatever pieces it likes.
///
/// Both radio links work this way: a BLE notification carries twenty-odd
/// bytes of a reply at the minimum MTU, and a USB-serial driver hands over
/// whatever its last transfer held. Neither protocol has framing a reader
/// could wait for, so "take exactly N bytes" is the only workable read — the
/// caller always knows how long the answer it is waiting for will be.
class ByteInbox {
  final List<int> _buffer = [];
  Completer<void>? _waiter;
  Object? _error;

  void add(List<int> chunk) {
    _buffer.addAll(chunk);
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// The link feeding this inbox has failed with [error]: every [take] that
  /// cannot be served from what already arrived throws it, at once.
  ///
  /// Without it a reader learned of a dead feed only by waiting out its
  /// timeout, and then reported silence instead of the cause. The first
  /// failure wins; a stream's done event after its error adds nothing.
  void fail(Object error) {
    _error ??= error;
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// Take exactly [count] bytes, waiting up to [timeout] for them to arrive.
  ///
  /// Throws [TimeoutException] when they do not, leaving whatever did arrive
  /// in the buffer — [clear] is the caller's decision, not a side effect.
  /// Throws the [fail] error instead once the feed has failed.
  Future<List<int>> take(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      final error = _error;
      if (error != null) throw error;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('waiting for $count bytes', timeout);
      }
      final waiter = Completer<void>();
      _waiter = waiter;
      try {
        await waiter.future.timeout(remaining);
      } finally {
        _waiter = null;
      }
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }

  /// Drop anything left over, so one command's tail cannot be read as the
  /// next command's reply.
  void clear() => _buffer.clear();
}
