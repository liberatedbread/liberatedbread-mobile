// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The image editor on a device that is not on BLE: a Wi-Fi LOY SPACE panel.
// Pictures and the size query go through the link and nothing touches the
// BLE service. What the link does with them over UDP is
// popled_udp_control_service_test.dart's business.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart'
    show sharedPreferencesProvider;
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/led_image_link.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/led_image_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

/// led-space.yaml's surface as the core reports it: popled, 64x64 at most,
/// size stated by the panel.
const _panel = ImageUploadDto(
  handler: 'popled_json',
  encodable: true,
  format: 'zlib-bmp',
  maxWidth: 64,
  maxHeight: 64,
  resolutionDeviceReported: true,
  animation: true,
  animatedUpload: true,
);

class _Link implements LedImageLink {
  _Link({this.size});
  final ({int width, int height})? size;
  final sent = <({int width, int height, int bytes})>[];
  var asked = 0;

  @override
  Future<void> sendImage(
    Uint8List rgb,
    int width,
    int height,
    String specYaml,
  ) async {
    sent.add((width: width, height: height, bytes: rgb.length));
  }

  @override
  Future<({int width, int height})?> panelSize() async {
    asked++;
    return size;
  }
}

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<FakeBleService> pump(WidgetTester tester, _Link link) async {
    final ble = FakeBleService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(FakeSpecCodec()),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 300,
                child: LedImageWidget(
                  deviceId: '192.168.4.1',
                  imageUpload: _panel,
                  specYaml: 'yaml',
                  link: link,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ble;
  }

  testWidgets('the canvas takes the size the panel states over its link', (
    tester,
  ) async {
    final link = _Link(size: (width: 32, height: 16));
    await pump(tester, link);
    expect(link.asked, 1);

    final send = find.text('Send to device');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(link.sent.single.width, 32);
    expect(link.sent.single.height, 16);
    expect(link.sent.single.bytes, 32 * 16 * 3);
  });

  testWidgets('a send goes through the link and never to BLE', (tester) async {
    final link = _Link();
    final ble = await pump(tester, link);

    final send = find.text('Send to device');
    await tester.ensureVisible(send);
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(link.sent, hasLength(1));
    expect(ble.writes, isEmpty);
  });
}
