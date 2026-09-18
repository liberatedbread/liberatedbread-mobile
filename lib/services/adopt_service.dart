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

  /// How many times an idempotent Wemo setup read is attempted before it is
  /// treated as a failure. Three because the spec's troubleshooting table
  /// answers "everything fails repeatedly for no clear reason" with "genuinely
  /// try again" — and because the failure it covers costs the user a factory
  /// reset. See [_setupRead] for what this does and does not cover.
  static const setupAttempts = 3;

  /// Attempts for the metadata read that happens while connecting. One retry
  /// rather than [setupAttempts]: the first ask can land before the client has
  /// properly settled on the setup AP, which is the transient the spec's
  /// "genuinely try again" describes and is cheap to absorb here — but a device
  /// that is simply not answering `metainfo` should not hold the network picker
  /// for the full budget, since provisioning asks again anyway.
  static const connectMetaInfoAttempts = 2;

  /// The pause between those attempts. Not zero: a Wemo answers being hammered
  /// by getting slower, so an immediate re-ask of a request that just timed out
  /// is the least likely one to be answered. Injectable only so a test can
  /// exercise the retry without spending it.
  final Duration setupRetryGap;

  AdoptService({
    required this.codec,
    SoapControlClient? soap,
    LifxControlClient? lifx,
    this.wemoPorts = const [49153, 49152, 49154, 49151, 49155],
    this.wemoGateway = '10.22.22.1',
    this.setupRetryGap = const Duration(seconds: 2),
  }) : soap = soap ?? SoapControlClient(),
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
    String? gatewayIp,
    List<int>? ports,
  }) async {
    switch (family) {
      case AdoptFamily.wemo:
        return _connectWemo(specYaml, gatewayIp: gatewayIp, ports: ports);
      case AdoptFamily.lifx:
        return _connectLifx(specYaml);
    }
  }

  Future<AdoptSession?> _connectWemo(
    String specYaml, {
    String? gatewayIp,
    List<int>? ports,
  }) async {
    // Where the device answers, and on which ports, come from the spec — the
    // profile the catalogue extracted — not from constants here. The setup
    // port moves across firmware, so the spec carries the whole probe list
    // (nine ports, not the five below); the constants are only a floor for a
    // spec that documents neither, so an older pack still limps rather than
    // dead-ends.
    final gateway = (gatewayIp != null && gatewayIp.isNotEmpty)
        ? gatewayIp
        : wemoGateway;
    final probePorts = (ports != null && ports.isNotEmpty) ? ports : wemoPorts;
    // Said up front, because the probe is the longest silence in the flow: a
    // device that is not there costs one full HTTP timeout per port, and the
    // worst case is the number a reader needs in order to tell "slow" from
    // "hung".
    final worstCase = SoapControlClient.timeout * probePorts.length;
    Log.adopt.info(
      'wemo connect: probing $gateway on ${probePorts.length} '
      'port(s) ${probePorts.join(', ')} — '
      '${SoapControlClient.timeout.inSeconds}s each, '
      'up to ${worstCase.inSeconds}s if nothing answers',
    );
    final overall = Stopwatch()..start();
    var answered = 0;
    for (final port in probePorts) {
      final attempt = Stopwatch()..start();
      try {
        final description = await soap.fetchDescription(gateway, port);
        answered++;
        // The WiFiSetup service is only listed while the device is in setup
        // mode; its presence proves we are talking to a Wemo AP and not, say, a
        // captive portal that answered /setup.xml with an HTML page.
        final hasSetup = description.controlUrls.keys.any(
          (type) => type.contains('WiFiSetup'),
        );
        if (!hasSetup) {
          // The single most misreadable outcome in the whole flow: something
          // IS there and did serve a description, so "couldn't reach the
          // device" is the wrong story. Almost always a Wemo that is already
          // provisioned (setup mode closed), which the service list says
          // plainly — so say it plainly.
          Log.adopt.warning(
            'wemo probe $gateway:$port answered in ${_elapsed(attempt)} but '
            'lists no WiFiSetup service — this is not a device in setup '
            'mode. name=${description.friendlyName ?? '<none>'} '
            'services=[${_serviceNames(description).join(', ')}]',
          );
          continue;
        }
        Log.adopt.info(
          'wemo setup AP confirmed at $gateway:$port in ${_elapsed(attempt)}: '
          'name=${description.friendlyName ?? '<none>'} '
          'firmware=${description.firmwareVersion ?? '<none>'} '
          'rtos=${description.rtos ?? '<absent>'} '
          'iot=${description.iot ?? '<absent>'} '
          'services=[${_serviceNames(description).join(', ')}]',
        );
        final session = AdoptSession._(
          family: AdoptFamily.wemo,
          specYaml: specYaml,
          description: description,
        );
        return AdoptSession._(
          family: AdoptFamily.wemo,
          specYaml: specYaml,
          description: description,
          metaInfo: await _readMetaInfoEarly(session),
        );
      } catch (e) {
        Log.adopt.debug(
          'wemo probe $gateway:$port failed after '
          '${_elapsed(attempt)}: $e',
        );
      }
    }
    // Nothing usable. Which of the two causes it was is worth separating: a
    // host that answered on some port is a reachable device in the wrong
    // state, while total silence is almost always a client that is not on the
    // setup AP at all (or whose traffic left by another interface — the spec
    // lists that as the first cause of "AP is joinable but HTTP times out").
    Log.adopt.warning(
      answered == 0
          ? 'wemo connect: nothing answered on any of ${probePorts.length} '
                'port(s) at $gateway after ${_elapsed(overall)} — the client is '
                'probably not joined to the setup AP, or its route to '
                '$gateway left by another interface'
          : 'wemo connect: $answered host(s) answered at $gateway in '
                '${_elapsed(overall)} but none offered WiFiSetup — the device is '
                'not in setup mode; factory reset it and try again',
    );
    return null;
  }

  /// Read `GetMetaInfo` while still connecting, best effort.
  ///
  /// Two reasons this is here rather than at provision time, where the key
  /// material is actually used. The spec's own step order reads the metadata
  /// before the AP list — so this is simply the documented sequence — and the
  /// device is at its least busy right now, before it has been asked to run a
  /// radio scan. (The spec's "do not call GetMetaInfo for an open network" is
  /// about not *needing* key material, not a prohibition; the read is one
  /// idempotent request either way.)
  ///
  /// [connectMetaInfoAttempts] rather than the full [setupAttempts]: a
  /// recoverable warm-up earns a retry — the first ask can arrive before the
  /// client has settled on the setup AP — but not a budget that would hold the
  /// network picker for half a minute over a read provisioning repeats anyway.
  Future<String?> _readMetaInfoEarly(AdoptSession session) async {
    try {
      final meta = (await _setupRead(
        session,
        'GetMetaInfo',
        attempts: connectMetaInfoAttempts,
      ))['MetaInfo'];
      if (meta == null) {
        Log.adopt.warning(
          'wemo GetMetaInfo answered without a MetaInfo value; '
          'a secured network cannot be encrypted for this device',
        );
        return null;
      }
      Log.adopt.debug('wemo meta: ${_metaSummary(meta)}');
      return meta;
    } catch (e) {
      // Not fatal here: an open network needs none of this, and provision
      // asks again with the retry budget. Said out loud all the same — it is
      // the earliest possible warning that a secured join will not work.
      // The error itself was just logged by the attempt loop; this line is
      // the consequence, which is the part a reader needs.
      Log.adopt.warning(
        'wemo connect: no metadata, so a secured network '
        'cannot be encrypted for this device yet — provision will ask again '
        'with up to $setupAttempts attempt(s) (${errorType(e)})',
      );
      return null;
    }
  }

  /// The service list reduced to short names — `WiFiSetup:1`, `metainfo:1` —
  /// because the full `urn:Belkin:service:…` URNs turn one useful log line
  /// into three wrapped ones.
  static List<String> _serviceNames(SoapDeviceDescription description) => [
    for (final type in description.controlUrls.keys)
      type.split(':').length > 2 ? type.split(':').skip(3).join(':') : type,
  ];

  Future<AdoptSession?> _connectLifx(String specYaml) async {
    try {
      final seq = lifx.nextSequence();
      final probe = await codec.buildLifxDiscoveryProbe(sequence: seq);
      Log.adopt.info(
        'lifx connect: broadcasting GetService to '
        '$lifxSetupBroadcast',
      );
      final replies = await lifx.collect(
        lifxSetupBroadcast,
        Uint8List.fromList(probe),
        sequence: seq,
        window: const Duration(seconds: 3),
        // The setup AP holds one device; some firmware does not echo the
        // sequence, and dropping its reply would strand it. The StateService
        // decode below is the real check.
        matchSequence: false,
      );
      // Any datagram that decodes as a StateService proves a LIFX device is on
      // the setup network.
      for (final reply in replies) {
        try {
          await codec.parseLifxStateService(bytes: reply);
          Log.adopt.info(
            'lifx setup network confirmed: a StateService reply '
            'decoded out of ${replies.length} datagram(s)',
          );
          return AdoptSession._(family: AdoptFamily.lifx, specYaml: specYaml);
        } catch (_) {
          // Not a StateService; keep looking.
        }
      }
    } catch (e) {
      Log.adopt.debug('lifx setup discovery failed: $e');
    }
    Log.adopt.warning(
      'lifx connect: nothing on the setup network answered '
      'GetService — the client is probably not joined to the light\'s AP',
    );
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
    final reply = await _setupRead(session, 'GetApList');
    final apList = reply['ApList'];
    if (apList == null) {
      // An empty picker looks identical to a device that scanned and saw
      // nothing, so the reply's actual shape is the only way to tell them
      // apart afterwards.
      Log.adopt.warning(
        'wemo GetApList returned no ApList value — the reply '
        'carried [${reply.keys.join(', ')}]',
      );
      return const [];
    }
    final networks = await codec.parseWemoApList(apList: apList);
    final joinable = networks.where((ap) => ap.joinable).length;
    Log.adopt.info(
      'wemo GetApList: ${networks.length} network(s), '
      '$joinable joinable '
      '(${apList.length} bytes, ${'\n'.allMatches(apList).length + 1} lines)',
    );
    for (final ap in networks) {
      // Per network rather than a summary: the two failures this flow cannot
      // otherwise explain — the target SSID is 5 GHz (so the device never saw
      // it and it is simply absent here), and the target is WPA3 (so it is
      // here but marked Unknown) — are both read off this list.
      Log.adopt.debug(
        'wemo ap: "${ap.ssid}" channel=${ap.channel} '
        '${ap.auth}/${ap.encrypt ?? '-'}'
        '${ap.joinable ? '' : ' NOT JOINABLE — the device cannot express '
                  'this security mode (WPA3 is the usual cause)'}',
      );
    }
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
      // As in discovery: accept the one setup-AP device's answer even if its
      // firmware does not echo the sequence; the AccessPoint decode filters.
      matchSequence: false,
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
            // Whether it is an open network is the codec's call — it owns the
            // LIFX security vocabulary — not an == against a byte here.
            isOpen: ap.isOpen,
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
    Log.adopt.info(
      'wemo provision: ssid="${network.ssid}" '
      'auth=${network.auth ?? '<none>'} encrypt=${network.encrypt ?? '<none>'} '
      'channel=${network.channel?.isEmpty ?? true ? '<none>' : network.channel} '
      'open=${network.isOpen} joinable=${network.joinable} '
      'passphrase=${passphrase.length} chars',
    );
    if (!network.joinable) {
      // Not fatal here — the user picked it, so send it — but it is the
      // explanation for the join that is about to silently never happen.
      Log.adopt.warning(
        'wemo provision: the device reported it cannot express '
        '"${network.ssid}"\'s security mode; this join will not succeed '
        'however many variants are tried',
      );
    }

    // A secured network needs the device metadata the passphrase key derives
    // from; an open one skips the encryption entirely (the spec's rule) and
    // GetMetaInfo with it.
    var meta = '';
    if (!network.isOpen) {
      // Normally already in hand, read in the spec's order while connecting.
      meta = session.metaInfo ?? '';
      if (meta.isEmpty) {
        Log.adopt.info(
          'wemo provision: no metadata from the connect step; '
          'reading it now, with up to $setupAttempts attempt(s)',
        );
        String? metaInfo;
        try {
          metaInfo = (await _setupRead(session, 'GetMetaInfo'))['MetaInfo'];
        } catch (e) {
          // The reported failure shape, and the one place the flow cannot
          // carry on: no key material, no encrypted passphrase. It used to
          // reach the screen as a bare transport error behind generic
          // "sending the settings failed" text, which names neither the step
          // nor the remedy.
          Log.adopt.warning(
            'wemo provision: the device never handed over its '
            'metadata, so the passphrase cannot be encrypted: $e',
          );
          throw const AdoptException(
            'The device stopped answering before it handed over the details '
            'needed to encrypt your Wi-Fi password. Factory reset it and try '
            'again.',
          );
        }
        if (metaInfo == null) {
          throw const AdoptException(
            'The device did not return the information needed to encrypt the '
            'password. Try again from a factory reset.',
          );
        }
        meta = metaInfo;
        Log.adopt.debug('wemo meta: ${_metaSummary(metaInfo)}');
      }
    }

    // Rust assembles the whole credential-send: it encrypts every variant of
    // the spec's sweep and renders each into a ready ConnectHomeNetwork
    // request. This service owns only the socket and the poll — never the
    // crypto or the XML — exactly as control leaves it.
    final List<WemoConnectAttemptDto> requests;
    try {
      requests = await codec.renderWemoConnectRequests(
        specYaml: session.specYaml,
        metaInfo: meta,
        ssid: network.ssid,
        auth: network.auth ?? '',
        encrypt: network.encrypt ?? '',
        channel: network.channel ?? '',
        passphrase: passphrase,
        // The setup.xml's own rtos/iot markers pick the password layout to try
        // first, so an rtos=1 unit does not burn a full poll on the wrong one.
        rtos: session.description?.rtos,
        iot: session.description?.iot,
      );
    } catch (e) {
      throw AdoptException(
        friendlyErrorText(
          e,
          context: 'wemo connect request',
          log: Log.adopt,
          fallback:
              'That password can\'t be used. Wi-Fi passwords must be at '
              'least 8 characters.',
        ),
      );
    }
    // The device never says which encryption variant it liked, so the sweep is
    // the flow's other long silence: every variant that does not join costs a
    // full 20-second status poll. Name the size of it, and the setup.xml
    // markers that chose the order, before spending it.
    Log.adopt.info(
      'wemo provision: ${requests.length} credential variant(s) to '
      'try (rtos=${session.description?.rtos ?? '<absent>'}, '
      'iot=${session.description?.iot ?? '<absent>'}), '
      'up to ${requests.length * 20}s if none joins',
    );

    // The device only tells us a variant was wrong by never connecting, so each
    // is tried in turn until one joins.
    var everDelivered = false;
    var unreachableRun = 0;
    for (final (index, attempt) in requests.indexed) {
      final label =
          'variant ${index + 1}/${requests.length} '
          '(${_variantLabel(attempt)})';
      final outcome = await _tryWemoRequest(session, attempt.request, label);
      if (outcome.status == AdoptStatus.joined) {
        // The one fact the whole sweep exists to discover, and the one worth
        // carrying into a bug report: which layout this hardware wanted.
        Log.adopt.info('wemo provision: joined with $label');
        await _closeWemoSetup(session);
        return outcome;
      }
      if (outcome.status == AdoptStatus.rejected) {
        // Terminal — a different encryption will not lengthen an
        // 8-character-minimum passphrase.
        Log.adopt.warning(
          'wemo provision: the device rejected the passphrase '
          '(network status 2 — shorter than 8 characters); '
          '${requests.length - index - 1} variant(s) not tried, because none '
          'of them would make it longer',
        );
        return outcome;
      }
      // sentUnconfirmed means this variant's credentials reached the device;
      // unreachable means not even the first send got through. Remember the
      // difference: once anything was delivered the honest summary is "sent,
      // unconfirmed", never "nothing happened".
      if (outcome.status == AdoptStatus.sentUnconfirmed) {
        everDelivered = true;
        unreachableRun = 0;
        continue;
      }
      if (outcome.status != AdoptStatus.unreachable) continue;
      unreachableRun++;
      // R-029: a variant is a guess about ENCRYPTION, and encryption is not
      // why a send did not arrive. Once two in a row have failed to reach the
      // device at all, and nothing has ever landed, the setup access point is
      // gone — and every remaining variant is another twenty-second poll
      // spent proving it again, with the user watching a spinner. Two rather
      // than one, so a single dropped datagram on a flaky setup AP still gets
      // a second chance.
      if (unreachableRun >= 2 && !everDelivered) {
        Log.adopt.warning(
          'wemo provision: two variants in a row did not reach the device and '
          'nothing has landed; stopping with '
          '${requests.length - index - 1} variant(s) untried, because a '
          'different encryption cannot fix a send that never arrives',
        );
        break;
      }
    }
    if (!everDelivered) {
      Log.adopt.warning(
        'wemo provision: no variant got a first send through — the setup AP '
        'went away before any credentials landed',
      );
      return const AdoptOutcome(
        AdoptStatus.unreachable,
        'The device stopped answering on its setup network before the settings '
        'went through. Make sure you are still joined to its Wi-Fi, then try '
        'again.',
      );
    }
    Log.adopt.warning(
      'wemo provision: all ${requests.length} variant(s) were '
      'delivered and none reported a join. Most likely: wrong passphrase, or '
      'a 5 GHz-only SSID (every Wemo radio is 2.4 GHz), or the band-steering '
      'case where one SSID name covers both bands',
    );
    return const AdoptOutcome(
      AdoptStatus.sentUnconfirmed,
      'The device took the settings but did not confirm it joined. Give it a '
      'minute, then look for it in a Wi-Fi scan. If it never appears, factory '
      'reset and try again — Wemo setup sometimes needs a second attempt.',
    );
  }

  /// Which encryption layout built one attempt, in the spec's own vocabulary.
  static String _variantLabel(WemoConnectAttemptDto attempt) {
    final method = attempt.method;
    if (method == null) return 'open network, no password';
    return 'method $method, '
        '${attempt.addLengths ? 'with' : 'without'} length suffix';
  }

  /// A `GetMetaInfo` reply reduced to a line worth logging.
  ///
  /// Two of these fields are the key material for the passphrase encryption,
  /// and the spec warns that swapping them yields a valid-looking blob the
  /// device rejects without explanation — so the shapes are what this reports:
  /// the MAC's OUI half (a manufacturer prefix, not an identity) and the
  /// serial's length. Never the serial itself: it is the device's identity and
  /// half the encryption key, and neither belongs in a log or a screen share.
  static String _metaSummary(String metaInfo) {
    final fields = metaInfo.split('|');
    String field(int index) =>
        index < fields.length ? fields[index].trim() : '<absent>';
    final mac = field(0);
    final serial = field(1);
    return 'fields=${fields.length} '
        'mac=${mac.length == 12 ? '${mac.substring(0, 6)}xxxxxx' : '<malformed: ${mac.length} chars>'} '
        'serial=<${serial.length} chars> sku=${field(2)} '
        'firmware=${field(3)} ap="${field(4)}" model=${field(5)}';
  }

  Future<AdoptOutcome> _tryWemoRequest(
    AdoptSession session,
    SoapRequestDto request,
    String label,
  ) async {
    // Send twice, ~100ms apart: pywemo reports a markedly higher success rate
    // when it is repeated, and the spec carries the rule forward. Once the
    // FIRST send is through, the device has the credentials — the setup AP is
    // internet-less and single-radio, so it routinely drops the moment the
    // device starts hopping to join, and a failure past that point is "sent,
    // now joining", NOT "sending failed". So the follow-up send and every poll
    // are guarded: a transient error there leaves the outcome unconfirmed, it
    // does not throw and abort the whole variant sweep.
    Log.adopt.info(
      'wemo $label: sending ConnectHomeNetwork (twice, '
      '100ms apart)',
    );
    try {
      final reply = await _sendWemoRequest(session, request);
      // PairingStatus is an acknowledgement, not the join result — but it is
      // the device's only word between "credentials sent" and twenty seconds
      // of polling, so it is worth having in the transcript.
      Log.adopt.debug(
        'wemo $label: first send acknowledged, '
        'PairingStatus=${reply['PairingStatus'] ?? '<absent>'}',
      );
    } catch (e) {
      Log.adopt.warning(
        'wemo $label: the first send did not get through, so '
        'no credentials landed: $e',
      );
      return const AdoptOutcome(AdoptStatus.unreachable, '');
    }
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _sendWemoRequest(session, request);
    } catch (e) {
      // The credentials already landed on the first send; the repeat is only
      // insurance. Do not let its failure mask that.
      Log.adopt.debug(
        'wemo $label: repeat send failed (non-fatal, the first '
        'one already delivered the credentials): $e',
      );
    }

    // Poll GetNetworkStatus up to the spec's 20-second floor; Rust names the
    // status code.
    final poll = Stopwatch()..start();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    // Transitions, not ticks: twenty identical "status 0" lines per variant,
    // six variants deep, is the kind of volume that hides the one line that
    // changed. `polls`/`failures` carry the rest as a single closing count.
    String? lastReported;
    var polls = 0;
    var failures = 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final String? code;
      try {
        code = (await _sendWemo(
          session,
          stateCommand: 'GetNetworkStatus',
          trace: false,
        ))['NetworkStatus'];
        polls++;
      } catch (e) {
        // A dropped setup AP is the expected shape of a successful join; keep
        // polling in case it comes back, and fall through to unconfirmed if
        // it does not.
        failures++;
        if (failures == 1) {
          Log.adopt.debug(
            'wemo $label: status poll failed at '
            '${_elapsed(poll)} — this is also what a successful join looks '
            'like, since the setup AP drops as the device hops away: $e',
          );
        }
        continue;
      }
      if (code == null) continue;
      final status = await codec.wemoNetworkStatus(code: code);
      if (code != lastReported) {
        lastReported = code;
        Log.adopt.debug(
          'wemo $label: NetworkStatus=$code (${status.name}) at '
          '${_elapsed(poll)}',
        );
      }
      switch (status) {
        case WemoJoinStatus.connected:
          Log.adopt.info(
            'wemo $label: the device reports it joined, after '
            '${_elapsed(poll)} of polling',
          );
          return const AdoptOutcome(
            AdoptStatus.joined,
            'Connected. The device is joining your Wi-Fi now.',
          );
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
    // Delivered at least once, never confirmed.
    Log.adopt.warning(
      'wemo $label: delivered, but no join in ${_elapsed(poll)} '
      '($polls poll(s) answered, $failures failed; '
      'last NetworkStatus=${lastReported ?? '<never answered>'})',
    );
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
        Log.adopt.debug(
          'wemo $command after join failed (non-fatal, '
          'SetSetupDoneStatus is absent on some firmware): $e',
        );
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
      throw AdoptException(
        friendlyErrorText(
          e,
          context: 'lifx set access point',
          log: Log.adopt,
          fallback: 'Those network details can\'t be sent to the device.',
        ),
      );
    }
    // Fire-and-forget by design: the legacy SetAccessPoint has no reply and no
    // status poll. The password is not kept anywhere.
    Log.adopt.info(
      'lifx provision: sending SetAccessPoint for '
      '"${network.ssid}" (security=$security, '
      'passphrase=${passphrase.length} chars) — fire-and-forget, the legacy '
      'protocol has no reply and no status to poll',
    );
    await lifx.send(lifxSetupBroadcast, datagram);
    return const AdoptOutcome(
      AdoptStatus.sentUnconfirmed,
      'Sent. The light will drop its setup network and join your Wi-Fi. '
      'Rejoin your home network and it should turn up in a Wi-Fi scan.',
    );
  }

  // ── Wemo SOAP helpers ──────────────────────────────────────────────────────

  /// One idempotent setup read, attempted up to [setupAttempts] times.
  ///
  /// The spec's troubleshooting table opens its catch-all entry with "genuinely
  /// try again — pywemo's own documentation lists this first. Wemo devices
  /// sometimes fail to connect and the identical sequence subsequently works."
  /// This is that, kept to the two reads it is safe for: `GetMetaInfo` and
  /// `GetApList` change nothing on the device, so re-asking cannot half-apply
  /// anything.
  ///
  /// What is NOT retried here, and why each is already covered:
  ///  * `ConnectHomeNetwork` — the credential sweep re-sends it up to six
  ///    times over, and the spec's own repeat rule sends each twice.
  ///  * `GetNetworkStatus` — the 20-second poll IS its retry loop.
  ///  * `CloseSetup` — best effort by design; its failure changes nothing.
  ///
  /// A [SoapFaultException] is never retried: the device understood the
  /// request and refused it, which no amount of asking again changes. The gap
  /// between attempts is deliberate rather than eager — Wemo firmware runs a
  /// handful of worker threads and answers a hammering by getting slower, so
  /// the spec's guidance throughout is patient timeouts over fast retries.
  Future<Map<String, String>> _setupRead(
    AdoptSession session,
    String stateCommand, {
    int? attempts,
  }) async {
    final budget = attempts ?? setupAttempts;
    for (var attempt = 1; ; attempt++) {
      try {
        return await _sendWemo(session, stateCommand: stateCommand);
      } on SoapFaultException {
        rethrow;
      } on AdoptException {
        // The device does not offer the action at all — a different answer,
        // not a flaky one.
        rethrow;
      } catch (e) {
        if (attempt >= budget) {
          Log.adopt.warning(
            'wemo $stateCommand failed on all $budget attempt(s): $e',
          );
          rethrow;
        }
        Log.adopt.warning(
          'wemo $stateCommand failed on attempt $attempt of '
          '$budget; retrying in ${setupRetryGap.inSeconds}s: $e',
        );
        await Future<void>.delayed(setupRetryGap);
      }
    }
  }

  Future<Map<String, String>> _sendWemo(
    AdoptSession session, {
    required String stateCommand,
    bool trace = true,
  }) async {
    final request = await codec.renderNetworkStateRequest(
      specYaml: session.specYaml,
      stateCommand: stateCommand,
    );
    return _sendWemoRequest(session, request, trace: trace);
  }

  /// POST one rendered request to the setup AP, tracing the exchange.
  ///
  /// Every Wemo setup step is one of these, so this is the only place that has
  /// to time and name them — and naming them is the point: a caught
  /// `TimeoutException` reported by its caller says "after 0:00:10" and
  /// nothing else, which is indistinguishable between the description fetch,
  /// GetMetaInfo, GetApList and ConnectHomeNetwork. [trace] is false for the
  /// per-second status poll, which reports its own transitions instead.
  Future<Map<String, String>> _sendWemoRequest(
    AdoptSession session,
    SoapRequestDto request, {
    bool trace = true,
  }) async {
    final description = session.description!;
    final path = description.controlPathFor(request);
    if (path == null) {
      throw AdoptException(
        'The device does not offer ${request.action} in setup mode.',
      );
    }
    // Which path was resolved, and whether it came from the device's own
    // service list or the spec's conventional fallback: the spec repeats more
    // often than any other rule that these spellings vary across firmware
    // (/upnp/control/WiFiSetup1 vs /upnp/control/wifi1), and a POST to the
    // wrong one is answered with silence, not an error.
    final resolved = description.controlUrls.containsKey(request.service)
        ? 'device'
        : 'spec';
    final call = Stopwatch()..start();
    try {
      final values = await soap.send(
        description.host,
        description.port,
        path,
        request,
        urlBase: description.urlBase,
      );
      if (trace) {
        Log.adopt.debug(
          'wemo ${request.action} -> $path ($resolved): ok in '
          '${_elapsed(call)}, returned [${values.keys.join(', ')}]',
        );
      }
      return values;
    } catch (e) {
      if (trace) {
        Log.adopt.debug(
          'wemo ${request.action} -> $path ($resolved): failed '
          'after ${_elapsed(call)}: $e',
        );
      }
      rethrow;
    }
  }
}

/// A stopwatch reading, in the one spelling every timed line in this app uses.
///
/// Was a local `toStringAsFixed(1)` here and nowhere else, which is what made
/// this the only flow in the app that could answer "how long did that take".
/// [formatElapsed] is that rendering, shared, and it reads sub-second waits in
/// milliseconds — the difference between "the device answered" and "the
/// deadline expired" is exactly what every line in this flow is asking.
String _elapsed(Stopwatch watch) => formatElapsed(watch.elapsed);

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

  /// Wemo only: the raw `GetMetaInfo` reply, read while connecting.
  ///
  /// The spec's step order puts this read before the AP list, and it is where
  /// it belongs: it is the one setup exchange whose failure cannot be worked
  /// around later — no metadata, no passphrase encryption — so finding out
  /// costs nothing here and costs a typed password and a two-minute credential
  /// sweep if it is deferred. Null when the device did not answer it (the
  /// caller retries then, properly) or on LIFX, which has no such step.
  final String? metaInfo;

  const AdoptSession._({
    required this.family,
    required this.specYaml,
    this.description,
    this.metaInfo,
  });
}
