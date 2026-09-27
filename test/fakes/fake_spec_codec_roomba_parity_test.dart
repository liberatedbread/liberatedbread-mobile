// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// FakeSpecCodec.roombaParsePasswordReply is a hand copy of
// protocol::roomba::parse_password_reply, and the Roomba service tests trust
// it. It had drifted: it never stripped the echoed probe magic
// (`ef cc 3b 29`, two of them printable), so the reply real robots send came
// back as ";)\x00<password>" where Rust returns the password — the exact bug
// Rust had already fixed once (junk prefix, then CONNACK 4). Its comment
// promised that a divergence would fail a round-trip; nothing compared the
// two. This does, for every reply shape the service tests use.
import 'dart:convert' show utf8;

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';

import '../helpers/host_rust_lib.dart';
import 'fake_spec_codec.dart';

const _password = ':1:1486937829:gktkDoYpWaDxCfGh';

List<int> _reply(List<int> body) => [0xf0, body.length, ...body];

final Map<String, List<int>> _replies = {
  'the real shape: echoed magic, status, password': _reply([
    0xef,
    0xcc,
    0x3b,
    0x29,
    0x00,
    ...utf8.encode(_password),
  ]),
  'padded with non-printable filler (dorita980 offset 13)': _reply([
    for (var i = 1; i <= 11; i++) i % 0x20,
    ...utf8.encode(_password),
  ]),
  'padded with NULs, trailing NULs trimmed': _reply([
    0x00,
    0x00,
    0x00,
    ...utf8.encode(_password),
    0x00,
    0x00,
  ]),
  'the magic and status with no password': _reply([
    0xef,
    0xcc,
    0x3b,
    0x29,
    0x00,
    0x00,
    0x00,
  ]),
  'unsupported firmware': const [0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x03],
  'too short to be a disclosure': const [0xf0, 0x01, 0x41],
};

/// The parsed password, or 'error' — the two codecs throw different types,
/// and what must agree is whether a password came out and which.
Future<String> _outcome(Future<String> Function() parse) async {
  try {
    return await parse();
  } catch (_) {
    return 'error';
  }
}

void main() {
  final fake = FakeSpecCodec();

  test('the fake parses the real reply shape to the bare password', () async {
    // Runs without the Rust lib, so a fresh clone still pins the fix.
    final reply = _replies['the real shape: echoed magic, status, password']!;
    expect(await fake.roombaParsePasswordReply(reply: reply), _password);
  });

  group('FakeSpecCodec agrees with protocol::roomba', () {
    late bool rustReady;
    final real = RealSpecCodec();

    setUpAll(() async {
      rustReady = await initHostRustLib();
    });

    _replies.forEach((label, reply) {
      test(label, () async {
        if (!rustReady) {
          markTestSkipped('Rust lib not loaded');
          return;
        }
        final want = await _outcome(
          () => real.roombaParsePasswordReply(reply: reply),
        );
        final got = await _outcome(
          () => fake.roombaParsePasswordReply(reply: reply),
        );
        expect(got, want, reason: 'reply ${reply.toList()}');
      });
    });
  });
}
