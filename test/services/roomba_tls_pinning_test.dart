// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The trust decision on the Roomba's TLS connection, against a real loopback
// TLS server — because the robot's certificate is self-signed with no chain,
// `onBadCertificate` fires on EVERY connection and IS the whole verification,
// and the in-memory socket fakes the other Roomba suites use never reach it.
// Certificates come from test/fixtures/roomba_tls/ (see its README): `robot`
// is the robot itself, `impostor` a different key at the same address.
//
// The spec's TLS note, executed: the leaf is pinned on first sight keyed by
// BLID; the same certificate reconnects; a different one fails closed BEFORE
// the password crosses, is never silently re-pinned, and names the recovery;
// forgetting the robot clears the pin so a factory-reset robot can be adopted
// again. Plain unit suite — loopback, ephemeral ports, no network.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/mqtt_session.dart';
import 'package:liberated_bread_mobile/services/roomba_control_service.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';
import 'package:liberated_bread_mobile/services/tls_trust.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _blid = 'ABC123';
const _host = '127.0.0.1';
const _fixtures = 'test/fixtures/roomba_tls';
const _password = ':1:1700000000:AbCdEfGhIjKlMnOp';

/// CONNACK, accepted.
const _connack = [0x20, 0x02, 0x00, 0x00];

/// A disclosure reply in the wire shape the codec parses: `[0xf0][length]`,
/// a few non-printable bytes, then the password.
List<int> _disclosure(String password) {
  final body = [0x00, 0x00, 0x00, ...utf8.encode(password)];
  return [0xf0, body.length, ...body];
}

/// The sha256 the client should pin: over the certificate's DER bytes,
/// recomputed here from the PEM fixture so the expectation is independent of
/// the code under test.
String _expectedPin(String certName) {
  final pem = File('$_fixtures/$certName.crt').readAsStringSync();
  final base64Body = pem
      .split('\n')
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return sha256.convert(base64Decode(base64Body)).toString();
}

/// A loopback robot presenting the named fixture certificate.
///
/// Answers the first bytes of every connection with [reply] — once, so a
/// CONNACK is not repeated at the SUBSCRIBE that follows it — and records
/// what arrived. What arrived is the assertion that matters: a refused
/// handshake must leave [received] empty, because the probe or the CONNECT
/// carrying the password is the very thing the pin exists to withhold.
class _FakeRobot {
  final SecureServerSocket _server;
  final List<int> reply;
  final List<List<int>> received = [];

  _FakeRobot._(this._server, this.reply);

  static Future<_FakeRobot> serve(
    String certName, {
    required List<int> reply,
  }) async {
    final context = SecurityContext()
      ..useCertificateChain('$_fixtures/$certName.crt')
      ..usePrivateKey('$_fixtures/$certName.key');
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final robot = _FakeRobot._(server, reply);
    server.listen(
      (socket) {
        var answered = false;
        socket.listen(
          (bytes) {
            robot.received.add(List.of(bytes));
            if (answered) return;
            answered = true;
            socket.add(reply);
          },
          onError: (Object _) {},
          onDone: socket.destroy,
        );
      },
      // A client that refuses our certificate fails the handshake on this
      // side too; that is the expected shape of half these tests.
      onError: (Object _) {},
    );
    return robot;
  }

  int get port => _server.port;

  Future<void> close() => _server.close();
}

/// A settings store whose reads throw — the keychain still locked after a
/// cold start, as CertificatePinStore sees it. prepare() records the identity
/// as unreadable and the evaluator refuses rather than trust on first contact.
class _LockedSettingsStore extends InMemorySettingsStore {
  @override
  Future<String?> read(String key) async =>
      throw StateError('keychain locked: $key');
}

void main() {
  late InMemorySettingsStore settings;
  late FakeSpecCodec codec;

  setUp(() {
    settings = InMemorySettingsStore();
    codec = FakeSpecCodec();
  });

  /// A trust that reads whatever [settings] holds — a FRESH one each time, so
  /// a pin has to survive the round trip through the store (and `prepare`)
  /// rather than ride the in-memory cache of the instance that wrote it.
  TlsTrust trust() => TlsTrust(CertificatePinStore(settings));

  final identity = roombaTlsIdentity(_blid);
  final pinKey = 'tls.pin.$identity';

  Future<_FakeRobot> robot(String cert, {List<int> reply = _connack}) async {
    final served = await _FakeRobot.serve(cert, reply: reply);
    addTearDown(served.close);
    return served;
  }

  /// The pin write is fired off, not awaited, by the handshake callback.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('pinnedTlsConnect', () {
    test('first sight pins the leaf under the identity', () async {
      final server = await robot('robot');
      final connect = pinnedTlsConnect(trust(), identity: identity);

      final socket = await connect(
        _host,
        server.port,
        const Duration(seconds: 5),
      );
      await socket.close();
      await settle();

      expect(settings.values[pinKey], _expectedPin('robot'));
    });

    test(
      'the same certificate reconnects on a trust that only has the store',
      () async {
        final server = await robot('robot');
        settings.values[pinKey] = _expectedPin('robot');
        final connect = pinnedTlsConnect(trust(), identity: identity);

        final socket = await connect(
          _host,
          server.port,
          const Duration(seconds: 5),
        );
        await socket.close();

        expect(settings.values[pinKey], _expectedPin('robot'));
      },
    );

    test(
      'a pin the store cannot read is refused as UNREADABLE, not as changed',
      () async {
        // The keychain still locked after a cold start: prepare() records the
        // identity as unreadable, the evaluator refuses rather than trust on
        // first contact over a pin it cannot see, and the handshake then
        // fails exactly the way a changed certificate does. The connector
        // used to branch on the bool and send the user to remove the device
        // and add it again — which, followed, erases a correct pin.
        final server = await robot('robot');
        final trust = TlsTrust(CertificatePinStore(_LockedSettingsStore()));
        final connect = pinnedTlsConnect(trust, identity: identity);

        await expectLater(
          connect(_host, server.port, const Duration(seconds: 5)),
          throwsA(
            isA<MqttConnectionException>()
                .having(
                  (e) => e.certificateChanged,
                  'certificateChanged',
                  isFalse,
                )
                .having((e) => e.handshakeFailed, 'handshakeFailed', isTrue)
                .having((e) => e.message, 'message', mqttPinUnreadableMessage),
          ),
        );
        expect(server.received, isEmpty, reason: 'nothing crossed the socket');
      },
    );

    test('a handshake that fails before the certificate does not report the '
        "previous attempt's refusal", () async {
      // Attempt one, keychain locked: the pin cannot be read and the
      // refusal is recorded as pinUnreadable. The user unlocks and retries
      // — against a broker that rejects at ServerHello, before any
      // certificate arrives, so the callback never runs. refusalReason was
      // read on ANY HandshakeException, and the record from attempt one was
      // still there: "unlock the phone and try again", for a failure that
      // unlocking cannot fix.
      final trust = TlsTrust(CertificatePinStore(_LockedSettingsStore()));
      final locked = await robot('robot');
      final connect = pinnedTlsConnect(trust, identity: identity);
      await expectLater(
        connect(_host, locked.port, const Duration(seconds: 5)),
        throwsA(
          isA<MqttConnectionException>().having(
            (e) => e.message,
            'message',
            mqttPinUnreadableMessage,
          ),
        ),
      );

      // A "broker" that refuses at ServerHello: it answers the ClientHello
      // with a fatal handshake_failure alert — what a cipher-suite mismatch
      // looks like on the wire — so the client throws HandshakeException with
      // no certificate ever having reached the callback. (Dropping the socket
      // instead is a read failure, which takes a different branch and never
      // consults the reason at all.)
      final notTls = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(notTls.close);
      notTls.listen((socket) {
        socket.listen((_) {
          // TLS 1.2 alert record: level fatal (2), handshake_failure (40).
          socket.add(const [0x15, 0x03, 0x03, 0x00, 0x02, 0x02, 0x28]);
          socket.flush().then((_) => socket.destroy());
        }, onError: (Object _) {});
      });

      await expectLater(
        connect(_host, notTls.port, const Duration(seconds: 5)),
        throwsA(
          isA<MqttConnectionException>()
              .having((e) => e.handshakeFailed, 'handshakeFailed', isTrue)
              .having(
                (e) => e.message,
                'message',
                isNot(mqttPinUnreadableMessage),
              ),
        ),
      );
    });

    test(
      'a changed certificate fails closed, says so, and keeps the pin',
      () async {
        final server = await robot('impostor');
        settings.values[pinKey] = _expectedPin('robot');
        final connect = pinnedTlsConnect(trust(), identity: identity);

        await expectLater(
          connect(_host, server.port, const Duration(seconds: 5)),
          throwsA(
            isA<MqttConnectionException>()
                .having(
                  (e) => e.certificateChanged,
                  'certificateChanged',
                  isTrue,
                )
                .having((e) => e.handshakeFailed, 'handshakeFailed', isTrue)
                .having(
                  (e) => e.message,
                  'message',
                  mqttCertificateChangedMessage,
                ),
          ),
        );

        expect(
          settings.values[pinKey],
          _expectedPin('robot'),
          reason: 'a mismatch is never silently re-pinned',
        );
        expect(server.received, isEmpty, reason: 'nothing crossed the socket');
      },
    );

    test(
      'forgetting the identity clears the pin and the next sight re-pins',
      () async {
        final server = await robot('impostor');
        settings.values[pinKey] = _expectedPin('robot');
        final shared = trust();
        final connect = pinnedTlsConnect(shared, identity: identity);
        await expectLater(
          connect(_host, server.port, const Duration(seconds: 5)),
          throwsA(isA<MqttConnectionException>()),
        );

        await shared.forget(identity, host: _host);
        expect(settings.values.containsKey(pinKey), isFalse);

        final socket = await connect(
          _host,
          server.port,
          const Duration(seconds: 5),
        );
        await socket.close();
        await settle();
        expect(settings.values[pinKey], _expectedPin('impostor'));
      },
    );
  });

  group('RoombaPasswordService', () {
    test(
      'pins under roomba:<BLID> on first sight and returns the password',
      () async {
        final server = await robot('robot', reply: _disclosure(_password));
        final service = RoombaPasswordService(codec: codec, trust: trust());

        final password = await service.fetchPassword(
          _host,
          blid: _blid.toLowerCase(),
          port: server.port,
          attempts: 1,
        );
        await settle();

        expect(password, _password);
        expect(
          settings.values[pinKey],
          _expectedPin('robot'),
          reason:
              'keyed by the uppercased BLID, the same spelling the '
              'credential store and the MQTT session use',
        );
      },
    );

    test(
      'a changed certificate is refused before the probe, and not retried',
      () async {
        final server = await robot('impostor', reply: _disclosure(_password));
        settings.values[pinKey] = _expectedPin('robot');
        final service = RoombaPasswordService(codec: codec, trust: trust());
        final attempts = <int>[];

        await expectLater(
          service.fetchPassword(
            _host,
            blid: _blid,
            port: server.port,
            attempts: 4,
            onAttempt: attempts.add,
          ),
          throwsA(
            isA<RoombaConnectionException>()
                .having(
                  (e) => e.certificateChanged,
                  'certificateChanged',
                  isTrue,
                )
                .having(
                  (e) => e.legacyTlsSuspected,
                  'legacyTlsSuspected',
                  isFalse,
                )
                .having((e) => e.message, 'message', contains('factory-reset')),
          ),
        );

        expect(attempts, [1], reason: 'the answer is the same every time');
        expect(server.received, isEmpty, reason: 'the probe never went out');
        expect(settings.values[pinKey], _expectedPin('robot'));
      },
    );

    test(
      'without a BLID the pin is keyed by host rather than not at all',
      () async {
        final server = await robot('robot', reply: _disclosure(_password));
        final service = RoombaPasswordService(codec: codec, trust: trust());

        await service.fetchPassword(_host, port: server.port, attempts: 1);
        await settle();

        expect(settings.values['tls.pin.host:$_host'], _expectedPin('robot'));
      },
    );

    test(
      'without a trust store it accepts any certificate, as before',
      () async {
        final server = await robot('robot', reply: _disclosure(_password));
        final service = RoombaPasswordService(codec: codec);

        expect(
          await service.fetchPassword(_host, port: server.port, attempts: 1),
          _password,
        );
        expect(settings.values, isEmpty);
      },
    );
  });

  group('RoombaMqttClient', () {
    const credentials = RoombaCredentials(blid: _blid, password: _password);

    RoombaMqttClient client() {
      final built = RoombaMqttClient(codec: codec, trust: trust());
      addTearDown(built.dispose);
      return built;
    }

    test('pins on first sight and the login goes through', () async {
      final server = await robot('robot');

      await client().connect(_host, credentials, port: server.port);
      await settle();

      expect(settings.values[pinKey], _expectedPin('robot'));
      expect(server.received, isNotEmpty);
    });

    test('a pin the store cannot read withholds the password without blaming '
        'the robot', () async {
      // Same refusal as the MQTT case above, in the connector that owns the
      // robot's wording: "factory-reset it, remove it and adopt it again"
      // for a locked keychain would throw away a correct pin AND the
      // stored password.
      final server = await robot('robot');
      final locked = RoombaMqttClient(
        codec: codec,
        trust: TlsTrust(CertificatePinStore(_LockedSettingsStore())),
      );
      addTearDown(locked.dispose);

      await expectLater(
        locked.connect(_host, credentials, port: server.port),
        throwsA(
          isA<RoombaConnectionException>()
              .having(
                (e) => e.certificateChanged,
                'certificateChanged',
                isFalse,
              )
              .having((e) => e.message, 'message', roombaPinUnreadableMessage),
        ),
      );
      expect(
        server.received,
        isEmpty,
        reason: 'the password must not have crossed the socket',
      );
    });

    test('the same certificate reconnects against the stored pin', () async {
      final server = await robot('robot');
      settings.values[pinKey] = _expectedPin('robot');

      final session = client();
      await session.connect(_host, credentials, port: server.port);

      expect(session.isConnected, isTrue);
    });

    test(
      'a changed certificate is refused before the CONNECT carries the password',
      () async {
        final server = await robot('impostor');
        settings.values[pinKey] = _expectedPin('robot');
        final session = client();

        await expectLater(
          session.connect(_host, credentials, port: server.port),
          throwsA(
            isA<RoombaConnectionException>()
                .having(
                  (e) => e.certificateChanged,
                  'certificateChanged',
                  isTrue,
                )
                .having(
                  (e) => e.legacyTlsSuspected,
                  'legacyTlsSuspected',
                  isFalse,
                ),
          ),
        );

        expect(session.isConnected, isFalse);
        expect(
          server.received,
          isEmpty,
          reason:
              'the CONNECT packet — BLID and password — must not have '
              'reached whatever is answering',
        );
        expect(settings.values[pinKey], _expectedPin('robot'));
      },
    );

    test(
      'forgetting the robot clears the pin; the new certificate is pinned next',
      () async {
        final server = await robot('impostor');
        settings.values[pinKey] = _expectedPin('robot');
        final shared = trust();
        final session = RoombaMqttClient(codec: codec, trust: shared);
        addTearDown(session.dispose);

        await expectLater(
          session.connect(_host, credentials, port: server.port),
          throwsA(isA<RoombaConnectionException>()),
        );

        // What forgetNetworkDevice does for a robot — the same identity
        // function, so the key the session checked is the key that clears.
        await shared.forget(roombaTlsIdentity(_blid), host: _host);

        await session.connect(_host, credentials, port: server.port);
        await settle();
        expect(session.isConnected, isTrue);
        expect(settings.values[pinKey], _expectedPin('impostor'));
      },
    );
  });
}
