// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'spec_codec.dart';

/// Feeds the stored-upload response characteristic's notifications, one at a
/// time, into a decode that sees a WINDOW of them.
///
/// A packet a 23-byte MTU splits in two never arrives in one notification: its
/// first fragment stops short of the SimpleMessage, the single-notification
/// decode hands back nothing rather than a verdict it invented, and nothing
/// reassembled — so on an unnegotiated link the M_UPLOAD_COMPLETE the device
/// sent was never decoded, the completer never fired, and every save timed
/// out as "unconfirmed". This keeps the recent notifications and asks the
/// codec about all of them; the window is cleared once a packet completes so
/// an event is reported once.
class StoredUploadEventReader {
  final SpecCodec codec;
  final String specYaml;

  /// Notifications kept: enough for the largest packet the device sends
  /// split at the smallest MTU, plus the pushes that share the channel.
  static const int windowSize = 16;

  final List<List<int>> _window = [];

  StoredUploadEventReader({required this.codec, required this.specYaml});

  /// The event [notification] completes, or null if it completes none.
  Future<StoredUploadEventDto?> feed(List<int> notification) async {
    _window.add(List.of(notification));
    if (_window.length > windowSize) _window.removeAt(0);
    final events = await codec.decodeStoredUploadEvents(
      specYaml: specYaml,
      notifications: List.of(_window),
    );
    if (events.isEmpty) return null;
    _window.clear();
    return events.last;
  }
}
