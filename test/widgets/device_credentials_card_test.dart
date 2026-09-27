// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The generic "this device needs one more thing" prompt: what it hides while
// a secret is typed, and what it says when the keychain refuses the value.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/device_credentials_card.dart';

const _password = NetworkCredentialDto(
  name: 'password',
  description: 'The Wi-Fi password on the sticker.',
  neededBy: ['get_state'],
  mustBeAskedFor: true,
);

Widget _wrap(Future<void> Function(String, String) onSave) => MaterialApp(
  home: Scaffold(
    body: DeviceCredentialsCard(missing: const [_password], onSave: onSave),
  ),
);

void main() {
  testWidgets('the typed value is hidden until the person asks to see it', (
    tester,
  ) async {
    // Old code: no obscureText, so a password showed in clear on screen and
    // in the app-switcher snapshot.
    await tester.pumpWidget(_wrap((_, _) async {}));
    await tester.tap(find.text('Enter password'));
    await tester.pumpAndSettle();

    TextField field() => tester.widget<TextField>(find.byType(TextField));
    expect(field().obscureText, isTrue);
    expect(field().enableSuggestions, isFalse);
    expect(field().autocorrect, isFalse);

    await tester.tap(find.byTooltip('Show'));
    await tester.pump();
    expect(field().obscureText, isFalse);
    expect(field().enableSuggestions, isFalse);
    expect(find.byTooltip('Hide'), findsOneWidget);
  });

  testWidgets('a keychain refusal says so without echoing the value', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap((_, _) async {
        throw PlatformException(code: 'locked');
      }),
    );
    await tester.tap(find.text('Enter password'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 's3cret');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Could not store password'), findsOneWidget);
    expect(find.textContaining('s3cret'), findsNothing);
    // Still missing, so the card still asks.
    expect(find.text('This device needs one more thing'), findsOneWidget);
    expect(find.text('Enter password'), findsOneWidget);
  });
}
