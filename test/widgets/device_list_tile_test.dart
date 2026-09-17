// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// F-017: the subtitle row's trailing detail (host:port on the Wi-Fi tab) was
// a bare Text beside a Flexible subtitle, so once the subtitle had shrunk to
// nothing the Row overflowed — at accessibility text sizes, or in iPad Slide
// Over, the address was clipped off the right edge.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/device_list_tile.dart';

const _address = '192.168.100.100:49153';
const _addressDetail = '  ·  $_address';

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double textScale,
  required String subtitle,
  required String detail,
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
                  title: 'Hue Bridge',
                  subtitle: subtitle,
                  detail: detail,
                  rssi: -67,
                  badge: 'Supported',
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
}
