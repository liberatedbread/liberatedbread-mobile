// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/web_link.dart';

void main() {
  group('isWebLink', () {
    test('accepts http and https with a host', () {
      expect(isWebLink(Uri.parse('https://example.com/advisory')), isTrue);
      expect(isWebLink(Uri.parse('http://192.168.1.2/fix')), isTrue);
    });

    test('rejects everything a spec pack could smuggle in', () {
      for (final url in const [
        'shortcuts://run-shortcut?name=Wipe%20Phone',
        'tel:911',
        'sms:+15555550100?body=hi',
        'itms-services://?action=download-manifest&url=https://x/y.plist',
        'facetime-audio:someone@example.com',
        'javascript:alert(1)',
        'data:text/html,<script>alert(1)</script>',
        'file:///etc/passwd',
        '//example.com/scheme-relative',
        'https://',
        'https:///no-host',
        'not a url at all',
        '',
      ]) {
        expect(isWebLink(Uri.tryParse(url)), isFalse, reason: url);
      }
      expect(isWebLink(null), isFalse);
    });
  });

  group('openWebLink', () {
    Future<(List<Uri>, WidgetTester)> pumpWith(
      WidgetTester tester,
      String url,
    ) async {
      final launched = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openWebLink(
                  context,
                  url,
                  launcher: (uri) async {
                    launched.add(uri);
                    return true;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      return (launched, tester);
    }

    testWidgets('launches a web link', (tester) async {
      final (launched, _) = await pumpWith(tester, 'https://example.com/a');
      expect(launched, [Uri.parse('https://example.com/a')]);
      expect(find.textContaining('Could not open'), findsNothing);
    });

    testWidgets('never launches a non-web scheme, and says so', (tester) async {
      final (launched, _) = await pumpWith(
        tester,
        'shortcuts://run-shortcut?name=X',
      );
      expect(
        launched,
        isEmpty,
        reason: 'a spec-supplied custom scheme must not reach the OS',
      );
      expect(
        find.text('Could not open shortcuts://run-shortcut?name=X'),
        findsOneWidget,
      );
    });

    testWidgets('reports a launcher that threw', (tester) async {
      // url_launcher raises a PlatformException where a platform has no
      // handler for the scheme; the promise is a SnackBar, not an unhandled
      // async error out of a tap.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openWebLink(
                  context,
                  'https://example.com',
                  launcher: (_) =>
                      Future.error(PlatformException(code: 'NO_ACTIVITY')),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(find.text('Could not open https://example.com'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('reports a launcher that declined', (tester) async {
      var asked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openWebLink(
                  context,
                  'https://example.com',
                  launcher: (_) {
                    asked++;
                    return Future.value(false);
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(asked, 1);
      expect(find.text('Could not open https://example.com'), findsOneWidget);
    });
  });
}
