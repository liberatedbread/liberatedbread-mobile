// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/log.dart';
import '../models/network_device.dart';
import 'settings_store.dart';

/// What a spec says to do about a LAN device's TLS certificate.
///
/// A LAN device's certificate is almost never publicly verifiable: the chain
/// ends at a self-signed leaf, or at a vendor CA no platform store carries. So
/// the platform's answer is always "reject", and every client that wants to
/// reach the device has to override it — which is where the honesty goes. Each
/// client here had invented its own override and they had all landed on the
/// same one: accept anything.
///
/// `identification.tls.verification` is the spec answering the question
/// properly, and this is that answer as a type.
enum TlsPolicy {
  /// The certificate validates against a public chain. Rare on a LAN, and the
  /// only value where the platform's own check is the whole story.
  standard,

  /// Pin the leaf the first time it is seen; refuse a different one after.
  /// The Hue bridge precedent, and what the Envoy and SmartCast specs ask for.
  trustOnFirstUse,

  /// Validate against a vendor CA the spec's notes point at. No CA bundle
  /// ships with this app, so it is served as [trustOnFirstUse] — pinning the
  /// leaf is strictly stronger than accepting anything, and weaker than the
  /// chain check the spec describes. Named rather than silently folded in, so
  /// the day a bundle exists there is one place to change.
  vendorCa,

  /// Tolerate any certificate. Honest only for a device that regenerates its
  /// certificate on every boot, where a pin would break on the next reboot.
  none;

  /// The policy for a spec's `tls.verification` string.
  ///
  /// An unrecognised value — a policy written after this build — resolves to
  /// [trustOnFirstUse] rather than [none]: an unknown instruction should land
  /// on the more cautious of the two behaviours this app can actually perform,
  /// not the one that checks nothing.
  ///
  /// A spec that states NOTHING is a different case and the caller decides it:
  /// see [TlsTrust.evaluator]'s `fallback`.
  static TlsPolicy? parse(String? verification) => switch (verification) {
    null => null,
    'standard' => TlsPolicy.standard,
    'trust_on_first_use' => TlsPolicy.trustOnFirstUse,
    'vendor_ca' => TlsPolicy.vendorCa,
    'none' => TlsPolicy.none,
    _ => TlsPolicy.trustOnFirstUse,
  };
}

/// Why a policy refused a handshake.
///
/// `badCertificateCallback` returns a bool, so the reason has to be recorded
/// on the side or it is gone — and the three are NOT the same news. Reporting
/// all of them as "the device is presenting a different certificate than
/// before" was wrong twice: [unverifiableChain] pins nothing, so there is no
/// "before" to differ from, and [pinUnreadable] says nothing about the
/// certificate at all. Each one points at a different action, which is the
/// only reason a user-facing message exists.
enum TlsRefusal {
  /// A pinned device presented a leaf that is not the pinned one. Re-pair, or
  /// find out what is answering at that address.
  certificateChanged,

  /// The spec asked for `standard` validation and the chain does not reach a
  /// trusted root. Nothing was pinned; nothing changed.
  unverifiableChain,

  /// The device is pinned but the stored fingerprint could not be READ, so
  /// first-contact trust would overwrite it. The certificate may be fine.
  pinUnreadable,
}

/// Remembers which certificate a device presented the first time, so a later
/// change is visible.
///
/// Keyed by the identity the CALLER considers stable, not by IP: an IP is a
/// DHCP lease and re-pinning on every lease change is the same as not pinning.
/// The Hue bridge's own store keys by bridgeid for exactly this reason; a
/// device with no better handle passes its host, which is honest — it pins
/// within a lease and says so — but weaker.
///
/// Backed by [SettingsStore], so production writes reach the platform keychain
/// and tests inject an in-memory fake. A pin is not a secret, but it is the
/// thing an attacker would most like to edit.
class CertificatePinStore {
  final SettingsStore _store;

  CertificatePinStore(this._store);

  static String _key(String identity) => 'tls.pin.$identity';

  Future<String?> pin(String identity) => _store.read(_key(identity));

  Future<void> save(String identity, String fingerprint) =>
      _store.write(_key(identity), fingerprint);

  Future<void> clear(String identity) => _store.delete(_key(identity));
}

/// How a device is keyed in the pin store.
///
/// The hardware address when it published one, because that is the only handle
/// here that does not move: keying by IP re-pins on every DHCP lease — the
/// same as not pinning — and hands the next tenant of that address the
/// previous device's fingerprint to fail against. The host is the fallback,
/// and the prefix says which kind of handle it is so the two can never
/// collide.
///
/// One function because two callers have to agree exactly: the sender that
/// writes the pin, and the forget-device flow that clears it. A key computed
/// two ways is a pin nothing can erase.
String identityFor({String? mac, String? host}) =>
    (mac != null && mac.isNotEmpty)
    ? 'mac:${mac.toLowerCase()}'
    : 'host:${host ?? ''}';

/// The one spelling of "this scanned device's store identity".
///
/// Three call sites — the device screen, the sender factory, the group
/// provider — each used to derive it by hand from the same two fields. An
/// edit to any one of them (a normalization, a keying change) would split
/// the key a credential is WRITTEN under from the keys it is READ under:
/// saved but never found, and the television's Allow prompt returns.
extension NetworkDeviceIdentity on NetworkDevice {
  String get credentialIdentity => identityFor(mac: advertisedMac, host: host);
}

/// The sha256 of a certificate's DER encoding, lowercase hex — what gets
/// pinned. The DER is the certificate's own bytes, so this changes when and
/// only when the certificate does.
String certificateFingerprint(X509Certificate certificate) =>
    sha256.convert(certificate.der).toString();

/// Builds the `badCertificateCallback` a policy implies.
///
/// Written for three callers and wired into two.
///
/// `HttpControlClient` reads it, and both specs that ask to be pinned ride
/// plain HTTP, so the policy reaches every device that currently declares one.
/// The MQTT transport reads it through `pinnedTlsConnect`, and the Roomba —
/// whose spec says "validate by pinning on first sight" and whose password
/// crosses every reconnect — pins under `roomba:<BLID>` through it; the other
/// MQTT specs declare `verification: none` and keep the accept-anything
/// connector. `WsSession` still answers this question itself with an
/// unconditional yes — honest today, because the specs on that transport
/// declare `verification: none` and mean it (a television's certificate is
/// self-signed with no chain), but it is its answer rather than the spec's.
/// Rust already parses `websocket.connect.tls.verification` and carries it
/// across the FFI, where no Dart reads it; the day a spec pairs
/// `trust_on_first_use` with a socket, that is the wiring to do, and this
/// class is what it wires into.
class TlsTrust {
  final CertificatePinStore _pins;

  TlsTrust(this._pins);

  /// Certificates already accepted this session, so a policy decision is made
  /// once per identity rather than on every reconnect. The store is async and
  /// `badCertificateCallback` is not, which is the other reason this exists:
  /// the pin has to be in hand BEFORE the handshake.
  final Map<String, String> _known = <String, String>{};

  /// Hosts whose certificate this policy REFUSED, so the failure that follows
  /// can say why.
  ///
  /// `badCertificateCallback` returns a bool: it cannot carry a reason, and
  /// what the caller sees is a `HandshakeException` indistinguishable from a
  /// device being switched off. That is how a factory-reset Envoy ended up
  /// reported as "not reachable — it may be off or have a new address", with
  /// nothing anywhere naming the certificate or the one action that recovers
  /// it. The refusal is recorded here and read one layer up.
  ///
  /// Keyed by host because that is what the caller asks with, and REMOVED per
  /// host for the same reason. It used to be cleared wholesale by [forget],
  /// which meant forgetting device A erased device B's recorded refusal and
  /// B's next failure reported as a plain unreachable.
  ///
  /// The VALUE is which refusal it was: a bare set could only say "the policy
  /// said no", and the caller then had one sentence for three different
  /// situations.
  final Map<String, TlsRefusal> _refused = <String, TlsRefusal>{};

  /// Identities whose stored pin could not be read.
  ///
  /// Not the same as having no pin, and the difference decides the handshake.
  /// No pin is first contact: accept, remember. An UNREADABLE pin is a device
  /// that may well have one — a locked keystore on a backgrounded app, a
  /// desktop with no keyring — and taking the first-contact branch there would
  /// overwrite a real pin with whatever just answered, which is precisely the
  /// substitution the pin exists to catch. So it refuses instead.
  final Set<String> _unreadable = <String>{};

  /// Whether the last handshake with [host] was refused BY THIS POLICY rather
  /// than by the network.
  bool refused(String host) => _refused.containsKey(host);

  /// WHICH refusal the last handshake with [host] was, or null when the
  /// policy did not refuse it. The caller turns this into the one sentence
  /// that names the action the user can take.
  TlsRefusal? refusalReason(String host) => _refused[host];

  /// Load [identity]'s pin so [evaluator] can answer synchronously. Call
  /// before opening the connection.
  ///
  /// Never throws: the caller publishes its policy either way, and a store
  /// that could not be read is recorded so the evaluator can fail CLOSED. A
  /// throw here used to skip the caller's publish entirely, which left the
  /// host on the blanket-trust fallback — a device that asked to be pinned
  /// downgraded to accept-anything by a transient storage blip.
  Future<void> prepare(String identity) async {
    try {
      final stored = await _pins.pin(identity);
      _unreadable.remove(identity);
      if (stored != null && stored.isNotEmpty) _known[identity] = stored;
    } catch (e) {
      _unreadable.add(identity);
      Log.net.warning(
        'could not read the stored certificate pin for $identity; '
        'this device will refuse rather than trust on first contact',
        error: e,
      );
    }
  }

  /// Forget [identity]'s pin, in the store and in memory.
  ///
  /// The recovery a refused certificate points at. A pin is never replaced
  /// silently — a changed certificate is a reset, new firmware, or somebody in
  /// the middle, and this app cannot tell which — so forgetting the device has
  /// to be a real way out rather than a sentence in a log line. Clearing the
  /// in-memory copy matters as much as the stored one: `_known` lives on a
  /// Provider that outlives any screen, so a store-only clear would leave the
  /// old fingerprint deciding until the process ended.
  Future<void> forget(String identity, {String? host}) async {
    _known.remove(identity);
    _unreadable.remove(identity);
    // Only this device's recorded refusal. `_refused` is host-keyed and this
    // is identity-keyed, so the host is passed when the caller knows it;
    // clearing the whole set was erasing every OTHER device's refusal.
    if (host != null) _refused.remove(host);
    await _pins.clear(identity);
  }

  /// The callback for one device.
  ///
  /// [fallback] is what to do when the spec states no policy at all — which is
  /// most of the catalogue, and where changing behaviour would break devices
  /// that work today. Callers pass what they did before.
  bool Function(X509Certificate cert, String host, int port) evaluator({
    required String identity,
    required TlsPolicy? policy,
    required bool Function(X509Certificate cert, String host, int port)
    fallback,
  }) {
    return (cert, host, port) {
      switch (policy) {
        // The platform already rejected this certificate, and `standard` says
        // the platform is right. Nothing to excuse.
        case TlsPolicy.standard:
          Log.net.warning(
            'TLS rejected for $host:$port: the spec asks for standard '
            'validation and the certificate does not chain to a trusted root',
          );
          // Recorded like any other policy refusal. Without it the caller
          // reports "not reachable — try scanning again", which is advice that
          // cannot help for a failure that is not about reachability.
          _refused[host] = TlsRefusal.unverifiableChain;
          return false;
        case TlsPolicy.none:
          return true;
        case TlsPolicy.trustOnFirstUse:
        case TlsPolicy.vendorCa:
          final fingerprint = certificateFingerprint(cert);
          if (_unreadable.contains(identity)) {
            Log.net.warning(
              'TLS refused for $host:$port: this device is pinned but its '
              'stored fingerprint could not be read, so first-contact trust '
              'would overwrite it',
            );
            _refused[host] = TlsRefusal.pinUnreadable;
            return false;
          }
          final pinned = _known[identity];
          if (pinned == null) {
            _refused.remove(host);
            // First contact. Trusted, remembered, and the write is fired off
            // rather than awaited — the handshake cannot wait, and a pin that
            // fails to persist costs a re-pin, not a wrong answer.
            _known[identity] = fingerprint;
            unawaited(
              _pins
                  .save(identity, fingerprint)
                  .catchError(
                    (Object e) =>
                        Log.net.warning('could not persist a pin', error: e),
                  ),
            );
            return true;
          }
          if (pinned == fingerprint) {
            _refused.remove(host);
            return true;
          }
          // A different certificate on a device that already showed us one.
          // Either the device was replaced or reset, or something is between
          // us and it. The pin is NEVER silently replaced: the user re-pairs,
          // which is the same rule the Hue path has always applied.
          Log.net.warning(
            'TLS refused for $host:$port: the certificate changed since this '
            'device was first seen. Re-pair it if the device was reset.',
          );
          _refused[host] = TlsRefusal.certificateChanged;
          return false;
        case null:
          return fallback(cert, host, port);
      }
    };
  }
}
