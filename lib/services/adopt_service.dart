// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import '../core/error_text.dart';
import '../core/log.dart';
import 'lifx_control_service.dart';
import 'soap_control_service.dart';
import 'spec_codec.dart';

/// Which onboarding conversation a setup network speaks. Derived from the
/// matched spec's `softap_*` method type, so a third adoptable family is a spec
/// plus one enum arm, not a rewrite.
enum AdoptFamily {
  /// Wemo: UPnP/SOAP over the setup AP's HTTP server.
  wemo,

  /// LIFX: the legacy access-point datagrams over UDP.
  lifx;

  static AdoptFamily? fromMethodType(String methodType) => switch (methodType) {
        'softap_soap' => AdoptFamily.wemo,
        'softap_udp' => AdoptFamily.lifx,
        _ => null,
      };
}

/// A home network the device itself reported it can see, reduced to what the UI
/// shows and what provisioning needs to send back.
///
/// The two families fill different halves: Wemo carries `auth`/`encrypt`/
/// `channel` (its `ConnectHomeNetwork` rejects any vocabulary but the device's
/// own); LIFX carries `securityByte`. `joinable` is false for a network the
/// device said it cannot express (Wemo's `Unknown`, i.e. WPA3).
class SetupNetwork {
  final String ssid;
  final bool joinable;
  final bool isOpen;

  // Wemo.
  final String? auth;
  final String? encrypt;
  final String? channel;

  // LIFX.
  final int? securityByte;

  const SetupNetwork({
    required this.ssid,
    required this.joinable,
    required this.isOpen,
    this.auth,
    this.encrypt,
    this.channel,
    this.securityByte,
  });
}

/// The result of a provisioning attempt, in the vocabulary the UI needs to
/// choose its next screen.
enum AdoptStatus {
  /// The device accepted the credentials and reported it joined.
  joined,

  /// The credentials were sent but the device never confirmed a join. For LIFX
  /// this is the expected terminal state — the exchange is fire-and-forget and
  /// the only real confirmation is the device turning up on the home LAN.
  sentUnconfirmed,

  /// The device rejected the passphrase for a reason retrying will not fix
  /// (Wemo network status 2 — shorter than 8 characters).
  rejected,

  /// Nothing on the setup network answered.
  unreachable,
}

/// The outcome of [AdoptService.provision], carrying a line for the UI.
class AdoptOutcome {
  final AdoptStatus status;
  final String message;

  const AdoptOutcome(this.status, this.message);
}

/// A step the caller wanted did not go through, with text safe to show.
class AdoptException implements UserFacingException {
  @override
  final String message;
  const AdoptException(this.message);
  @override
  String toString() => 'AdoptException: $message';
}

/// Drives the two Wi-Fi adoption conversations from the spec and nothing else.
///
/// The division is the same as the rest of the app: what to send and what a
/// reply means come from the catalogue (rendered and parsed by the Rust
/// [codec]); this class only sequences the moves. The Wemo half speaks SOAP
/// through the shared [SoapControlClient]; the LIFX half speaks UDP through the
/// shared [LifxControlClient] and the same LIFX SoftAP primitives the rest of
/// the app uses. Both transports are constructor-injected, so the whole flow
/// runs in a unit test against canned replies with no radio.
class AdoptService {
  final SpecCodec codec;
  final SoapControlClient soap;
  final LifxControlClient lifx;

  /// Wemo setup ports to probe for `/setup.xml`, in the spec's order. The
  /// setup-mode port moves like the normal one, so the gateway is probed.
  final List<int> wemoPorts;

  /// Where the Wemo device answers on its own setup AP.
  final String wemoGateway;

  /// The LIFX setup network is its own subnet with one device on it; a
  /// broadcast reaches it whether or not we know its address yet.
  static const lifxSetupBroadcast = '255.255.255.255';

  AdoptService({
    required this.codec,
    SoapControlClient? soap,
    LifxControlClient? lifx,
    this.wemoPorts = const [49153, 49152, 49154, 49151, 49155],
    this.wemoGateway = '10.22.22.1',
  })  : soap = soap ?? SoapControlClient(),
        lifx = lifx ?? LifxControlClient();

  /// Confirm the client is on the device's setup network and resolve where to
  /// talk to it. For Wemo this fetches `/setup.xml` (caching the control URLs);
  /// for LIFX it broadcasts `GetService` and waits for any answer.
  ///
  /// Returns null when nothing answered — the near-universal cause is the client
  /// not being joined to the setup AP yet, a normal state the UI turns into
  /// "join the network, then tap again", not an error.
  Future<AdoptSession?> connect({
    required AdoptFamily family,
    required String specYaml,
  }) async {
    switch (family) {
      case AdoptFamily.wemo:
        return _connectWemo(specYaml);
      case AdoptFamily.lifx:
        return _connectLifx(specYaml);
    }
  }

  Future<AdoptSession?> _connectWemo(String specYaml) async {
    for (final port in wemoPorts) {
      try {
        final description = await soap.fetchDescription(wemoGateway, port);
        // The WiFiSetup service is only listed while the device is in setup
        // mode; its presence proves we are talking to a Wemo AP and not, say, a
        // captive portal that answered /setup.xml with an HTML page.
        final hasSetup = description.controlUrls.keys
            .any((type) => type.contains('WiFiSetup'));
        if (hasSetup) {
          return AdoptSession._(
            family: AdoptFamily.wemo,
            specYaml: specYaml,
            description: description,
          );
        }
      } catch (e) {
        Log.net.debug('wemo setup probe on $wemoGateway:$port failed: $e');
      }
    }
    return null;
  }

  Future<AdoptSession?> _connectLifx(String specYaml) async {
    try {
      final seq = lifx.nextSequence();
      final probe = await codec.buildLifxDiscoveryProbe(sequence: seq);
      final replies = await lifx.collect(
        lifxSetupBroadcast,
        Uint8List.fromList(probe),
        sequence: seq,
        window: const Duration(seconds: 3),
      );
      // Any datagram that decodes as a StateService proves a LIFX device is on
      // the setup network.
      for (final reply in replies) {
        try {
          await codec.parseLifxStateService(bytes: reply);
          return AdoptSession._(family: AdoptFamily.lifx, specYaml: specYaml);
        } catch (_) {
          // Not a StateService; keep looking.
        }
      }
    } catch (e) {
      Log.net.debug('lifx setup discovery failed: $e');
    }
    return null;
  }

  /// Ask the device what home networks it can see. Wemo devices always can
  /// (their `ConnectHomeNetwork` needs the auth/cipher/channel from this list);
  /// LIFX devices sometimes return nothing, in which case the caller falls back
  /// to a typed SSID.
  Future<List<SetupNetwork>> listNetworks(AdoptSession session) async {
    switch (session.family) {
      case AdoptFamily.wemo:
        return _listWemoNetworks(session);
      case AdoptFamily.lifx:
        return _listLifxNetworks();
    }
  }

  Future<List<SetupNetwork>> _listWemoNetworks(AdoptSession session) async {
    final reply = await _sendWemo(session, stateCommand: 'GetApList');
    final apList = reply['ApList'];
    if (apList == null) return const [];
    final networks = await codec.parseWemoApList(apList: apList);
    return [
      for (final ap in networks)
        SetupNetwork(
          ssid: ap.ssid,
          joinable: ap.joinable,
          isOpen: ap.isOpen,
          auth: ap.auth,
          encrypt: ap.encrypt,
          channel: ap.channel,
        ),
    ];
  }

  Future<List<SetupNetwork>> _listLifxNetworks() async {
    final seq = lifx.nextSequence();
    final request = await codec.buildLifxGetAccessPoints(sequence: seq);
    final replies = await lifx.collect(
      lifxSetupBroadcast,
      Uint8List.fromList(request),
      sequence: seq,
    );
    final found = <String, SetupNetwork>{};
    for (final reply in replies) {
      try {
        final ap = await codec.decodeLifxAccessPoint(bytes: reply);
        if (ap.ssid.isEmpty) continue;
        // One row per SSID: a strip on 2.4 and 5 GHz answers twice.
        found.putIfAbsent(
          ap.ssid,
          () => SetupNetwork(
            ssid: ap.ssid,
            joinable: true,
            isOpen: ap.security == 1,
            securityByte: ap.security,
          ),
        );
      } catch (_) {
        // A malformed scan result is skipped, not fatal.
      }
    }
    final networks = found.values.toList()
      // Strongest first is what the user reaches for, but strength is not on
      // SetupNetwork; the device already returns them roughly so-ordered.
      ..sort((a, b) => a.ssid.compareTo(b.ssid));
    return networks;
  }

  /// Hand the device its home network. [passphrase] is empty for an open
  /// network. The returned [AdoptOutcome] says what to show next.
  Future<AdoptOutcome> provision(
    AdoptSession session,
    SetupNetwork network,
    String passphrase,
  ) async {
    switch (session.family) {
      case AdoptFamily.wemo:
        return _provisionWemo(session, network, passphrase);
      case AdoptFamily.lifx:
        return _provisionLifx(network, passphrase);
    }
  }

  Future<AdoptOutcome> _provisionWemo(
    AdoptSession session,
    SetupNetwork network,
    String passphrase,
  ) async {
    // A secured network needs the device metadata the passphrase key derives
    // from; an open one skips the encryption entirely (the spec's rule) and
    // GetMetaInfo with it.
    var meta = '';
    if (!network.isOpen) {
      final metaInfo =
          (await _sendWemo(session, stateCommand: 'GetMetaInfo'))['MetaInfo'];
      if (metaInfo == null) {
        throw const AdoptException(
            'The device did not return the information needed to encrypt the '
            'password. Try again from a factory reset.');
      }
      meta = metaInfo;
    }

    // Rust assembles the whole credential-send: it encrypts every variant of
    // the spec's sweep and renders each into a ready ConnectHomeNetwork
    // request. This service owns only the socket and the poll — never the
    // crypto or the XML — exactly as control leaves it.
    final List<SoapRequestDto> requests;
    try {
      requests = await codec.renderWemoConnectRequests(
        specYaml: session.specYaml,
        metaInfo: meta,
        ssid: network.ssid,
        auth: network.auth ?? '',
        encrypt: network.encrypt ?? '',
        channel: network.channel ?? '',
        passphrase: passphrase,
      );
    } catch (e) {
      throw AdoptException(friendlyErrorText(e,
          context: 'wemo connect request',
          fallback: 'That password can\'t be used. Wi-Fi passwords must be at '
              'least 8 characters.'));
    }

    // The device only tells us a variant was wrong by never connecting, so each
    // is tried in turn until one joins.
    for (final request in requests) {
      final outcome = await _tryWemoRequest(session, request);
      if (outcome.status == AdoptStatus.joined) {
        await _closeWemoSetup(session);
        return outcome;
      }
      if (outcome.status == AdoptStatus.rejected) {
        // Terminal — a different encryption will not lengthen an
        // 8-character-minimum passphrase.
        return outcome;
      }
    }
    return const AdoptOutcome(
      AdoptStatus.sentUnconfirmed,
      'The device took the settings but did not confirm it joined. Give it a '
      'minute, then look for it in a Wi-Fi scan. If it never appears, factory '
      'reset and try again — Wemo setup sometimes needs a second attempt.',
    );
  }

  Future<AdoptOutcome> _tryWemoRequest(
    AdoptSession session,
    SoapRequestDto request,
  ) async {
    // Send twice, ~100ms apart: pywemo reports a markedly higher success rate
    // when it is repeated, and the spec carries the rule forward.
    await _sendWemoRequest(session, request);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await _sendWemoRequest(session, request);

    // Poll GetNetworkStatus up to the spec's 20-second floor; Rust names the
    // status code.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final code = (await _sendWemo(session,
          stateCommand: 'GetNetworkStatus'))['NetworkStatus'];
      if (code == null) continue;
      switch (await codec.wemoNetworkStatus(code: code)) {
        case WemoJoinStatus.connected:
          return const AdoptOutcome(AdoptStatus.joined,
              'Connected. The device is joining your Wi-Fi now.');
        case WemoJoinStatus.rejected:
          return const AdoptOutcome(
            AdoptStatus.rejected,
            'The device rejected the password (it must be at least 8 '
            'characters). Fix it and try again.',
          );
        case WemoJoinStatus.connecting:
        case WemoJoinStatus.handshaking:
        case WemoJoinStatus.unknown:
          break; // Keep polling.
      }
    }
    return const AdoptOutcome(AdoptStatus.sentUnconfirmed, '');
  }

  Future<void> _closeWemoSetup(AdoptSession session) async {
    // Best-effort: CloseSetup drops the AP so the device joins the home
    // network; SetSetupDoneStatus is absent on some firmware. Neither failing
    // changes that the credentials were accepted.
    for (final command in const ['CloseSetup', 'SetSetupDoneStatus']) {
      try {
        await _sendWemo(session, stateCommand: command);
      } catch (e) {
        Log.net.debug('wemo $command after join failed (non-fatal): $e');
      }
    }
  }

  Future<AdoptOutcome> _provisionLifx(
    SetupNetwork network,
    String passphrase,
  ) async {
    final security = network.securityByte ?? await codec.lifxDefaultSecurity();
    final Uint8List datagram;
    try {
      datagram = await codec.renderLifxSetAccessPoint(
        ssid: network.ssid,
        password: passphrase,
        security: security,
        sequence: lifx.nextSequence(),
      );
    } catch (e) {
      throw AdoptException(friendlyErrorText(e,
          context: 'lifx set access point',
          fallback: 'Those network details can\'t be sent to the device.'));
    }
    // Fire-and-forget by design: the legacy SetAccessPoint has no reply and no
    // status poll. The password is not kept anywhere.
    await lifx.send(lifxSetupBroadcast, datagram);
    return const AdoptOutcome(
      AdoptStatus.sentUnconfirmed,
      'Sent. The light will drop its setup network and join your Wi-Fi. '
      'Rejoin your home network and it should turn up in a Wi-Fi scan.',
    );
  }

  // ── Wemo SOAP helpers ──────────────────────────────────────────────────────

  Future<Map<String, String>> _sendWemo(
    AdoptSession session, {
    required String stateCommand,
  }) async {
    final request = await codec.renderNetworkStateRequest(
      specYaml: session.specYaml,
      stateCommand: stateCommand,
    );
    return _sendWemoRequest(session, request);
  }

  Future<Map<String, String>> _sendWemoRequest(
    AdoptSession session,
    SoapRequestDto request,
  ) {
    final description = session.description!;
    final path = description.controlPathFor(request);
    if (path == null) {
      throw AdoptException(
          'The device does not offer ${request.action} in setup mode.');
    }
    return soap.send(description.host, description.port, path, request);
  }
}

/// A live adoption conversation: the family, the matched-spec YAML the render
/// calls need, and — for Wemo — the resolved device description its control
/// URLs come from. Immutable; built by [AdoptService.connect].
class AdoptSession {
  final AdoptFamily family;

  /// The matched-spec YAML the render calls use. Empty for LIFX, whose SoftAP
  /// primitives the crate encodes without a spec.
  final String specYaml;

  /// Wemo only: the parsed `/setup.xml`, the source of every control path. Null
  /// for LIFX.
  final SoapDeviceDescription? description;

  const AdoptSession._({
    required this.family,
    required this.specYaml,
    this.description,
  });
}
