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

final _progress = StoredUploadEventDto(
  kind: StoredUploadEventKind.progress,
  code: BigInt.zero,
  resumeOffset: BigInt.zero,
  progress: BigInt.one,
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

  test('feeds that overlap are run one at a time, in arrival order', () async {
    // The BLE `listen` callback does not wait for the previous one, so two
    // notifications inside one decode round-trip used to share the window:
    // the earlier feed's clear (on the progress event IT found) threw away
    // the first fragment of the M_UPLOAD_COMPLETE the later feed had already
    // appended, and the second fragment then arrived to an empty window.
    // Progress twice, complete never — the bug the reader exists to end.
    final windows = <List<List<int>>>[];
    final codec = _WindowingFake(
      windows,
      // 1: a single-notification progress packet. 2 then 3: a complete
      // packet split in two, reported only once both are in the window.
      windowEvents: (window) => [
        for (final n in window)
          if (n.first == 1)
            _progress
          else if (n.first == 3 && window.any((m) => m.first == 2))
            _complete,
      ],
      release: () => Future<void>.delayed(Duration.zero),
    );
    final reader = StoredUploadEventReader(codec: codec, specYaml: 'y');

    final results = await Future.wait([
      reader.feed([1]),
      reader.feed([2]),
      reader.feed([3]),
    ]);
    expect(results.map((e) => e?.kind).toList(), [
      StoredUploadEventKind.progress,
      null,
      StoredUploadEventKind.complete,
    ]);
    expect(windows, [
      [
        [1],
      ],
      [
        [2],
      ],
      [
        [2],
        [3],
      ],
    ], reason: 'each feed sees the window as the previous one left it');
  });
}

/// A fake whose window decode records what it was asked and answers per
/// notification through [eventFor], or over the whole window through
/// [windowEvents]; [release] is awaited first, so a test can hold a decode
/// open while more notifications arrive.
class _WindowingFake extends FakeSpecCodec {
  final List<List<List<int>>> windows;
  final StoredUploadEventDto? Function(List<int>)? eventFor;
  final List<StoredUploadEventDto> Function(List<List<int>>)? windowEvents;
  final Future<void> Function()? release;

  _WindowingFake(this.windows, {this.eventFor, this.windowEvents, this.release})
    : assert((eventFor == null) != (windowEvents == null));

  @override
  Future<List<StoredUploadEventDto>> decodeStoredUploadEvents({
    required String specYaml,
    required List<List<int>> notifications,
  }) async {
    windows.add([for (final n in notifications) List.of(n)]);
    await release?.call();
    final perNotification = eventFor;
    if (perNotification != null) {
      return [for (final n in notifications) ?perNotification(n)];
    }
    return windowEvents!(notifications);
  }
}
