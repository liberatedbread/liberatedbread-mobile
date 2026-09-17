// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The screen that makes the app's logging reachable from the device it runs
// on. Everything it shows comes from `Log.buffer`; everything it changes is a
// live setting on `Log`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';
import 'package:liberated_bread_mobile/screens/diagnostics_screen.dart';

void main() {
  late LogSink? suiteDefaultSink;
  late LogBuffer? suiteBuffer;

  setUp(() {
    suiteDefaultSink = Log.defaultSink;
    suiteBuffer = Log.buffer;
    // The suite runs with the buffer off (nothing reads it there); this screen
    // is the thing that reads it, so it gets one.
    Log.buffer = LogBuffer();
  });

  tearDown(() {
    Log.defaultSink = suiteDefaultSink;
    Log.buffer = suiteBuffer;
    Log.reset();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DiagnosticsScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('shows what the app logged, newest first', (tester) async {
    // Newest first because the screen is opened right after the thing
    // happened, and the answer is at the end of the log.
    Log.minLevel = LogLevel.debug;
    Log.net.info('network scan finished');
    Log.ble.warning('adapter turned off');

    await pump(tester);

    expect(find.text('network scan finished'), findsOneWidget);
    expect(find.text('adapter turned off'), findsOneWidget);
    final first = tester.getTopLeft(find.text('adapter turned off'));
    final second = tester.getTopLeft(find.text('network scan finished'));
    expect(first.dy, lessThan(second.dy));
  });

  testWidgets('an error and stack ride along with the line', (tester) async {
    Log.minLevel = LogLevel.debug;
    Log.ha.error('registration failed', error: StateError('no route'));

    await pump(tester);

    expect(find.text('registration failed'), findsOneWidget);
    expect(find.textContaining('Bad state: no route'), findsOneWidget);
  });

  testWidgets('the view filter narrows without changing what is captured', (
    tester,
  ) async {
    // A reader narrowing to warnings must not stop the app recording debug
    // lines they may want a moment later.
    Log.minLevel = LogLevel.debug;
    Log.net.debug('datagram from 10.0.0.4');
    Log.net.warning('SSDP discovery failed');

    await pump(tester);
    expect(find.text('datagram from 10.0.0.4'), findsOneWidget);

    await tester.tap(find.text('DEBUG and up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WARN and up').last);
    await tester.pumpAndSettle();

    expect(find.text('datagram from 10.0.0.4'), findsNothing);
    expect(find.text('SSDP discovery failed'), findsOneWidget);
    expect(Log.minLevel, LogLevel.debug, reason: 'capture is untouched');
  });

  testWidgets('a category chip turns that category up, and only it', (
    tester,
  ) async {
    Log.minLevel = LogLevel.info;
    Log.net.info('anchor');
    await pump(tester);

    // The capture row lists every category; the view row lists only the ones
    // present. Both spell 'net', so the capture chip is the first.
    await tester.tap(find.widgetWithText(FilterChip, 'net').first);
    await tester.pumpAndSettle();

    expect(Log.categoryLevel(Log.net), LogLevel.debug);
    expect(Log.categoryLevel(Log.ble), isNull);
    expect(Log.minLevel, LogLevel.info);

    await tester.tap(find.widgetWithText(FilterChip, 'net').first);
    await tester.pumpAndSettle();
    expect(Log.categoryLevel(Log.net), isNull);
  });

  testWidgets('copy puts the visible lines on the clipboard', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    Log.minLevel = LogLevel.debug;
    Log.net.debug('chatter');
    Log.net.warning('SSDP discovery failed');
    await pump(tester);

    // Narrow first: what gets copied is what was on screen, because a report
    // of thirty relevant lines gets read and one of five hundred does not.
    await tester.tap(find.text('DEBUG and up'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WARN and up').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Copy for a bug report'));
    await tester.pumpAndSettle();

    expect(copied.single, contains('SSDP discovery failed'));
    expect(copied.single, isNot(contains('chatter')));
  });

  testWidgets('clear empties the buffer', (tester) async {
    Log.minLevel = LogLevel.debug;
    Log.app.info('started');
    await pump(tester);
    expect(find.text('started'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('started'), findsNothing);
    expect(find.textContaining('Nothing recorded'), findsOneWidget);
  });

  testWidgets('says so when recording is off rather than looking empty', (
    tester,
  ) async {
    Log.buffer = null;
    await pump(tester);
    expect(find.textContaining('recording is off'), findsOneWidget);
  });

  testWidgets('a secret redacted at the call site stays redacted here', (
    tester,
  ) async {
    // The screen renders records verbatim and offers them to the clipboard, so
    // it is the last place a leaked secret would become someone else's. The
    // rule is upstream — redact at the call site — and this pins that nothing
    // here undoes it.
    Log.minLevel = LogLevel.debug;
    Log.ha.info(
      'registering ${logFields({'token': redact('s3cret-token'), 'webhook': redact(null)})}',
    );

    await pump(tester);

    expect(find.textContaining('token=<redacted>'), findsOneWidget);
    expect(find.textContaining('s3cret-token'), findsNothing);
  });
}
