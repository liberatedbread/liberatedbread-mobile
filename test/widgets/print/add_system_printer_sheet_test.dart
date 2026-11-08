// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// "Add to system printers": per-platform instructions, never an action the
// platform cannot take — and label printers stay in the app.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/print/add_system_printer_sheet.dart';

Future<void> _pump(WidgetTester tester, {bool labelPrinter = false}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddSystemPrinterSheet(
            printerName: 'Office Laser',
            host: '192.168.1.50',
            labelPrinter: labelPrinter,
          ),
        ),
      ),
    );

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the lpadmin command names a safe queue and the IPP resource', () {
    expect(
      lpadminCommand(printerName: 'Office Laser (2F)', host: '192.168.1.50'),
      "lpadmin -p Office_Laser_2F -E -v 'ipp://192.168.1.50:631/ipp/print' "
      '-m everywhere',
    );
    expect(
      lpadminCommand(
        printerName: '***',
        host: 'h',
        resourcePath: '/ipp/printer',
      ),
      "lpadmin -p Printer -E -v 'ipp://h:631/ipp/printer' -m everywhere",
    );
  });

  test('the lpadmin command shell-quotes the advertised resource', () {
    expect(
      lpadminCommand(
        printerName: 'Office Laser',
        host: 'printer.local',
        resourcePath: "/ipp/print;id;\$HOME&'quoted'",
      ),
      'lpadmin -p Office_Laser -E -v '
      "'ipp://printer.local:631/ipp/print;id;\$HOME&'\\''quoted'\\''' "
      '-m everywhere',
    );
  });

  testWidgets('iOS: nothing to add', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await _pump(tester);
    expect(find.textContaining('Nothing to add'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: opens the print service settings', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('ca.pigscanfly.liberatedbread/print_settings'),
      (call) async {
        calls.add(call.method);
        return true;
      },
    );
    await _pump(tester);
    expect(find.textContaining('Default Print Service'), findsOneWidget);
    await tester.tap(find.text('Open print settings'));
    await tester.pump();
    expect(calls, ['open']);
    debugDefaultTargetPlatformOverride = null;
  });

  test('the IPP URI is IPv6-safe and drives the CUPS command', () {
    expect(
      ippDeviceUri(host: '2001:db8::50', resourcePath: '/ipp/printer'),
      'ipp://[2001:db8::50]:631/ipp/printer',
    );
    expect(
      lpadminCommand(
        printerName: 'Office Laser',
        host: '2001:db8::50',
        resourcePath: '/ipp/printer',
      ),
      contains("-v 'ipp://[2001:db8::50]:631/ipp/printer' -m everywhere"),
    );
  });

  testWidgets('Linux: copyable CUPS command and IPP URI', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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
    await _pump(tester);
    expect(find.textContaining('lpadmin -p Office_Laser'), findsOneWidget);
    expect(find.byTooltip('Copy command'), findsOneWidget);
    expect(find.text('Open CUPS'), findsOneWidget);

    await tester.tap(find.text('Copy IPP URI'));
    await tester.pump();
    expect(copied, 'ipp://192.168.1.50:631/ipp/print');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a label printer is printed from the app', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _pump(tester, labelPrinter: true);
    expect(find.textContaining('Compose a label'), findsOneWidget);
    expect(find.text('Open print settings'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
