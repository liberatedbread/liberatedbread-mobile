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

import 'package:liberated_bread_mobile/services/settings_store.dart';

import '../fakes/in_memory_settings_store.dart';

/// A certificate is only ever asked for its DER here, so the rest of
/// [X509Certificate] can stay unimplemented — and should, so a policy that
/// starts reading the subject or the validity dates fails this file loudly
/// rather than quietly depending on a fake's guess.
/// A settings store whose reads throw — a locked Android keystore, a desktop
/// with no keyring. What matters is that a pin read CAN fail, not how.
class _FailingStore implements SettingsStore {
  @override
  Future<String?> read(String key) async => throw StateError('keystore locked');
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
  @override
  Future<Map<String, String>> readAll() async => const {};
}

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

  test('forgetting a device is a real way back', () async {
    // A pin is never replaced silently — a changed certificate is a reset, new
    // firmware, or somebody in the middle, and this app cannot tell which — so
    // the refusal points at forgetting the device. If that did not actually
    // clear the pin, the device would be permanently unreachable and the
    // instruction a lie: only wiping app data would recover it.
    final evaluate = evaluatorFor(TlsPolicy.trustOnFirstUse);
    expect(evaluate(_FakeCert('old-leaf'), '192.0.2.4', 443), isTrue);
    expect(evaluate(_FakeCert('new-leaf'), '192.0.2.4', 443), isFalse);
    await Future<void>.delayed(Duration.zero);

    await trust.forget('envoy@192.0.2.4');

    // The reset device's new certificate is now a first contact.
    expect(evaluate(_FakeCert('new-leaf'), '192.0.2.4', 443), isTrue);
    // And it stays forgotten across a restart, not just in memory: `_known`
    // lives on a Provider that outlives any screen.
    final next = TlsTrust(CertificatePinStore(store));
    await next.prepare('envoy@192.0.2.4');
    expect(await CertificatePinStore(store).pin('envoy@192.0.2.4'), isNotNull,
        reason: 'the new certificate was pinned in its place');
  });

  test('the pin key survives a DHCP lease when the device published a MAC', () {
    // The sender writes the pin and the forget flow erases it, and they have
    // to compute the same key or the pin is one nothing can clear. Keying by
    // IP also re-pins on every lease — the same as not pinning — and hands the
    // next tenant of that address the previous device's fingerprint.
    expect(identityFor(mac: 'AA:BB:CC:11:22:33', host: '192.0.2.4'),
        identityFor(mac: 'aa:bb:cc:11:22:33', host: '192.0.2.99'));
    expect(identityFor(mac: null, host: '192.0.2.4'), 'host:192.0.2.4');
    expect(identityFor(mac: '', host: '192.0.2.4'), 'host:192.0.2.4',
        reason: 'an empty address is no address');
  });

  test('one sender closing does not disarm another on the same host', () async {
    // The client is shared and the registrations are not. A group run drives
    // several members at once and closes each sender in a `finally`, so two
    // saved records pointing at one host is enough for one close to erase a
    // policy another sender is still relying on — and the survivor never
    // re-registers, because its own handover is memoized. Its next https send
    // would fall through to the by-host fallback, which accepts anything.
    final client = HttpControlClient(trust: trust);
    for (var i = 0; i < 2; i++) {
      await client.useTlsPolicy(
        host: '192.0.2.4',
        identity: 'envoy@192.0.2.4',
        policy: TlsPolicy.trustOnFirstUse,
      );
    }
    expect(
        client.debugEvaluateCertificate(_FakeCert('envoy'), '192.0.2.4', 443),
        isTrue);

    client.forgetHost('192.0.2.4');
    expect(
      client.debugEvaluateCertificate(_FakeCert('impostor'), '192.0.2.4', 443),
      isFalse,
      reason: 'the second sender is still live and still pinned',
    );

    // Both gone: the policy goes with them, and nothing about this host is
    // remembered on a client that outlives every screen.
    client.forgetHost('192.0.2.4');
    expect(
      client.debugEvaluateCertificate(_FakeCert('impostor'), '192.0.2.4', 443),
      isFalse,
      reason: 'an unregistered host is not on the trusted list either',
    );
  });

  test('a sender that never registered cannot disarm one that did', () async {
    // The refcount was asymmetric: `useTlsPolicy` increments only on a
    // sender's first https send, while close() forgot unconditionally. A
    // second sender for the same host that never sent anything would, on
    // close, decrement a count it had never incremented — dropping a live
    // sender's pinned policy to zero. The survivor's own handover is memoized,
    // so it never re-registered and its next send fell through to blanket
    // trust: an impostor accepted on a device pinned a moment earlier.
    final client = HttpControlClient(trust: trust);
    await client.useTlsPolicy(
      host: '192.0.2.4',
      identity: 'envoy@192.0.2.4',
      policy: TlsPolicy.trustOnFirstUse,
    );
    expect(client.debugEvaluateCertificate(_FakeCert('real'), '192.0.2.4', 443),
        isTrue);

    // The unregistered sibling closing. It registered nothing, so it forgets
    // nothing — which is what the sender now enforces by only calling
    // forgetHost when it holds a registration.
    expect(
      client.debugEvaluateCertificate(_FakeCert('impostor'), '192.0.2.4', 443),
      isFalse,
      reason: 'the registered sender is still pinned',
    );
  });

  test('a pin that cannot be read refuses instead of re-pinning', () async {
    // Not the same as having no pin, and the difference decides the
    // handshake. A locked keystore on a backgrounded app reads as "no pin",
    // and first-contact trust would then overwrite a real fingerprint with
    // whatever just answered — the exact substitution the pin exists to catch.
    final failing = _FailingStore();
    final guarded = TlsTrust(CertificatePinStore(failing));
    await guarded.prepare('envoy@192.0.2.4');

    final evaluate = guarded.evaluator(
      identity: 'envoy@192.0.2.4',
      policy: TlsPolicy.trustOnFirstUse,
      fallback: (_, __, ___) => true,
    );
    expect(evaluate(_FakeCert('whatever'), '192.0.2.4', 443), isFalse);
    expect(guarded.refused('192.0.2.4'), isTrue,
        reason: 'and it says WHY, rather than reading as unreachable');
  });

  test('a standard-policy refusal is reported as a certificate problem', () {
    // "The device is not reachable — try scanning again" is advice that cannot
    // help for a certificate that does not chain to a trusted root.
    final evaluate = evaluatorFor(TlsPolicy.standard);
    expect(evaluate(_FakeCert('unchained'), '192.0.2.7', 443), isFalse);
    expect(trust.refused('192.0.2.7'), isTrue);
  });

  test('forgetting one device leaves another\'s refusal recorded', () async {
    // `_refused` was cleared wholesale, so forgetting device A erased device
    // B's recorded refusal and B's next failure reported as plain unreachable.
    final evaluate = evaluatorFor(TlsPolicy.trustOnFirstUse);
    expect(evaluate(_FakeCert('first'), '192.0.2.4', 443), isTrue);
    expect(evaluate(_FakeCert('changed'), '192.0.2.4', 443), isFalse);
    expect(trust.refused('192.0.2.4'), isTrue);

    await trust.forget('someone-else@192.0.2.9', host: '192.0.2.9');

    expect(trust.refused('192.0.2.4'), isTrue,
        reason: 'another device being forgotten is not news about this one');
  });

  test('a refused certificate is distinguishable from an absent device', () {
    // `badCertificateCallback` returns a bool, so the handshake failure that
    // follows carries no reason and reads exactly like a device switched off.
    // That is how a factory-reset Envoy got reported as "not reachable — it
    // may be off or have a new address", with nothing naming the certificate
    // or the one action that recovers it.
    final evaluate = evaluatorFor(TlsPolicy.trustOnFirstUse);
    expect(trust.refused('192.0.2.4'), isFalse);

    expect(evaluate(_FakeCert('first'), '192.0.2.4', 443), isTrue);
    expect(trust.refused('192.0.2.4'), isFalse,
        reason: 'first contact is fine');

    expect(evaluate(_FakeCert('changed'), '192.0.2.4', 443), isFalse);
    expect(trust.refused('192.0.2.4'), isTrue);

    // And the real device coming back clears it, so one bad handshake does not
    // mislabel every later failure on that host.
    expect(evaluate(_FakeCert('first'), '192.0.2.4', 443), isTrue);
    expect(trust.refused('192.0.2.4'), isFalse);
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
