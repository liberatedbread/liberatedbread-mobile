// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/widgets/raw_characteristic_widget.dart';

import '../fakes/fake_ble_service.dart';

Widget _wrap(Widget child, FakeBleService fake) => ProviderScope(
  overrides: [bleServiceProvider.overrideWithValue(fake)],
  child: MaterialApp(
    home: Scaffold(body: ListView(children: [child])),
  ),
);

const _charUuid = '00002a19-0000-1000-8000-00805f9b34fb';
const _serviceUuid = '0000180f-0000-1000-8000-00805f9b34fb';

void main() {
  testWidgets('readable characteristic shows hex value after read', (
    tester,
  ) async {
    final fake = FakeBleService(
      readValues: {
        _charUuid: const [0x55, 0xaa],
      },
    );
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        fake,
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('55 aa'), findsOneWidget);
  });

  testWidgets('read error is surfaced in the subtitle', (tester) async {
    final fake = FakeBleService(readError: StateError('denied'));
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        fake,
      ),
    );

    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not read this characteristic'),
      findsOneWidget,
    );
    expect(find.textContaining('Bad state'), findsNothing);
  });

  testWidgets('writable characteristic writes parsed hex bytes', (
    tester,
  ) async {
    final fake = FakeBleService();
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: false,
            canWrite: true,
            canWriteWithoutResponse: true,
            canNotify: false,
          ),
        ),
        fake,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '01 aa ff');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(fake.writes.length, 1);
    expect(fake.writes.single.value, const [0x01, 0xaa, 0xff]);
    expect(find.textContaining('Wrote 01 aa ff'), findsOneWidget);
  });

  testWidgets('invalid hex is rejected without a write', (tester) async {
    final fake = FakeBleService();
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ),
        fake,
      ),
    );
    await tester.pumpAndSettle();

    // `zz` no longer reaches the parser (the field filters it out); an odd
    // digit count is what the parser still has to reject.
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(fake.writes, isEmpty);
    expect(find.textContaining('Invalid hex'), findsOneWidget);
  });

  testWidgets('read-only characteristic offers no write field', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        FakeBleService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('non-readable characteristic renders no-value placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ),
        FakeBleService(),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('(no value)'), findsOneWidget);
  });

  testWidgets('printable values also render as ASCII', (tester) async {
    // The capability the deleted CharacteristicScreen had and the live browser
    // did not: seeing "OK" next to "4f 4b" while reverse-engineering.
    final fake = FakeBleService(
      readValues: {
        _charUuid: const [0x4f, 0x4b],
      },
    );
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        fake,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('4f 4b'), findsOneWidget);
    expect(find.text('"OK"'), findsOneWidget);
  });

  testWidgets('binary values show hex only', (tester) async {
    final fake = FakeBleService(
      readValues: {
        _charUuid: const [0x01, 0x80, 0xff],
      },
    );
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        fake,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('01 80 ff'), findsOneWidget);
    expect(find.textContaining('"'), findsNothing);
  });

  // F-055: the error, write-status and placeholder lines used
  // Colors.red/green/grey literals, which fail contrast on the light surface
  // and ignore dark mode.
  testWidgets('status lines use theme roles, not literals', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        FakeBleService(readError: StateError('denied')),
      ),
    );
    await tester.pumpAndSettle();
    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    expect(
      tester
          .widget<Text>(
            find.textContaining('Could not read this characteristic'),
          )
          .style
          ?.color,
      scheme.error,
    );

    // A fresh tree, not a rebuild: pumping the same widget shape reuses its
    // State and the first read (the error) would stay on screen.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: false,
            canWrite: true,
            canWriteWithoutResponse: true,
            canNotify: false,
          ),
        ),
        FakeBleService(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('(no value)')).style?.color,
      scheme.onSurfaceVariant,
    );

    await tester.enterText(find.byType(TextField), '01 aa ff');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.textContaining('Wrote 01 aa ff')).style?.color,
      scheme.tertiary,
    );
  });

  testWidgets('a notification after a failed read shows the value, not the '
      'read error', (tester) async {
    // Old code: `_error` was cleared only by a read and checked before the
    // value, so 'Error: Could not read...' stayed up while notifications
    // kept arriving underneath it.
    final notify = StreamController<List<int>>();
    addTearDown(notify.close);
    final fake = FakeBleService(
      readError: StateError('denied'),
      notifyStream: notify.stream,
    );
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: true,
          ),
        ),
        fake,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not read'), findsOneWidget);

    notify.add(const [0x12, 0x34]);
    await tester.pumpAndSettle();
    expect(find.text('12 34'), findsOneWidget);
    expect(find.textContaining('Could not read'), findsNothing);
  });

  testWidgets('a notify error keeps the last value on screen', (tester) async {
    final notify = StreamController<List<int>>();
    addTearDown(notify.close);
    final fake = FakeBleService(notifyStream: notify.stream);
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: false,
            canWrite: false,
            canNotify: true,
          ),
        ),
        fake,
      ),
    );
    notify.add(const [0xab]);
    await tester.pumpAndSettle();
    notify.addError(StateError('link lost'));
    await tester.pumpAndSettle();
    expect(find.text('ab'), findsOneWidget);
    expect(find.textContaining('Live updates stopped'), findsOneWidget);
  });

  const writable = BleDiscoveredCharacteristic(
    uuid: _charUuid,
    canRead: false,
    canWrite: true,
    canWriteWithoutResponse: true,
    canNotify: false,
  );

  // Screenshot 24/25: the result was a separate Text under the field, so
  // with the keyboard up the field scrolled into view and the result line
  // was cut in half at the keyboard edge. In the decoration, it scrolls with
  // the field.
  testWidgets('write results render in the field decoration', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: writable,
        ),
        FakeBleService(),
      ),
    );
    await tester.pumpAndSettle();
    InputDecoration decoration() =>
        tester.widget<TextField>(find.byType(TextField)).decoration!;

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(decoration().errorText, contains('Invalid hex'));
    expect(decoration().helperText, isNull);
    // The result is the field's own: no 'Error: ' prefix used nowhere else.
    expect(find.textContaining('Error:'), findsNothing);

    await tester.enterText(find.byType(TextField), '01 ff 42');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(decoration().errorText, isNull);
    expect(decoration().helperText, 'Wrote 01 ff 42');
  });

  // Screenshots 24/25 (round 3): the "Value" caption pushed the field to
  // the keyboard's edge and the result line was cut in half. A widget test
  // has no keyboard inset, so this does not reproduce that (it passes on
  // the old code too); it pins the contract, and the walkthrough's shots
  // are the check against the real keyboard.
  testWidgets('a write result is scrolled fully into view', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bleServiceProvider.overrideWithValue(_RejectingBle())],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                // Filler so the field sits right at the viewport's bottom
                // edge, as it does above an open keyboard.
                SizedBox(
                  height:
                      tester.view.physicalSize.height /
                      tester.view.devicePixelRatio,
                ),
                const RawCharacteristicWidget(
                  deviceId: '01',
                  serviceUuid: _serviceUuid,
                  characteristic: writable,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Scroll so the field's bottom edge is exactly the viewport's, where
    // the keyboard leaves it (ensureVisible would park it at the top).
    final field = find.byType(TextField, skipOffstage: false);
    final viewport = tester.getRect(find.byType(ListView));
    scroll.jumpTo(
      scroll.offset + tester.getRect(field).bottom - viewport.bottom,
    );
    await tester.pumpAndSettle();

    // A valid payload the device rejects: its error arrives after the
    // write, with no keystroke to scroll it into view, and runs to lines
    // the default scroll padding does not cover.
    await tester.enterText(find.byType(TextField), '01');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    final error = find.textContaining('rejected');
    expect(error, findsOneWidget);
    expect(tester.getRect(error).bottom, lessThanOrEqualTo(viewport.bottom));
  });

  testWidgets('the hex field is not a prose field', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: writable,
        ),
        FakeBleService(),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.smartDashesType, SmartDashesType.disabled);
    expect(field.smartQuotesType, SmartQuotesType.disabled);
    expect(field.keyboardType, TextInputType.visiblePassword);

    // Everything the parser accepts survives the filter...
    const accepted = '0x01,0XAA 01:aa-ff\t0b';
    await tester.enterText(find.byType(TextField), accepted);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      accepted,
    );
    // ...and an edit holding anything it could only reject is refused
    // whole. Regression: stripping characters turned a pasted
    // '01 02 // comment' into '01 02 ce', valid bytes nobody typed.
    await tester.enterText(find.byType(TextField), '01 02 // comment');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      accepted,
    );
  });

  testWidgets('a failed read shows no "Error: " prefix', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        FakeBleService(readError: StateError('denied')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not read this characteristic.'), findsOneWidget);
    expect(find.textContaining('Error:'), findsNothing);
  });

  // Screenshot 23: the R/W/N chips shared the UUID's row, which wrapped the
  // 128-bit UUID mid-string on a phone.
  testWidgets('the UUID has its own line above the property chips', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: true,
            canNotify: true,
          ),
        ),
        FakeBleService(),
      ),
    );
    await tester.pumpAndSettle();
    final uuid = tester.getRect(find.text(_charUuid));
    for (final p in ['R', 'W', 'N']) {
      final chip = tester.getRect(find.widgetWithText(Chip, p));
      expect(chip.top, greaterThanOrEqualTo(uuid.bottom), reason: p);
    }
  });

  // Screenshots 23-25: the trailing refresh button narrowed the title, and
  // the UUID still wrapped one character onto a second line.
  testWidgets('the UUID stays on one line beside no trailing button', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: true,
          ),
        ),
        FakeBleService(
          readValues: {
            _charUuid: const [0x0a],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final uuid = find.text(_charUuid);
    final lines = tester
        .renderObject<RenderParagraph>(uuid)
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: _charUuid.length),
        )
        .map((b) => b.top)
        .toSet();
    expect(lines, hasLength(1));
    // Nothing shares the UUID's row: the refresh button sits with the chips.
    final refresh = find.byTooltip('Read this characteristic again');
    expect(refresh, findsOneWidget);
    expect(
      tester.getRect(refresh).top,
      greaterThanOrEqualTo(tester.getRect(uuid).bottom),
    );
  });

  // Screenshot 23: bare bytes under the chips read as another property.
  testWidgets('the read value is captioned', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const RawCharacteristicWidget(
          deviceId: '01',
          serviceUuid: _serviceUuid,
          characteristic: BleDiscoveredCharacteristic(
            uuid: _charUuid,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ),
        FakeBleService(
          readValues: {
            _charUuid: const [0x0a, 0x1b, 0x2c],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final caption = tester.getRect(find.text('Value'));
    final value = tester.getRect(find.text('0a 1b 2c'));
    expect(value.top, greaterThanOrEqualTo(caption.bottom));
  });
}

/// Rejects every write, for the error path that has no keystroke behind it.
class _RejectingBle extends FakeBleService {
  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    throw Exception(
      'GATT write rejected: the device refused the value it '
      'was sent (status 0x03, write not permitted)',
    );
  }
}
