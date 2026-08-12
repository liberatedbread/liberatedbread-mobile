// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The ECP2 signed session, driven from a scripted socket: the challenge
// handshake byte-for-byte, the ECP-path → ECP2-verb translation, and the
// failure shapes (refused, unanswered, unsupported) the screen's fallback
// depends on telling apart.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ecp2_socket.dart';

/// Connect and complete the challenge handshake; returns the authenticated
/// session and the socket so the test can keep playing the device.
Future<(Ecp2Session, FakeEcp2Socket)> authenticatedSession({
  String challenge = 'QUJDREVGR0hJSg==',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final socket = FakeEcp2Socket();
  final service = Ecp2ControlService(
      connector: (host, port) async => socket, timeout: timeout);
  final connecting = service.connect('10.0.0.9', 8060);
  await Future<void>.delayed(Duration.zero);
  socket.receive({
    'notify': 'authenticate',
    'param-challenge': challenge,
    'param-methods': ['client-id', 'jwt'],
  });
  await Future<void>.delayed(Duration.zero);
  expect(socket.sent, hasLength(1),
      reason: 'the client should answer the '
          'challenge before anything else');
  socket.receive({
    'response': 'authenticate',
    'response-id': '${socket.sent.single['request-id']}',
    'status': '200',
  });
  return (await connecting, socket);
}

void main() {
  group('the handshake', () {
    test('answers the challenge with the APK-derived secret', () async {
      // The expected value is pinned from the reference implementation
      // (work/roku-apk/ecp2_poc.py), not recomputed here — a regression in
      // the nibble shift or the concatenation changes it.
      expect(Ecp2Session.paramResponse('QUJDREVGR0hJSg=='),
          'Vn+SEVU9O68PuAIL9/1EqiDs7h4=');
      expect(Ecp2Session.paramResponse('AAAAAAAAAAAAAAAAAAAAAA=='),
          'a03nDziqklN3rsxNkiFGrQUeP64=');
    });

    test('sends the authenticate answer as the first frame', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);

      expect(socket.sent.single, {
        'request': 'authenticate',
        'request-id': '1',
        'param-response': 'Vn+SEVU9O68PuAIL9/1EqiDs7h4=',
      });
    });

    test('a refused client id fails the connect', () async {
      final socket = FakeEcp2Socket();
      final service =
          Ecp2ControlService(connector: (host, port) async => socket);
      final connecting = service.connect('10.0.0.9', 8060);
      await Future<void>.delayed(Duration.zero);
      socket.receive(
          {'notify': 'authenticate', 'param-challenge': 'QUJDREVGR0hJSg=='});
      await Future<void>.delayed(Duration.zero);
      socket.receive({
        'response': 'authenticate',
        'response-id': '${socket.sent.single['request-id']}',
        'status': '403',
      });

      await expectLater(connecting, throwsA(isA<Ecp2Exception>()));
      expect(socket.closed, isTrue,
          reason: 'a session that never authenticated must not leak');
    });

    test('no challenge at all fails the connect', () async {
      final socket = FakeEcp2Socket();
      final service = Ecp2ControlService(
          connector: (host, port) async => socket,
          timeout: const Duration(milliseconds: 50));
      await expectLater(
          service.connect('10.0.0.9', 8060), throwsA(isA<Ecp2Exception>()));
      expect(socket.closed, isTrue);
    });
  });

  group('translating ECP requests', () {
    test('query-apps returns the decoded XML plain ECP would have', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);
      const apps = '<apps><app id="12">Netflix</app></apps>';

      final answer = session.send(
          const HttpRequestDto(method: 'GET', path: '/query/apps', body: ''));
      await Future<void>.delayed(Duration.zero);
      expect(socket.sent.last, {'request': 'query-apps', 'request-id': '2'});
      socket.receive({
        'response': 'query-apps',
        'response-id': '2',
        'status': '200',
        'content-type': 'application/xml',
        'content-data': base64.encode(utf8.encode(apps)),
      });

      expect(await answer, apps);
    });

    test('a keypress rides key-press with the decoded key name', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);

      final answer = session.send(const HttpRequestDto(
          method: 'POST', path: '/keypress/Lit_%20', body: ''));
      await Future<void>.delayed(Duration.zero);
      // Lit_%20 is a typed space: the URI encoding is ECP's, ECP2 takes the
      // key name itself.
      expect(socket.sent.last,
          {'request': 'key-press', 'request-id': '2', 'param-key': 'Lit_ '});
      socket.receive(
          {'response': 'key-press', 'response-id': '2', 'status': '200'});

      expect(await answer, isEmpty);
    });

    test('keydown and keyup map to key-down and key-up', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);

      for (final (path, verb) in [
        ('/keydown/VolumeDown', 'key-down'),
        ('/keyup/VolumeDown', 'key-up'),
      ]) {
        final answer =
            session.send(HttpRequestDto(method: 'POST', path: path, body: ''));
        await Future<void>.delayed(Duration.zero);
        final frame = socket.sent.last;
        expect(frame['request'], verb);
        expect(frame['param-key'], 'VolumeDown');
        socket.receive({
          'response': verb,
          'response-id': frame['request-id'],
          'status': '200',
        });
        await answer;
      }
    });

    test('a launch carries the app id and its query args as JSON', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);

      final answer = session.send(const HttpRequestDto(
          method: 'POST',
          path: '/launch/12?contentID=abc&mediaType=movie',
          body: ''));
      await Future<void>.delayed(Duration.zero);
      expect(socket.sent.last, {
        'request': 'launch',
        'request-id': '2',
        'param-channel-id': '12',
        'param-params': jsonEncode({'contentID': 'abc', 'mediaType': 'movie'}),
      });
      socket
          .receive({'response': 'launch', 'response-id': '2', 'status': '200'});
      expect(await answer, isEmpty);
    });

    test('a 403 from the device is the same refusal plain ECP gives', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);

      final answer = session.send(const HttpRequestDto(
          method: 'POST', path: '/keypress/Home', body: ''));
      await Future<void>.delayed(Duration.zero);
      socket.receive(
          {'response': 'key-press', 'response-id': '2', 'status': '403'});

      await expectLater(answer, throwsA(isA<ControlRefusedException>()));
    });

    test('a path with no ECP2 equivalent is the plain refusal', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);

      await expectLater(
          session.send(const HttpRequestDto(
              method: 'POST', path: '/input', body: 'x=y')),
          throwsA(isA<ControlRefusedException>()));
      expect(socket.sent, hasLength(1),
          reason: 'nothing but the auth answer should have gone out');
    });

    test('an unanswered request fails instead of hanging', () async {
      final socket = FakeEcp2Socket();
      final service = Ecp2ControlService(
          connector: (host, port) async => socket,
          timeout: const Duration(milliseconds: 50));
      final connecting = service.connect('10.0.0.9', 8060);
      await Future<void>.delayed(Duration.zero);
      socket.receive(
          {'notify': 'authenticate', 'param-challenge': 'QUJDREVGR0hJSg=='});
      await Future<void>.delayed(Duration.zero);
      socket.receive({
        'response': 'authenticate',
        'response-id': '${socket.sent.single['request-id']}',
        'status': '200',
      });
      final session = await connecting;
      addTearDown(session.close);

      await expectLater(
          session.send(const HttpRequestDto(
              method: 'POST', path: '/keypress/Home', body: '')),
          throwsA(isA<Ecp2Exception>()));
    });

    test('overlapping requests match their own responses by id', () async {
      final (session, socket) = await authenticatedSession();
      addTearDown(session.close);

      final first = session.send(const HttpRequestDto(
          method: 'GET', path: '/query/active-app', body: ''));
      final second = session.send(const HttpRequestDto(
          method: 'POST', path: '/keypress/Home', body: ''));
      await Future<void>.delayed(Duration.zero);
      final firstId = '${socket.sent[socket.sent.length - 2]['request-id']}';
      final secondId = '${socket.sent.last['request-id']}';
      // Answer out of order: the second request's response arrives first.
      socket.receive(
          {'response': 'key-press', 'response-id': secondId, 'status': '200'});
      socket.receive({
        'response': 'query-active-app',
        'response-id': firstId,
        'status': '200',
        'content-data': base64.encode(
            utf8.encode('<active-app><app id="12">Netflix</app></active-app>')),
      });

      expect(await second, isEmpty);
      expect(await first, contains('Netflix'));
    });
  });
}
