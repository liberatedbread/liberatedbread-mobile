// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Printing, end to end on the device under test: the real app widgets, the
// real Rust core, the real sockets — and a printer on the other end that is a
// fake only in having no paper.
//
// WHAT THIS PROVES THAT THE UNIT SUITES DO NOT
//
// Every piece has its own tests: the Rust encoders against golden bytes, the
// composer against a recording target, the TCP transport against a local
// server. None of them shows that the pieces agree with each other — that the
// label the composer previews is the label the encoder places on the head,
// that the bytes the transport writes are a job the printer's language
// accepts, that the status screen reads what an IPP printer actually sends.
// Here a label is typed into the UI, printed, and the raster that crossed the
// socket is decoded back into dots and checked.
//
// The Brother QL on the far side speaks just enough of the raster language:
// it answers the `ESC i S` status request with a 62 mm continuous roll, then
// swallows the job. The IPP printer answers Get-Printer-Attributes with a
// canned reply. Both bind 127.0.0.1 on an ephemeral port, so the suite runs
// on every device job without a network.
//
// Wants the bridge: it belongs after native_core in ci_all_test.dart.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart'
    show specAssetPath;
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/screens/ipp_printer_screen.dart';
import 'package:liberated_bread_mobile/screens/label_printer_screen.dart';
import 'package:liberated_bread_mobile/screens/print_label_screen.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/print/print_target.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/mock_ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/frb_generated.dart'
    show RustLib;

const _brotherSpec = 'device-specs/devices/brother-ql-1110nwb.yaml';
const _ippSpec = 'device-specs/devices/ipp-network-printer.yaml';
const _niimbotSpec = 'device-specs/devices/niimbot-d110.yaml';

/// Where to write screenshots, when set (LB_SHOT_DIR=/some/dir).
final _shotDir = Platform.environment['LB_SHOT_DIR'];
final _shotKey = GlobalKey();

/// The app under test, inside a boundary a screenshot can be taken of.
Widget _app(Widget home) => ProviderScope(
  child: RepaintBoundary(
    key: _shotKey,
    child: MaterialApp(home: home),
  ),
);

Future<void> _screenshot(WidgetTester tester, String name) async {
  final dir = _shotDir;
  if (dir == null) return;
  await tester.runAsync(() async {
    final boundary =
        _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

/// A NIIMBOT D110 over "BLE": parses every packet the app writes, answers
/// each control packet with its reply id, reports the page done on its
/// second status poll, and keeps the rows it was sent.
class _EmulatedD110 implements BleService {
  final _notify = StreamController<List<int>>.broadcast();
  final _pending = <int>[];
  final commands = <int>[];
  final rows = <int, List<int>>{};
  int pageRows = 0;
  int pageCols = 0;
  int _polls = 0;
  bool _pageEnded = false;

  static const _replies = {
    0xC1: 0xC2,
    0x21: 0x31,
    0x23: 0x33,
    0x01: 0x02,
    0x20: 0x30,
    0x03: 0x04,
    0x13: 0x14,
    0x15: 0x16,
    0xE3: 0xE4,
    0xF3: 0xF4,
  };

  @override
  Future<int> mtu(String deviceId) async => 185;

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) => _notify.stream;

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    _pending.addAll(value);
    // Whole packets only: 55 55 cmd len data xor AA AA (connect has a 03
    // in front of it).
    while (true) {
      if (_pending.isNotEmpty && _pending[0] == 0x03) _pending.removeAt(0);
      if (_pending.length < 4) return;
      final len = _pending[3];
      if (_pending.length < len + 7) return;
      final packet = _pending.sublist(0, len + 7);
      _pending.removeRange(0, len + 7);
      _handle(packet[2], packet.sublist(4, 4 + len));
    }
  }

  void _handle(int cmd, List<int> data) {
    commands.add(cmd);
    void reply(int id, List<int> body) {
      final xor = body.fold(id ^ body.length, (a, b) => a ^ b);
      final bytes = [0x55, 0x55, id, body.length, ...body, xor, 0xAA, 0xAA];
      scheduleMicrotask(() => _notify.add(bytes));
    }

    switch (cmd) {
      case 0x13:
        pageRows = data[0] << 8 | data[1];
        pageCols = data[2] << 8 | data[3];
      case 0x84:
        final row = data[0] << 8 | data[1];
        for (var r = 0; r < data[2]; r++) {
          rows[row + r] = const [];
        }
        return;
      case 0x83:
      case 0x85:
        final row = data[0] << 8 | data[1];
        final repeat = data[5];
        final dots = <int>[];
        if (cmd == 0x83) {
          for (var i = 6; i + 1 < data.length; i += 2) {
            dots.add(data[i] << 8 | data[i + 1]);
          }
        } else {
          final bytes = data.sublist(6);
          for (var d = 0; d < bytes.length * 8; d++) {
            if (bytes[d ~/ 8] & (0x80 >> (d % 8)) != 0) dots.add(d);
          }
        }
        for (var r = 0; r < repeat; r++) {
          rows[row + r] = dots;
        }
        return;
      case 0xE3:
        _pageEnded = true;
      case 0xA3:
        _polls++;
        final done = _pageEnded && _polls >= 2 ? 1 : 0;
        reply(0xB3, [0x00, done, done * 100, done * 100]);
        return;
    }
    final id = _replies[cmd];
    if (id != null) reply(id, [0x01]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A Brother QL on loopback: answers the status request with a loaded 62 mm
/// continuous roll and keeps every job it is sent.
class _FakeBrother {
  final ServerSocket _server;
  final jobs = <Uint8List>[];
  final _jobArrived = StreamController<Uint8List>.broadcast();

  _FakeBrother._(this._server) {
    _server.listen((socket) {
      final received = BytesBuilder();
      socket.listen(
        (chunk) {
          received.add(chunk);
          final bytes = received.toBytes();
          // The status request alone: 1B 69 53. Answer it; a job is longer.
          if (bytes.length == 3 &&
              bytes[0] == 0x1B &&
              bytes[1] == 0x69 &&
              bytes[2] == 0x53) {
            socket.add(_statusReply());
          }
        },
        onDone: () {
          final bytes = received.takeBytes();
          if (bytes.length > 3) {
            jobs.add(bytes);
            _jobArrived.add(bytes);
          }
          socket.destroy();
        },
        onError: (Object _) => socket.destroy(),
      );
    });
  }

  static Future<_FakeBrother> start() async =>
      _FakeBrother._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  int get port => _server.port;

  /// The next job to arrive, however soon it lands after this is asked.
  Future<Uint8List> get nextJob {
    final next = Completer<Uint8List>();
    late final StreamSubscription<Uint8List> sub;
    sub = _jobArrived.stream.listen((job) {
      if (!next.isCompleted) next.complete(job);
      unawaited(sub.cancel());
    });
    return next.future;
  }

  Future<void> close() async {
    await _server.close();
    await _jobArrived.close();
  }

  /// 32 bytes: header 80 20 42, no errors, 62 mm continuous (0x0A).
  static Uint8List _statusReply() {
    final r = Uint8List(32);
    r.setAll(0, [0x80, 0x20, 0x42]);
    r[10] = 62;
    r[11] = 0x0A;
    return r;
  }
}

/// A Brother raster job decoded back into dots: the print's rows, each the
/// set of lit head-dot indices counted from the print's LEFT edge (the wire
/// is mirrored), plus what the job said about its media.
class _DecodedJob {
  final int mediaWidthMm;
  final int rowCount;
  final List<Set<int>> rows;
  final bool endsWithPrint;
  _DecodedJob(this.mediaWidthMm, this.rowCount, this.rows, this.endsWithPrint);

  static _DecodedJob parse(Uint8List job, {required int headDots}) {
    // ESC i z <flags> <type> <width> <length> <rows u32 LE> <page> <0>
    final z = _find(job, [0x1B, 0x69, 0x7A]);
    expect(z, greaterThanOrEqualTo(0), reason: 'no ESC i z media command');
    final width = job[z + 5];
    final rowCount = ByteData.sublistView(
      job,
      z + 7,
      z + 11,
    ).getUint32(0, Endian.little);
    // Rows start after the margin command ESC i d <u16>.
    final d = _find(job, [0x1B, 0x69, 0x64]);
    expect(d, greaterThan(z), reason: 'no ESC i d margin command');
    var i = d + 5;
    final rows = <Set<int>>[];
    final rowBytes = headDots ~/ 8;
    while (i < job.length && job[i] != 0x1A) {
      if (job[i] == 0x5A) {
        rows.add(<int>{});
        i += 1;
      } else if (job[i] == 0x67) {
        expect(job[i + 1], 0x00);
        expect(job[i + 2], rowBytes);
        final data = job.sublist(i + 3, i + 3 + rowBytes);
        final lit = <int>{};
        for (var dot = 0; dot < headDots; dot++) {
          if (data[dot ~/ 8] & (0x80 >> (dot % 8)) != 0) {
            lit.add(headDots - 1 - dot);
          }
        }
        rows.add(lit);
        i += 3 + rowBytes;
      } else {
        fail('unexpected raster opcode 0x${job[i].toRadixString(16)} at $i');
      }
    }
    return _DecodedJob(width, rowCount, rows, i < job.length && job[i] == 0x1A);
  }

  static int _find(Uint8List haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var k = 0; k < needle.length; k++) {
        if (haystack[i + k] != needle[k]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

/// Whether some row carries a QR finder pattern: dark:light:dark:light:dark
/// runs in the ratio 1:1:3:1:1.
bool _hasFinderPattern(List<Set<int>> rows, int headDots) {
  for (final row in rows) {
    if (row.length < 5) continue;
    final runs = <(bool, int)>[];
    bool? current;
    var length = 0;
    for (var x = 0; x < headDots; x++) {
      final dark = row.contains(x);
      if (dark == current) {
        length++;
      } else {
        if (current != null) runs.add((current, length));
        current = dark;
        length = 1;
      }
    }
    runs.add((current!, length));
    for (var k = 0; k + 5 <= runs.length; k++) {
      final w = runs.sublist(k, k + 5);
      if (!w[0].$1 || w[1].$1 || !w[2].$1 || w[3].$1 || !w[4].$1) continue;
      final unit = w[0].$2;
      if (unit < 2) continue;
      bool near(int n, int want) => (n - want * unit).abs() <= unit ~/ 2 + 1;
      if (near(w[1].$2, 1) &&
          near(w[2].$2, 3) &&
          near(w[3].$2, 1) &&
          near(w[4].$2, 1)) {
        return true;
      }
    }
  }
  return false;
}

/// An IPP printer on loopback that answers every POST with [reply].
Future<HttpServer> _fakeIpp(Uint8List reply, List<String> paths) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    paths.add(request.uri.path);
    await request.drain<void>();
    request.response
      ..headers.contentType = ContentType('application', 'ipp')
      ..add(reply);
    await request.response.close();
  });
  return server;
}

/// A Get-Printer-Attributes reply: stopped, out of paper, toner at 12%,
/// A4 loaded.
Uint8List _ippReply() {
  final b = BytesBuilder();
  void attr(int tag, String name, List<int> value) {
    b.add([tag, name.length >> 8, name.length & 0xFF, ...name.codeUnits]);
    b.add([value.length >> 8, value.length & 0xFF, ...value]);
  }

  List<int> i32(int v) => [
    v >> 24 & 0xFF,
    v >> 16 & 0xFF,
    v >> 8 & 0xFF,
    v & 0xFF,
  ];
  b.add([0x02, 0x00, 0x00, 0x00, 0, 0, 0, 1, 0x01]);
  attr(0x47, 'attributes-charset', 'utf-8'.codeUnits);
  b.addByte(0x04);
  attr(0x23, 'printer-state', i32(5));
  attr(0x44, 'printer-state-reasons', 'media-empty-error'.codeUnits);
  attr(0x41, 'printer-state-message', 'Load paper in tray 1'.codeUnits);
  attr(0x41, 'printer-make-and-model', 'Example LaserJet 400'.codeUnits);
  attr(0x42, 'marker-names', 'Black Toner'.codeUnits);
  attr(0x42, 'marker-colors', '#000000'.codeUnits);
  attr(0x44, 'marker-types', 'toner'.codeUnits);
  attr(0x21, 'marker-levels', i32(12));
  attr(0x21, 'marker-low-levels', i32(15));
  attr(0x44, 'media-ready', 'iso_a4_210x297mm'.codeUnits);
  b.addByte(0x03);
  return b.toBytes();
}

Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    if (!MockBleService.rustAvailable) await RustLib.init();
  });

  testWidgets(
    'a composed label reaches a Brother QL as the dots it previewed',
    (tester) async {
      final printer = await _FakeBrother.start();
      addTearDown(printer.close);
      final spec = await rootBundle.loadString(specAssetPath(_brotherSpec));

      await tester.pumpWidget(
        _app(
          LabelPrinterScreen(
            device: NetworkDevice(
              host: '127.0.0.1',
              name: 'Brother QL-1110NWB',
              port: printer.port,
              sources: const {NetworkDiscoverySource.mdns},
              discoveredAt: DateTime(2026, 1, 1),
            ),
            controls: NetworkControls(
              specYaml: spec,
              entities: const [],
              rasterPrintHandler: 'brother_ql_raster',
            ),
          ),
        ),
      );
      await _settle(tester);
      await _screenshot(tester, 'brother-status');

      // The fake answered the status request: the screen knows the roll.
      expect(find.text('Ready to print'), findsOneWidget);
      expect(find.text('62 mm continuous'), findsOneWidget);

      await tester.tap(find.text('Compose a label'));
      await _settle(tester);
      expect(find.textContaining('62mm continuous'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('label-line-0')),
        'Hello',
      );
      await tester.enterText(
        find.byKey(const ValueKey('label-qr')),
        'https://liberatedbread.example/p/1',
      );
      await _settle(tester);

      await _screenshot(tester, 'brother-composer');
      final job = printer.nextJob;
      // The composer is a lazy ListView: scroll until its Print button is
      // built, then tap it.
      await tester.scrollUntilVisible(
        find.text('Print'),
        200,
        // The composer's list: the nearest scrollable around one of its
        // fields (a TextField has scrollables of its own, below it).
        scrollable: find
            .ancestor(
              of: find.byKey(const ValueKey('label-qr')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Print'));
      final bytes = await job.timeout(const Duration(seconds: 20));
      await _settle(tester, rounds: 5);
      expect(find.text('Label sent.'), findsOneWidget);

      // The job is the Brother raster language, opened and closed properly.
      expect(bytes.sublist(0, 4), [
        0x1B,
        0x69,
        0x61,
        0x01,
      ], reason: 'raster mode');
      final decoded = _DecodedJob.parse(bytes, headDots: 1296);
      expect(decoded.endsWithPrint, isTrue, reason: 'ends with 1A');
      expect(decoded.mediaWidthMm, 62);
      expect(decoded.rows.length, decoded.rowCount);

      // Something printed, all of it inside the 62 mm roll's printable dots —
      // clear of the head's right-hand dead zone and the roll's margin.
      final lit = decoded.rows.expand((r) => r).toList();
      expect(lit.length, greaterThan(500), reason: 'text and a QR code');
      const deadZone = 44, rightMargin = 12;
      const rightmostPrintable = 1296 - 1 - deadZone - rightMargin;
      expect(
        lit.reduce((a, b) => a > b ? a : b),
        lessThanOrEqualTo(rightmostPrintable),
      );
      // The QR code arrived as a QR code.
      expect(_hasFinderPattern(decoded.rows, 1296), isTrue);
    },
  );

  testWidgets('an IPP printer shows the status it reports', (tester) async {
    final paths = <String>[];
    final server = await _fakeIpp(_ippReply(), paths);
    addTearDown(() => server.close(force: true));
    final spec = await rootBundle.loadString(specAssetPath(_ippSpec));

    await tester.pumpWidget(
      _app(
        IppPrinterScreen(
          device: NetworkDevice(
            host: '127.0.0.1',
            name: 'Office Laser',
            port: server.port,
            sources: const {NetworkDiscoverySource.mdns},
            discoveredAt: DateTime(2026, 1, 1),
            serviceTypes: const ['_ipp._tcp'],
            txt: const {'rp': 'ipp/print'},
          ),
          controls: NetworkControls(
            specYaml: spec,
            entities: const [],
            ippStatus: true,
          ),
        ),
      ),
    );
    await _settle(tester);
    await _screenshot(tester, 'ipp-status');

    expect(paths, ['/ipp/print']);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Load paper in tray 1'), findsOneWidget);
    expect(find.text('Media empty'), findsOneWidget);
    expect(find.text('Black Toner'), findsOneWidget);
    expect(find.text('12%'), findsOneWidget);
    expect(find.text('A4 (210x297 mm)'), findsOneWidget);
  });

  testWidgets(
    'a label reaches an emulated NIIMBOT D110 through its whole task',
    (tester) async {
      final spec = await rootBundle.loadString(specAssetPath(_niimbotSpec));
      final codec = RealSpecCodec();
      final raster = await codec.rasterPrintForSpec(specYaml: spec);
      expect(raster?.transport, 'ble_write_plan');
      final printer = _EmulatedD110();

      await tester.pumpWidget(
        _app(
          PrintLabelScreen(
            target: BleRasterTarget(
              codec: codec,
              ble: printer,
              deviceId: 'D110-EMULATED',
              specYaml: spec,
              name: 'NIIMBOT D110',
              raster: raster!,
            ),
          ),
        ),
      );
      await _settle(tester);
      // A 12 mm head: the composer starts with text along the tape, and says
      // this protocol has not been run on hardware.
      expect(find.textContaining("hasn't been tried"), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('label-line-0')),
        'Spices',
      );
      await _settle(tester);
      await _screenshot(tester, 'niimbot-composer');
      await tester.scrollUntilVisible(
        find.text('Print'),
        200,
        scrollable: find
            .ancestor(
              of: find.byKey(const ValueKey('label-qr')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Print'));
      for (
        var i = 0;
        i < 60 && find.text('Label sent.').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(find.text('Label sent.'), findsOneWidget);

      // The task, in the spec's order, with print_end only after the status
      // poll reported the page done.
      final control = printer.commands
          .where((c) => c != 0x83 && c != 0x84 && c != 0x85)
          .toList();
      expect(control.take(9), [
        0xC1, 0x21, 0x23, 0x01, 0x20, 0x03, 0x13, 0x15, 0xE3, //
      ]);
      final polls = control.skip(9).takeWhile((c) => c == 0xA3).length;
      expect(polls, greaterThanOrEqualTo(2), reason: 'polled until done');
      expect(control.skip(9 + polls), [0xF3]);
      // Every row of the declared page arrived, on the 96-dot head, inked.
      expect(printer.pageCols, 96);
      expect(printer.rows.length, printer.pageRows);
      expect(printer.rows.values.expand((r) => r).length, greaterThan(50));
      expect(printer.rows.values.expand((r) => r).every((d) => d < 96), isTrue);
    },
  );
}
