// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The trust decision a spec's `identification.tls` block asks for.
//
// Worth its own file because the thing under test is a security policy that
// three transports share, and because the failure it exists to prevent is
// silent: a client that accepts every certificate looks exactly like one that
// checks them, right up until somebody is between you and the device.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/tls_trust.dart';

import '../fakes/in_memory_settings_store.dart';

/// A certificate is only ever asked for its DER here, so the rest of
/// [X509Certificate] can stay unimplemented — and should, so a policy that
/// starts reading the subject or the validity dates fails this file loudly
/// rather than quietly depending on a fake's guess.
class _FakeCert implements X509Certificate {
  @override
  final Uint8List der;

  _FakeCert(String seed) : der = Uint8List.fromList(seed.codeUnits);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late InMemorySettingsStore store;
  late TlsTrust trust;

  setUp(() {
    store = InMemorySettingsStore();
    trust = TlsTrust(CertificatePinStore(store));
  });

  bool Function(X509Certificate, String, int) evaluatorFor(
    TlsPolicy? policy, {
    bool fallback = false,
  }) =>
      trust.evaluator(
        identity: 'envoy@192.0.2.4',
        policy: policy,
        fallback: (_, __, ___) => fallback,
      );

  test('the vocabulary maps to what this app can actually do', () {
    expect(TlsPolicy.parse('standard'), TlsPolicy.standard);
    expect(TlsPolicy.parse('trust_on_first_use'), TlsPolicy.trustOnFirstUse);
    expect(TlsPolicy.parse('vendor_ca'), TlsPolicy.vendorCa);
    expect(TlsPolicy.parse('none'), TlsPolicy.none);
    // A spec stating nothing is not the same as a spec stating "none": the
    // caller decides the first, and most of the catalogue is in that state.
    expect(TlsPolicy.parse(null), isNull);
    // A policy written after this build lands on the more cautious of the two
    // behaviours available, never on the one that checks nothing.
    expect(TlsPolicy.parse('some_future_scheme'), TlsPolicy.trustOnFirstUse);
  });

  test('trust_on_first_use pins the first certificate and keeps it', () async {
    final evaluate = evaluatorFor(TlsPolicy.trustOnFirstUse);
    expect(evaluate(_FakeCert('envoy-leaf'), '192.0.2.4', 443), isTrue);
    // The same device, same certificate, later in the session.
    expect(evaluate(_FakeCert('envoy-leaf'), '192.0.2.4', 443), isTrue);
  });

  test('a changed certificate is refused, and the pin is not replaced',
      () async {
    final first = evaluatorFor(TlsPolicy.trustOnFirstUse);
    expect(first(_FakeCert('envoy-leaf'), '192.0.2.4', 443), isTrue);

    expect(
      first(_FakeCert('someone-elses-leaf'), '192.0.2.4', 443),
      isFalse,
      reason: 'this is the whole point of pinning',
    );
    // And the refusal does not quietly re-pin: the original certificate is
    // still the one this device is known by, so the real device coming back
    // still works and the impostor still does not.
    expect(first(_FakeCert('envoy-leaf'), '192.0.2.4', 443), isTrue);
  });

  test('a pin survives into a new session', () async {
    final before = evaluatorFor(TlsPolicy.trustOnFirstUse);
    expect(before(_FakeCert('envoy-leaf'), '192.0.2.4', 443), isTrue);
    // The write is fired off rather than awaited, so let it land.
    await Future<void>.delayed(Duration.zero);

    // A fresh app run, same store.
    final next = TlsTrust(CertificatePinStore(store));
    await next.prepare('envoy@192.0.2.4');
    final after = next.evaluator(
      identity: 'envoy@192.0.2.4',
      policy: TlsPolicy.trustOnFirstUse,
      fallback: (_, __, ___) => false,
    );
    expect(
      after(_FakeCert('someone-elses-leaf'), '192.0.2.4', 443),
      isFalse,
      reason: 'a pin that does not outlive the process is not a pin',
    );
    expect(after(_FakeCert('envoy-leaf'), '192.0.2.4', 443), isTrue);
  });

  test('vendor_ca pins too, because no CA bundle ships here', () {
    // Named separately from trust_on_first_use so the day a bundle exists
    // there is a test to change rather than a behaviour to discover.
    final evaluate = evaluatorFor(TlsPolicy.vendorCa);
    expect(evaluate(_FakeCert('vendor-leaf'), '192.0.2.4', 443), isTrue);
    expect(evaluate(_FakeCert('another-leaf'), '192.0.2.4', 443), isFalse);
  });

  test('standard refuses what the platform refused', () {
    // The callback only fires because validation already failed; `standard`
    // says the platform was right, so there is nothing to excuse.
    expect(
      evaluatorFor(TlsPolicy.standard)(_FakeCert('any'), '192.0.2.4', 443),
      isFalse,
    );
  });

  test('none tolerates anything, which is what it says', () {
    final evaluate = evaluatorFor(TlsPolicy.none);
    expect(evaluate(_FakeCert('one'), '192.0.2.4', 443), isTrue);
    expect(evaluate(_FakeCert('two'), '192.0.2.4', 443), isTrue);
  });

  test('a spec stating no policy defers to the caller', () {
    // Most of the catalogue. Changing what these devices do was never part of
    // reading the block, so the caller's own rule decides — and the decision
    // is visible here rather than buried in a client.
    expect(
      evaluatorFor(null, fallback: true)(_FakeCert('x'), '192.0.2.4', 443),
      isTrue,
    );
    expect(
      evaluatorFor(null, fallback: false)(_FakeCert('x'), '192.0.2.4', 443),
      isFalse,
    );
  });

  test('one shared client keeps two devices\' policies apart', () async {
    // The client is a `Provider`: one instance drives every device in the app,
    // and a group run drives several at once. Registering "the current device"
    // on it would let the second registration land while the first device's
    // handshake was in flight — pinning one certificate under the other's
    // name, and refusing the real device ever after. The callback is told
    // which host it is deciding about, so the host selects the policy.
    final client = HttpControlClient(trust: trust);
    await client.useTlsPolicy(
      host: '192.0.2.4',
      identity: 'envoy@192.0.2.4',
      policy: TlsPolicy.trustOnFirstUse,
    );
    await client.useTlsPolicy(
      host: '192.0.2.7',
      identity: 'smartcast@192.0.2.7',
      policy: TlsPolicy.trustOnFirstUse,
    );

    // Pin each device under its own name, interleaved as a group run would.
    expect(
        client.debugEvaluateCertificate(_FakeCert('envoy'), '192.0.2.4', 443),
        isTrue);
    expect(
        client.debugEvaluateCertificate(
            _FakeCert('smartcast'), '192.0.2.7', 7345),
        isTrue);

    // Each still recognises its own, and neither has been re-pinned to the
    // other's certificate.
    expect(
        client.debugEvaluateCertificate(_FakeCert('envoy'), '192.0.2.4', 443),
        isTrue);
    expect(
        client.debugEvaluateCertificate(
            _FakeCert('smartcast'), '192.0.2.4', 443),
        isFalse,
        reason: 'the other device\'s certificate is still an impostor here');
  });

  test('two devices do not share a pin', () async {
    final envoy = evaluatorFor(TlsPolicy.trustOnFirstUse);
    expect(envoy(_FakeCert('envoy-leaf'), '192.0.2.4', 443), isTrue);

    final vizio = trust.evaluator(
      identity: 'smartcast@192.0.2.7',
      policy: TlsPolicy.trustOnFirstUse,
      fallback: (_, __, ___) => false,
    );
    expect(
      vizio(_FakeCert('smartcast-leaf'), '192.0.2.7', 7345),
      isTrue,
      reason: 'a second device is on its own first contact, not a pin change',
    );
  });
}
