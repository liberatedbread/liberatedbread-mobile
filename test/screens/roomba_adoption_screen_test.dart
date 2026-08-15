// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The adoption wizard as a view of the two credential routes. The routes'
// own rules — the retry loop, the offset-free extraction, what the account
// route does and does not persist — live in
// roomba_control_service_test.dart and irobot_cloud_service_test.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart'
    show urlOpenerProvider;
import 'package:liberated_bread_mobile/providers/roomba_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/roomba_adoption_screen.dart';
import 'package:liberated_bread_mobile/services/irobot_cloud_service.dart';
import 'package:liberated_bread_mobile/services/roomba_control_service.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _blid = '3193C60472324700';
const _password = ':1:1486937829:gktkDoYpWaDxCfGh';

/// A robot that answers the disclosure probe with [password].
///
/// It replies when the probe is WRITTEN, which is what a real robot does —
/// and, unlike replying from the constructor, it cannot race the listener the
/// service attaches a moment later.
class _DisclosingRobot implements RoombaTlsSocket {
  final _out = StreamController<Uint8List>();
  final String password;

  _DisclosingRobot(this.password);

  @override
  Stream<Uint8List> get incoming => _out.stream;

  @override
  void add(List<int> bytes) {
    final encoded = utf8.encode(password);
    const gap = 11; // the password starts at offset 13 of the whole reply
    _out.add(Uint8List.fromList([
      0xf0,
      encoded.length + gap,
      for (var i = 1; i <= gap; i++) i % 0x20,
      ...encoded,
    ]));
  }

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}

MockClient _irobotAccount() => MockClient(_irobotAccountResponse);

/// The happy-path answers for the three round trips the account route makes,
/// so a test that only cares about ONE of them can reuse the other two.
Future<http.Response> _irobotAccountResponse(http.Request request) async {
      final path = request.url.path;
      if (path.endsWith('/v1/discover/endpoints')) {
        return http.Response(
          jsonEncode({
            'gigya': {
              'api_key': 'K',
              'datacenter_domain': 'accounts.us1.gigya.com',
            },
            'httpBase': 'https://unauth2.prod.iot.irobotapi.com',
          }),
          200,
        );
      }
      if (path.endsWith('/accounts.login')) {
        return http.Response(
          jsonEncode({
            'errorCode': 0,
            'UID': 'u',
            'UIDSignature': 's',
            'signatureTimestamp': 1,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'robots': {
            _blid: {'password': _password, 'name': 'Dorita', 'sku': 'R980020'},
          },
        }),
        200,
      );
}

void main() {
  late InMemorySettingsStore settings;
  final opened = <Uri>[];

  setUp(() {
    settings = InMemorySettingsStore();
    opened.clear();
  });

  /// The screen under a ProviderScope with every outward edge faked: no
  /// sockets, no HTTP, no keychain, no url_launcher channel.
  Widget wrap({
    RoombaTlsConnect? connect,
    http.Client? cloudClient,
    int passwordAttempts = 1,
  }) {
    final codec = FakeSpecCodec();
    return ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        specCodecProvider.overrideWithValue(codec),
        urlOpenerProvider.overrideWithValue((url) async {
          opened.add(url);
          return true;
        }),
        if (connect != null)
          roombaPasswordServiceProvider.overrideWithValue(
            RoombaPasswordService(codec: codec, connect: connect),
          ),
        if (cloudClient != null)
          iRobotCloudServiceProvider.overrideWithValue(
            IRobotCloudService(client: cloudClient),
          ),
      ],
      child: MaterialApp(
        home: RoombaAdoptionScreen(
          blid: _blid,
          host: '192.168.1.103',
          robotName: 'Dorita',
          sku: 'R980020',
          // One attempt by default: the retry loop's own behaviour belongs to
          // roomba_control_service_test, and waiting out four retry intervals
          // here would buy nothing.
          passwordAttempts: passwordAttempts,
        ),
      ),
    );
  }

  /// Let a running route finish, then rebuild.
  ///
  /// Two things make this fiddlier than `pumpAndSettle`. The wizard shows a
  /// [LinearProgressIndicator] while a route runs, and that schedules frames
  /// forever — so settling never happens however fast the work completes. And
  /// the routes are genuine async chains (a socket exchange, three HTTP
  /// round trips) whose continuations do not run on pumped fake time.
  ///
  /// `runAsync` gives them the real event loop for a moment; the pump
  /// afterwards is what draws the result.
  Future<void> pumpBusy(WidgetTester tester, {int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<RoombaCredentials?> stored() =>
      RoombaCredentialStore(settings).credentials(_blid);

  testWidgets('offers all three routes, button first', (tester) async {
    await tester.pumpWidget(wrap());

    expect(find.text('Hold the HOME button'), findsOneWidget);
    expect(find.text('Sign in to iRobot once'), findsOneWidget);
    expect(find.text('I already have the BLID and password'), findsOneWidget);
    // The account route's ordering trap, stated where the choice is made.
    expect(find.textContaining('before that'), findsOneWidget);
  });

  testWidgets('the button route saves the password and reveals it',
      (tester) async {
    await tester.pumpWidget(
      wrap(connect: (_, __, ___) async => _DisclosingRobot(_password)),
    );

    await tester.tap(find.text('Hold the HOME button'));
    await tester.pumpAndSettle();
    // The steps are ordered because the order is what makes it work.
    expect(find.text('Do this in order'), findsOneWidget);

    await tester.tap(find.text('I held HOME — ask the robot'));
    await pumpBusy(tester);

    expect(find.text('Screenshot this'), findsOneWidget);
    // The whole credential, on screen, selectable. This is the point of the
    // screen: capture it once and never do this again on any device.
    expect(find.text(_password), findsOneWidget);
    expect(find.text(_blid), findsOneWidget);
    expect(find.text('192.168.1.103'), findsOneWidget);

    final saved = await stored();
    expect(saved!.password, _password,
        reason: 'stored verbatim, leading colon and all');
    expect(saved.name, 'Dorita');
    expect(saved.lastIp, '192.168.1.103');
  });

  testWidgets('the account route saves the same credentials', (tester) async {
    await tester.pumpWidget(wrap(cloudClient: _irobotAccount()));

    await tester.tap(find.text('Sign in to iRobot once'));
    await tester.pumpAndSettle();

    // The promise made at the point the password is typed.
    expect(find.text('Not stored. Sent to iRobot once.'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'iRobot account email'),
        'someone@example.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'iRobot account password'),
        'account-secret');
    await tester.tap(find.text('Sign in and read my robots'));
    await pumpBusy(tester);

    expect(find.text('Screenshot this'), findsOneWidget);
    expect((await stored())!.password, _password);
    // The account password reached the network and nothing else.
    expect(
      settings.values.values.any((v) => v.contains('account-secret')),
      isFalse,
      reason: 'the iRobot account password must never be persisted',
    );
  });

  /// iRobot runs several regional APIs, and the wrong one signs in fine and
  /// then reports no robots. The country therefore has to reach the request,
  /// and has to be correctable — the phone's country and the account's are not
  /// always the same.
  testWidgets('the account route sends the region the user can edit',
      (tester) async {
    final countries = <String>[];
    await tester.pumpWidget(wrap(
      cloudClient: MockClient((request) async {
        if (request.url.path.endsWith('/v1/discover/endpoints')) {
          countries.add(request.url.queryParameters['country_code'] ?? '');
        }
        return _irobotAccountResponse(request);
      }),
    ));

    await tester.tap(find.text('Sign in to iRobot once'));
    await tester.pumpAndSettle();

    // Prefilled from the device locale, which the test binding reports as US —
    // so the field is populated rather than demanding input for the common
    // case.
    final region = find.widgetWithText(TextField, 'Account region');
    expect(tester.widget<TextField>(region).controller!.text, 'US');

    await tester.enterText(region, 'de');
    await tester.enterText(
        find.widgetWithText(TextField, 'iRobot account email'),
        'someone@example.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'iRobot account password'),
        'account-secret');
    await tester.tap(find.text('Sign in and read my robots'));
    await pumpBusy(tester);

    // Upper-cased on the way out: the API wants DE, the user typed de.
    expect(countries, ['DE']);
  });

  /// The account can hold robots that are not the one this screen was opened
  /// for. Adopting the first of them would store a DIFFERENT robot's password
  /// under that robot's BLID: the screen reports success, the robot the user
  /// picked still has nothing saved, and the failure turns up later somewhere
  /// else entirely.
  testWidgets('a robot missing from the account fails instead of adopting '
      'another one', (tester) async {
    await tester.pumpWidget(wrap(
      cloudClient: MockClient((request) async {
        if (request.url.path.endsWith('/v1/discover/endpoints') ||
            request.url.path.endsWith('/accounts.login')) {
          return _irobotAccountResponse(request);
        }
        // A real account, real robots — none of them this one.
        return http.Response(
          jsonEncode({
            'robots': {
              'AAAA1111BBBB2222': {
                'password': ':1:9999999999:someoneElsesRobot',
                'name': 'Downstairs',
                'sku': 'R980020',
              },
            },
          }),
          200,
        );
      }),
    ));

    await tester.tap(find.text('Sign in to iRobot once'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'iRobot account email'),
        'someone@example.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'iRobot account password'),
        'account-secret');
    await tester.tap(find.text('Sign in and read my robots'));
    await pumpBusy(tester);

    // Nothing adopted, and nothing stored under EITHER blid.
    expect(find.text('Screenshot this'), findsNothing);
    expect(await stored(), isNull);
    expect(
      settings.values.values.any((v) => v.contains('someoneElsesRobot')),
      isFalse,
      reason: 'another robot\'s password was saved',
    );
    // The message has to name the robot and say what to do instead, or the
    // user is left with "it did not work".
    expect(find.textContaining(_blid), findsOneWidget);
    expect(find.textContaining('Downstairs'), findsOneWidget);
  });

  testWidgets('the paste route keeps the whole password', (tester) async {
    await tester.pumpWidget(wrap());

    await tester.tap(find.text('I already have the BLID and password'));
    await tester.pumpAndSettle();
    // The mistake this field invites, named before it happens.
    expect(
      find.text('Paste the whole thing, including the leading colon.'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField).last, _password);
    await tester.tap(find.text('Save'));
    await pumpBusy(tester);

    expect((await stored())!.password, _password);
  });

  testWidgets('an empty paste is refused rather than saved', (tester) async {
    await tester.pumpWidget(wrap());

    await tester.tap(find.text('I already have the BLID and password'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
        find.textContaining('Both the BLID and the password'), findsOneWidget);
    expect(await stored(), isNull);
  });

  /// The cipher gap is not a retry situation. The panel has to say what does
  /// work instead of implying "try again" — otherwise someone spends an
  /// evening re-holding a button that was never the problem.
  testWidgets('a legacy-TLS failure offers the two things that do work',
      (tester) async {
    await tester.pumpWidget(wrap(
      connect: (_, __, ___) async => throw const RoombaConnectionException(
        'The TLS handshake failed.',
        legacyTlsSuspected: true,
      ),
    ));

    await tester.tap(find.text('Hold the HOME button'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I held HOME — ask the robot'));
    await pumpBusy(tester);

    expect(find.textContaining('TLS handshake failed'), findsOneWidget);
    expect(find.textContaining('Node can use the old cipher'), findsOneWidget);
    expect(find.text('dorita980'), findsOneWidget);
    expect(find.text('rest980'), findsOneWidget);
    expect(await stored(), isNull);

    await tester.ensureVisible(find.text('rest980'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('rest980'));
    await tester.pump();
    expect(opened.single.toString(), contains('koalazak/rest980'));
  });

  testWidgets('a failed handshake explains itself and saves nothing',
      (tester) async {
    await tester.pumpWidget(wrap(
      connect: (_, __, ___) async =>
          throw const RoombaPasswordException('not in disclosure mode'),
    ));

    await tester.tap(find.text('Hold the HOME button'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I held HOME — ask the robot'));
    await pumpBusy(tester);

    // The service's own words, not our fallback: RoombaPasswordException is a
    // UserFacingException precisely so the specific reason survives to the
    // screen. "did not hand over a password" would be true but useless.
    expect(find.textContaining('not in disclosure mode'), findsOneWidget);
    expect(await stored(), isNull);
    // No dead-end advice for a retryable failure — the steps are still there.
    expect(find.text('I held HOME — ask the robot'), findsOneWidget);
  });

  testWidgets('credits dorita980 on every step, tappably', (tester) async {
    await tester.pumpWidget(wrap());

    Finder credit() => find.textContaining('koalazak/dorita980\'s work (MIT)');
    expect(credit(), findsOneWidget);

    await tester.tap(find.text('Hold the HOME button'));
    await tester.pumpAndSettle();
    expect(credit(), findsOneWidget, reason: 'not just on the first step');

    await tester.ensureVisible(find.text('github.com/koalazak/dorita980'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('github.com/koalazak/dorita980'));
    await tester.pump();
    expect(opened.single.toString(), 'https://github.com/koalazak/dorita980');
  });
}
