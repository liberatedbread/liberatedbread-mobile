// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The window the reader keeps. Reassembly itself is the Rust core's and is
// pinned there (rust/tests/stored_design_bounds.rs, with the real fragment
// bytes); what is pinned here is that the reader hands the codec the window
// and not the notification, clears it once a packet completes, and caps it.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/stored_upload_event_reader.dart';

import '../fakes/fake_spec_codec.dart';

final _complete = StoredUploadEventDto(
  kind: StoredUploadEventKind.complete,
  code: BigInt.zero,
  resumeOffset: BigInt.zero,
  progress: BigInt.zero,
);

void main() {
  test(
    'a packet that needs two notifications is reported once both are in',
    () async {
      // The fake reports an event only for a notification whose first byte is
      // 2 — standing in for "the fragment that completes the packet".
      final windows = <List<List<int>>>[];
      final codec = _WindowingFake(
        windows,
        eventFor: (n) => n.first == 2 ? _complete : null,
      );
      final reader = StoredUploadEventReader(codec: codec, specYaml: 'y');

      expect(await reader.feed([1, 0xAA]), isNull);
      expect(windows.last, [
        [1, 0xAA],
      ], reason: 'the first fragment alone is asked about');

      final event = await reader.feed([2, 0xBB]);
      expect(event?.kind, StoredUploadEventKind.complete);
      expect(
        windows.last,
        [
          [1, 0xAA],
          [2, 0xBB],
        ],
        reason: 'the codec is handed the whole window, not the notification',
      );

      // The window was cleared by the completion: the next notification is
      // asked about on its own, so a completed packet is not reported twice.
      expect(await reader.feed([1, 0xCC]), isNull);
      expect(windows.last, [
        [1, 0xCC],
      ]);
    },
  );

  test('the window is capped', () async {
    final windows = <List<List<int>>>[];
    final codec = _WindowingFake(windows, eventFor: (_) => null);
    final reader = StoredUploadEventReader(codec: codec, specYaml: 'y');
    for (var i = 0; i < StoredUploadEventReader.windowSize + 5; i++) {
      await reader.feed([i]);
    }
    expect(windows.last, hasLength(StoredUploadEventReader.windowSize));
    expect(windows.last.first, [5], reason: 'oldest evicted first');
  });
}

/// A fake whose window decode records what it was asked and answers per
/// notification through [eventFor].
class _WindowingFake extends FakeSpecCodec {
  final List<List<List<int>>> windows;
  final StoredUploadEventDto? Function(List<int>) eventFor;

  _WindowingFake(this.windows, {required this.eventFor});

  @override
  Future<List<StoredUploadEventDto>> decodeStoredUploadEvents({
    required String specYaml,
    required List<List<int>> notifications,
  }) async {
    windows.add([for (final n in notifications) List.of(n)]);
    return [for (final n in notifications) ?eventFor(n)];
  }
}
