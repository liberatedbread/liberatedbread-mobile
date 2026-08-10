// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../core/stop_signal.dart';
import '../models/network_device.dart';
import 'multicast_lock.dart';
import 'network_scan_service.dart';

/// The DNS-SD meta-query that enumerates every service type on the link.
/// Asking this instead of a fixed list is what lets the scan find a device
/// whose spec we have not written yet.
const _serviceEnumerationQuery = '_services._dns-sd._udp.local';

const _ssdpAddress = '239.255.255.250';
const _ssdpPort = 1900;

/// Parse an SSDP response into its headers, lowercased keys.
///
/// Tolerant on purpose: SSDP implementations in shipped hardware are famously
/// sloppy about line endings, header casing and trailing whitespace, and a
/// strict parser here would silently drop real devices.
Map<String, String> parseSsdpHeaders(String payload) {
  final headers = <String, String>{};
  for (final rawLine in payload.split(RegExp(r'\r\n|\n|\r'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    // The HTTP status line has no colon before its first space.
    final colon = line.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    if (key.isNotEmpty && value.isNotEmpty) headers[key] = value;
  }
  return headers;
}

/// Pull the host and port out of an SSDP `LOCATION` URL.
///
/// Returns null for anything unparseable — a device that advertises a
/// malformed location is not one we can do anything with.
({String host, int? port})? parseSsdpLocation(String? location) {
  if (location == null || location.isEmpty) return null;
  final uri = Uri.tryParse(location);
  if (uri == null || uri.host.isEmpty) return null;
  return (host: uri.host, port: uri.hasPort ? uri.port : null);
}

/// Turn an mDNS TXT record's entries into a map, lowercasing keys.
///
/// TXT entries are `key=value` strings; a bare key with no `=` is a flag, kept
/// with an empty value rather than dropped, because its presence is the signal.
Map<String, String> parseTxtRecord(Iterable<String> entries) {
  final txt = <String, String>{};
  for (final entry in entries) {
    final equals = entry.indexOf('=');
    if (equals < 0) {
      if (entry.isNotEmpty) txt[entry.toLowerCase()] = '';
      continue;
    }
    final key = entry.substring(0, equals).trim().toLowerCase();
    if (key.isNotEmpty) txt[key] = entry.substring(equals + 1);
  }
  return txt;
}

/// Strip the DNS-SD instance name off a full service instance, leaving the
/// service type: `Hue Bridge._hue._tcp.local` -> `_hue._tcp.local`.
String serviceTypeOf(String instance) {
  final match = RegExp(r'(_[^.]+\._(?:tcp|udp)\..+)$').firstMatch(instance);
  return match?.group(1) ?? instance;
}

/// The instance's own label: `Hue Bridge._hue._tcp.local` -> `Hue Bridge`.
String instanceNameOf(String instance) {
  final type = serviceTypeOf(instance);
  if (type == instance || !instance.endsWith(type)) return '';
  final name = instance.substring(0, instance.length - type.length);
  return name.endsWith('.') ? name.substring(0, name.length - 1) : name;
}

/// What one discovery transport managed to do in a scan window.
///
/// Three states rather than a bool because "the socket opened" and "anything
/// came back" are different facts, and only the second one tells a quiet
/// network apart from a blocked one.
enum TransportOutcome {
  /// Never got off the ground: the client or socket failed to start.
  failed,

  /// Started, and nothing at all arrived — not a device, not a stray packet.
  silent,

  /// Started and heard something, whether or not it became a device. A reply
  /// we could not parse still proves traffic reaches us.
  heard,
}

/// Decide what a finished scan means, or null when it means nothing is wrong.
///
/// Pure, so the rule can be tested without sockets, a network, or a platform.
///
/// The distinction that matters is between a network with nothing on it and a
/// network whose replies are dropped before they reach us. On iOS and macOS a
/// denied local-network permission is invisible from in here: the sockets bind,
/// the queries go out, and the answers are filtered silently. So silence on
/// those platforms earns a message that names that possibility and points at
/// Settings. Silence anywhere else is just an empty network and gets the
/// ordinary empty state — Android's multicast filtering is handled by holding a
/// multicast lock, not by guessing after the fact.
///
/// Deliberately not keyed off how many devices were found: a network can carry
/// plenty of mDNS traffic and no device we have a spec for, and calling that a
/// permission problem would be a confident lie in the other direction.
UserFacingException? scanFailureFor({
  required List<TransportOutcome> outcomes,
  required bool isApplePlatform,
}) {
  if (outcomes.every((o) => o == TransportOutcome.failed)) {
    // Neither transport started: a real, platform-independent failure — no
    // interface, no multicast route, no network.
    return const NetworkUnavailableException();
  }
  if (outcomes.any((o) => o == TransportOutcome.heard)) return null;
  return isApplePlatform ? const LocalNetworkDeniedException() : null;
}

/// Coalesces sightings so a device answering on several service types, or on
/// both mDNS and SSDP, is one row rather than four.
///
/// Mirrors `ScanResultCoalescer` on the BLE side, including its contract:
/// returns the merged device when something about it changed, and null when
/// this sighting added nothing.
class NetworkScanCoalescer {
  final Map<String, NetworkDevice> _seen = {};

  int get deviceCount => _seen.length;

  NetworkDevice? next(NetworkDevice sighting) {
    final previous = _seen[sighting.host];
    final merged = previous == null ? sighting : previous.mergedWith(sighting);
    // Store first, always. `hasSameIdentity` decides whether the ROW needs
    // redrawing; it deliberately ignores `sources` and `server`, which are not
    // identity. Returning early without storing threw those away permanently:
    // a host already known over mDNS that then answered SSDP kept showing
    // "mDNS" forever, because the merge carrying the second source was
    // discarded rather than remembered.
    final unchanged = previous != null && previous.hasSameIdentity(merged);
    _seen[sighting.host] = merged;
    return unchanged ? null : merged;
  }
}

/// Real local-network discovery: DNS-SD over mDNS, plus SSDP.
///
/// Both are run because they do not overlap. Modern local-first hardware
/// announces itself over mDNS and nothing else; Wemo and older Hue bridges are
/// SSDP-only. Running one would silently miss half the catalogue.
class RealNetworkScanService implements NetworkScanService {
  /// Held for the duration of a scan so Android's Wi-Fi driver stops filtering
  /// the multicast replies both transports depend on. Injectable so a test can
  /// assert the scan takes it and gives it back.
  final MulticastLock multicastLock;

  RealNetworkScanService({MulticastLock? multicastLock})
      : multicastLock = multicastLock ?? MulticastLock();

  /// The scan currently entitled to the lock, or null between scans.
  ///
  /// Only ever compared by identity — a finishing scan checks whether it is
  /// still this one before releasing anything shared.
  _ScanSession? _session;

  @override
  Stream<NetworkDevice> scan({
    Duration timeout = const Duration(seconds: 8),
  }) {
    final controller = StreamController<NetworkDevice>();
    final coalescer = NetworkScanCoalescer();
    // Everything a scan has to be able to stop lives on the session, not on
    // the service. It used to live here, and one instance is shared through
    // `networkScanServiceProvider`: cancel a scan and start another, and the
    // first is still parked in _runMdns's post-enumeration delay (four seconds
    // at the default timeout). When it comes back its `finally` tore down
    // whatever it found on the fields — the *second* scan's mDNS client and
    // SSDP socket, its stopped flag, and the multicast lock it had just taken.
    // That scan then reported silent/silent, which on iOS and macOS is
    // rendered as "Local Network access is off" to a user whose permission was
    // never the problem.
    final session = _ScanSession();
    _session = session;

    void emit(NetworkDevice device) {
      if (controller.isClosed) return;
      final changed = coalescer.next(device);
      if (changed != null) controller.add(changed);
    }

    () async {
      try {
        // Before either transport starts, and released in the finally below:
        // without it Android delivers neither mDNS nor SSDP replies, so taking
        // it after the queries go out would be too late for the answers.
        await multicastLock.acquire();
        // Both halves run concurrently and are allowed to fail independently:
        // a platform that blocks one (iOS multicast entitlements, a network
        // with IGMP snooping) should still return what the other found.
        final outcomes = await Future.wait([
          _runMdns(session, emit, timeout).catchError((Object e) {
            Log.net.warning('mDNS discovery failed', error: e);
            return TransportOutcome.failed;
          }),
          _runSsdp(session, emit, timeout).catchError((Object e) {
            Log.net.warning('SSDP discovery failed', error: e);
            return TransportOutcome.failed;
          }),
        ]);

        final failure = scanFailureFor(
          outcomes: outcomes,
          isApplePlatform: Platform.isIOS || Platform.isMacOS,
        );
        if (failure != null) controller.addError(failure);
        Log.net.info('network scan finished: '
            '${coalescer.deviceCount} device(s)');
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      } finally {
        await _end(session);
        if (!controller.isClosed) await controller.close();
      }
    }();

    controller.onCancel = () => _end(session);
    return controller.stream;
  }

  /// Enumerate service types, then resolve each instance.
  ///
  /// Reports [TransportOutcome.heard] as soon as one record arrives, from
  /// either the enumeration or any resolution — the question the caller is
  /// asking is whether multicast reaches this app at all, and one record
  /// answers it. Records that resolve to nothing usable still count.
  Future<TransportOutcome> _runMdns(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
  ) async {
    final client = MDnsClient();
    await client.start();
    session.mdns = client;
    var heard = false;
    final resolving = <String>{};
    // `timeout` is the budget for the whole mDNS half, split between its two
    // phases: enumerate the link's service types, then resolve the instances
    // behind them. Both used to be given the full `timeout` and run back to
    // back, so an 8-second scan took twelve — the enumeration ran its window
    // out (it only closes early if every responder falls silent), and the
    // grace period for the resolutions was added on top of it.
    final phase = timeout ~/ 2;
    // `Stream.timeout` is an INACTIVITY timeout: every event resets it. On a
    // link where responders keep answering the meta-query inside the window —
    // which is what a busy network looks like — it never fires, the enumeration
    // never closes, `Future.wait` below never completes, and the scan stream
    // stays open forever with the spinner up and the button disabled. The
    // SSDP half has always had an absolute deadline for this reason; this one
    // did not, and the phase comment above claimed a budget it was not
    // keeping. Keep both: inactivity ends a quiet scan early, the deadline
    // bounds a chatty one.
    final deadline = DateTime.now().add(phase);
    try {
      await for (final PtrResourceRecord type in client
          .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(_serviceEnumerationQuery))
          .timeout(phase, onTimeout: (sink) => sink.close())) {
        heard = true;
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        // Once per type, not once per announcement. The meta-query is answered
        // by every responder on the link, so a common type like _http._tcp
        // arrives once per device; without this each arrival started another
        // full resolution of the same type, and multicast_dns fans every
        // incoming record to every pending lookup — so D duplicates cost D
        // queries and D^2 record deliveries.
        if (!resolving.add(type.domainName)) continue;
        // Fire the per-type resolution off rather than awaiting it: a slow or
        // unanswered service type must not hold up every other one.
        unawaited(
            _resolveServiceType(session, client, type.domainName, emit, phase)
                .catchError((Object e) {
          Log.net.debug('mDNS resolve failed for ${type.domainName}: $e');
        }));
      }
      // Give the fired-off resolutions the other half of the window — but wake
      // early if the scan is stopped.
      //
      // Unconditionally sleeping here made `stopScan()` a lie: the transports
      // shut down at once, but this half stayed parked, so `Future.wait` below
      // did not complete and the app-facing stream did not CLOSE for up to half
      // the scan window (thirty seconds at a one-minute timeout). A caller that
      // waits for the stream to end before re-enabling its button — which is
      // what "stop scanning" looks like from the UI — waits that long for a
      // scan that already stopped.
      await session.sleepUnlessStopped(phase);
      // No separate "heard during resolve" state: a resolution only ever
      // starts after the enumeration loop has already received a record, so
      // `heard` is necessarily true by then.
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      client.stop();
      session.mdns = null;
    }
  }

  Future<void> _resolveServiceType(
    _ScanSession session,
    MDnsClient client,
    String serviceType,
    void Function(NetworkDevice) emit,
    Duration timeout,
  ) async {
    await for (final PtrResourceRecord instance in client
        .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(serviceType))
        .timeout(timeout, onTimeout: (sink) => sink.close())) {
      if (session.stopped) return;
      // TXT and SRV are independent queries; run them together. A device that
      // publishes no TXT record leaves that stream open until its timeout, and
      // awaiting it before even asking for SRV used to spend the whole
      // resolution window on the absent half. Emission still waits for both,
      // so a device is emitted once, with everything it said.
      final txt = <String, String>{};
      final srvRecords = <SrvResourceRecord>[];
      await Future.wait([
        () async {
          await for (final TxtResourceRecord record in client
              .lookup<TxtResourceRecord>(
                  ResourceRecordQuery.text(instance.domainName))
              .timeout(timeout, onTimeout: (sink) => sink.close())) {
            txt.addAll(parseTxtRecord(record.text.split(RegExp(r'[\r\n]+'))));
          }
        }(),
        () async {
          await for (final SrvResourceRecord srv in client
              .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(instance.domainName))
              .timeout(timeout, onTimeout: (sink) => sink.close())) {
            if (session.stopped) return;
            srvRecords.add(srv);
          }
        }(),
      ]);

      for (final srv in srvRecords) {
        if (session.stopped) return;
        await for (final IPAddressResourceRecord address in client
            .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target))
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          emit(NetworkDevice(
            host: address.address.address,
            name: instanceNameOf(instance.domainName),
            hostname: srv.target,
            port: srv.port,
            serviceTypes: [serviceTypeOf(instance.domainName)],
            txt: txt,
            sources: const {NetworkDiscoverySource.mdns},
            discoveredAt: DateTime.now(),
          ));
        }
      }
    }
  }

  /// Multicast an M-SEARCH and collect the unicast replies.
  ///
  /// Any datagram counts as [TransportOutcome.heard], including one whose
  /// headers we cannot use: the caller is asking whether replies reach this app
  /// at all, and an unparseable reply still answers that yes.
  Future<TransportOutcome> _runSsdp(
    _ScanSession session,
    void Function(NetworkDevice) emit,
    Duration timeout,
  ) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
        reuseAddress: true);
    session.ssdpSocket = socket;
    socket.broadcastEnabled = true;
    var heard = false;
    try {
      // MX is the maximum random delay a device waits before replying; it
      // spreads responses out to avoid a storm, so the listen window has to be
      // at least MX seconds or slow-answering devices are missed.
      const request = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 3\r\n'
          'ST: ssdp:all\r\n'
          '\r\n';
      final bytes = request.codeUnits;
      final target = InternetAddress(_ssdpAddress);
      // Sent more than once: SSDP rides on UDP, and a dropped M-SEARCH means a
      // device that is simply never heard from.
      for (var attempt = 0; attempt < 2; attempt++) {
        socket.send(bytes, target, _ssdpPort);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final deadline = DateTime.now().add(timeout);
      await for (final event in socket.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (session.stopped || DateTime.now().isAfter(deadline)) break;
        if (event != RawSocketEvent.read) continue;
        final datagram = socket.receive();
        if (datagram == null) continue;
        heard = true;
        final headers = parseSsdpHeaders(String.fromCharCodes(datagram.data));
        final location = parseSsdpLocation(headers['location']);
        // Prefer the LOCATION host: a device behind a proxy or on a second
        // interface answers from an address its own service does not live on.
        final host = location?.host ?? datagram.address.address;
        final searchTarget = headers['st'] ?? headers['nt'];
        emit(NetworkDevice(
          host: host,
          name: '',
          port: location?.port,
          ssdpTargets: [if (searchTarget != null) searchTarget],
          server: headers['server'],
          sources: const {NetworkDiscoverySource.ssdp},
          discoveredAt: DateTime.now(),
        ));
      }
      return heard ? TransportOutcome.heard : TransportOutcome.silent;
    } finally {
      socket.close();
      session.ssdpSocket = null;
    }
  }

  /// End [session]: stop its transports, and give the multicast lock back if
  /// it is still the session holding it.
  ///
  /// Every path out of a scan runs this — normal finish, cancel, error, and
  /// [stopScan] — which is what keeps the lock from outliving the scan that
  /// took it. Holding it costs battery for the whole device, not just this app.
  ///
  /// The identity check is what stops a late finisher from disarming a live
  /// scan: the lock is a single platform-wide flag with no reference counting,
  /// so releasing one an overlapping scan is relying on silences it outright.
  /// Whichever session is current took the lock last and will release it when
  /// its own turn comes.
  Future<void> _end(_ScanSession session) async {
    session.stop();
    if (!identical(_session, session)) return;
    _session = null;
    await multicastLock.release();
  }

  @override
  Future<void> stopScan() async {
    final session = _session;
    if (session != null) await _end(session);
  }
}

/// One scan's disposable state.
///
/// Exists so that stopping a scan stops *that* scan. These were fields on the
/// service, and `networkScanServiceProvider` hands out a single shared
/// instance, so an overlapping pair fought over them.
class _ScanSession {
  MDnsClient? mdns;
  RawDatagramSocket? ssdpSocket;

  /// The interruptible-wait mechanism, shared with the mock service: a wait
  /// races [whenStopped] rather than only checking a flag at its ends — a
  /// transport parked in a delay never looks at a flag.
  final StopSignal _stop = StopSignal();

  bool get stopped => _stop.stopped;

  /// Completes when [stop] is called, so a wait can be cut short.
  Future<void> get whenStopped => _stop.whenStopped;

  /// Waits [duration], or until [stop] is called. True when stopped.
  Future<bool> sleepUnlessStopped(Duration duration) => _stop.sleep(duration);

  void stop() {
    // Idempotent (StopSignal guards the complete): every path out of a scan
    // calls this, and cancel-then-finish calls it twice.
    _stop.stop();
    mdns?.stop();
    mdns = null;
    ssdpSocket?.close();
    ssdpSocket = null;
  }
}
