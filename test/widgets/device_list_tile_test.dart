// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// F-017: the subtitle row's trailing detail (host:port on the Wi-Fi tab) was
// a bare Text beside a Flexible subtitle, so once the subtitle had shrunk to
// nothing the Row overflowed — at accessibility text sizes, or in iPad Slide
// Over, the address was clipped off the right edge.
//
// The title row had the opposite failure: two Flexibles in a Row split the
// width between them when both were too wide, so a long device name and its
// support badge were BOTH ellipsised, and the badge — the row's one claim
// about the device — lost its last word ("Likely Nuki Smart L…" beside
// "Holden's AirPods Pro #9" on an iPhone). The badge now keeps its text and
// drops to its own line when the name leaves it no room.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/device_list_tile.dart';

const _address = '192.168.100.100:49153';
const _addressDetail = '  ·  $_address';

/// The name from the iPhone report. In the test font it is wider than the
/// whole text column at every phone width, so it is always ellipsised.
const _longTitle = "Holden's AirPods Pro #9";

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double textScale = 1.0,
  String title = 'Hue Bridge',
  String subtitle = 'mDNS + SSDP',
  String detail = _address,
  String badge = 'Supported',
}) async {
  tester.view.physicalSize = Size(width, 400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: ListView(
              children: [
                DeviceListTile(
                  title: title,
                  subtitle: subtitle,
                  detail: detail,
                  rssi: -67,
                  badge: badge,
                  badgeIsClaim: true,
                  // The chevron a tappable row draws is part of the width
                  // budget the title and badge share, so the tests keep it.
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text));

void main() {
  testWidgets('a host:port detail never overflows the row, at any phone '
      'width or text size', (tester) async {
    for (final width in const [320.0, 375.0, 390.0]) {
      for (final scale in const [1.0, 2.0, 3.0]) {
        await _pump(
          tester,
          width: width,
          textScale: scale,
          subtitle: 'mDNS + SSDP',
          detail: _address,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$width pt at ${scale}x overflowed',
        );
        expect(find.text(_addressDetail), findsOneWidget);
      }
    }
  });

  testWidgets('the detail ellipsizes inside the row instead of running past '
      'its edge', (tester) async {
    await _pump(
      tester,
      width: 320,
      textScale: 3.0,
      subtitle: 'mDNS + SSDP',
      detail: _address,
    );

    expect(tester.takeException(), isNull);
    expect(_paragraph(tester, _addressDetail).didExceedMaxLines, isTrue);
    final tile = tester.getRect(find.byType(DeviceListTile));
    expect(
      tester.getRect(find.text(_addressDetail)).right,
      lessThanOrEqualTo(tile.right),
    );
  });

  testWidgets('at a comfortable width neither text is cut', (tester) async {
    await _pump(
      tester,
      width: 900,
      textScale: 1.0,
      subtitle: 'mDNS + SSDP',
      detail: _address,
    );

    expect(tester.takeException(), isNull);
    expect(_paragraph(tester, _addressDetail).didExceedMaxLines, isFalse);
    expect(_paragraph(tester, 'mDNS + SSDP').didExceedMaxLines, isFalse);
  });

  testWidgets('the subtitle gives way before the detail loses a character', (
    tester,
  ) async {
    // Wide enough for the address alone, not for the subtitle beside it.
    await _pump(
      tester,
      width: 520,
      textScale: 1.0,
      subtitle: 'A subtitle far too long to share the line with an address',
      detail: _address,
    );

    expect(tester.takeException(), isNull);
    expect(_paragraph(tester, _addressDetail).didExceedMaxLines, isFalse);
    expect(
      _paragraph(
        tester,
        'A subtitle far too long to share the line with an address',
      ).didExceedMaxLines,
      isTrue,
    );
  });

  group('the title row', () {
    testWidgets('a long name is the one that gets cut; the badge keeps every '
        'word and moves under it', (tester) async {
      // The test font is about twice as wide as the iPhone's, so the report's
      // "Likely Nuki Smart Lock" is wider than the tile's text column at 360
      // pt on its own — that is the pathological case below, not this one.
      // One word shorter, the badge fits the column with room to spare while
      // still being far too wide to share the line with the name.
      const badge = 'Likely Nuki Lock';
      await _pump(tester, width: 360, title: _longTitle, badge: badge);

      expect(tester.takeException(), isNull);
      expect(find.text(badge), findsOneWidget);
      expect(_paragraph(tester, badge).didExceedMaxLines, isFalse);
      expect(_paragraph(tester, _longTitle).didExceedMaxLines, isTrue);

      // Under the name, not beside a shrunken version of it: the badge's
      // whole text is the point, so the name yields the line rather than
      // the width.
      final title = tester.getRect(find.text(_longTitle));
      final badgeRect = tester.getRect(find.text(badge));
      expect(badgeRect.top, greaterThanOrEqualTo(title.bottom));
      // The pill, not its text: the text sits 8 px inside the pill's
      // padding, so measuring it would put the assertion exactly on any
      // tolerance and fail for a padding change rather than a layout one.
      final pill = tester.getRect(
        find
            .ancestor(of: find.text(badge), matching: find.byType(Container))
            .first,
      );
      expect(pill.left, title.left);
    });

    testWidgets('the reported badge fits whole at an iPhone width', (
      tester,
    ) async {
      // The exact string from the bug report, at the 390 pt of the phone it
      // was seen on. 360 pt is this string's pathological width in the test
      // font (see the case above), so the verbatim report is pinned here.
      const badge = 'Likely Nuki Smart Lock';
      await _pump(tester, width: 390, title: _longTitle, badge: badge);

      expect(tester.takeException(), isNull);
      expect(_paragraph(tester, badge).didExceedMaxLines, isFalse);
      expect(_paragraph(tester, _longTitle).didExceedMaxLines, isTrue);
      final title = tester.getRect(find.text(_longTitle));
      expect(
        tester.getRect(find.text(badge)).top,
        greaterThanOrEqualTo(title.bottom),
      );
    });

    testWidgets('a short name and a short badge share one line', (
      tester,
    ) async {
      // The Radios group's row: a handset name and its one-word badge.
      await _pump(tester, width: 360, title: 'UV-5R', badge: 'Radio');

      expect(tester.takeException(), isNull);
      expect(_paragraph(tester, 'UV-5R').didExceedMaxLines, isFalse);
      expect(_paragraph(tester, 'Radio').didExceedMaxLines, isFalse);

      final title = tester.getRect(find.text('UV-5R'));
      final badge = tester.getRect(find.text('Radio'));
      // Same line — the badge starts above the name's baseline row, and to
      // its right — so a name that fits does not push its badge down for
      // nothing.
      expect(badge.top, lessThan(title.bottom));
      expect(badge.bottom, greaterThan(title.top));
      expect(badge.left, greaterThan(title.right));
    });

    testWidgets('a badge wider than the tile ellipsises on its own line '
        'instead of overflowing', (tester) async {
      const badge =
          'Likely a Nuki Smart Lock, third generation, with the keypad';
      for (final scale in const [1.0, 2.0, 3.0]) {
        await _pump(
          tester,
          width: 360,
          textScale: scale,
          title: 'Ember Mug',
          badge: badge,
        );

        expect(
          tester.takeException(),
          isNull,
          reason: 'at ${scale}x the title row overflowed',
        );
        expect(find.text(badge), findsOneWidget);
        // The badge's own maxLines: 1 is what cuts it, and only because it
        // cannot fit the column by itself — not because the name took some.
        expect(_paragraph(tester, badge).didExceedMaxLines, isTrue);
        final tile = tester.getRect(find.byType(DeviceListTile));
        final badgeRect = tester.getRect(find.text(badge));
        expect(badgeRect.right, lessThanOrEqualTo(tile.right));
        expect(badgeRect.left, greaterThanOrEqualTo(tile.left));
      }
    });

    testWidgets('a name that fits is never cut to make room for the badge', (
      tester,
    ) async {
      // The name alone fits the column; the badge alone does not. Before the
      // fix the Row would have shared the width and cut both.
      const badge =
          'Likely a Nuki Smart Lock, third generation, with the keypad';
      await _pump(tester, width: 360, title: 'Ember Mug', badge: badge);

      expect(tester.takeException(), isNull);
      expect(_paragraph(tester, 'Ember Mug').didExceedMaxLines, isFalse);
      final title = tester.getRect(find.text('Ember Mug'));
      final badgeRect = tester.getRect(find.text(badge));
      expect(badgeRect.top, greaterThanOrEqualTo(title.bottom));
    });
  });
}
