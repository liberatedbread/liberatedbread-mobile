// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/core/ha_url.dart';
import 'package:opengreeniot_mobile/widgets/tailscale_suggestion_card.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('suggests Tailscale for private LAN addresses', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_wrap(TailscaleSuggestionCard(
      kind: HaUrlKind.privateLan,
      onLearnMore: () => tapped = true,
    )));

    expect(
        find.textContaining('only works on your home network'), findsOneWidget);
    expect(find.textContaining('Tailscale'), findsWidgets);

    await tester.tap(find.text('Set up Tailscale'));
    expect(tapped, isTrue);
  });

  testWidgets('suggests Tailscale for .local addresses', (tester) async {
    await tester.pumpWidget(_wrap(const TailscaleSuggestionCard(
      kind: HaUrlKind.mdnsLocal,
    )));
    expect(
        find.textContaining('only works on your home network'), findsOneWidget);
  });

  testWidgets('confirms a detected tailnet address', (tester) async {
    await tester.pumpWidget(_wrap(const TailscaleSuggestionCard(
      kind: HaUrlKind.tailscale,
    )));
    expect(find.text('Tailscale detected'), findsOneWidget);
    expect(find.textContaining('Secure remote access ready'), findsOneWidget);
  });

  testWidgets('warns about public plain HTTP', (tester) async {
    await tester.pumpWidget(_wrap(TailscaleSuggestionCard(
      kind: HaUrlKind.publicHttp,
      onLearnMore: () {},
    )));
    expect(find.text('Unencrypted connection'), findsOneWidget);
  });

  testWidgets('renders nothing for HTTPS and invalid input', (tester) async {
    await tester.pumpWidget(_wrap(const TailscaleSuggestionCard(
      kind: HaUrlKind.publicHttps,
    )));
    expect(find.byType(Card), findsNothing);

    await tester.pumpWidget(_wrap(const TailscaleSuggestionCard(
      kind: HaUrlKind.invalid,
    )));
    expect(find.byType(Card), findsNothing);
  });
}
