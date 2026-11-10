// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../core/constants.dart';
import '../core/error_text.dart';
import '../core/hex.dart';
import '../core/log.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../src/rust/api/mpid_api.dart' as rust;
import 'ble_service.dart';

export '../src/rust/api/mpid_api.dart' show MpidChannelsDto, MpidSessionDto;

/// The crypto and framing of a Mattel MPID session, which all live in Rust
/// (`protocol::mattel_mpid`). An interface so the session layer can be tested
/// against a device that is not a P-256 key.
abstract interface class MpidCodec {
  rust.MpidChannelsDto channels();

  /// Agree a session with the unit whose factory [token] was just read.
  Future<rust.MpidSessionDto> startSession(List<int> token);

  /// Frame number [seq] around a command [body]. Throws for a body the spec
  /// does not declare.
  Uint8List seal(rust.MpidSessionDto session, int seq, List<int> body);

  /// One notification decrypted, or a throw for anything that is not a whole
  /// frame under this session.
  Uint8List open(rust.MpidSessionDto session, List<int> frame);
}

class RustMpidCodec implements MpidCodec {
  const RustMpidCodec();

  @override
  rust.MpidChannelsDto channels() => rust.mpidChannels();

  @override
  Future<rust.MpidSessionDto> startSession(List<int> token) =>
      rust.mpidStartSession(token: token);

  @override
  Uint8List seal(rust.MpidSessionDto session, int seq, List<int> body) =>
      rust.mpidSeal(
        key: session.key,
        appNonce: session.appNonce,
        deviceSalt: session.deviceSalt,
        seq: seq,
        body: body,
      );

  @override
  Uint8List open(rust.MpidSessionDto session, List<int> frame) => rust.mpidOpen(
    key: session.key,
    appNonce: session.appNonce,
    deviceSalt: session.deviceSalt,
    frame: frame,
  );
}

/// A Lumalou (or another MPID unit) could not be talked to.
class MpidSessionException implements UserFacingException {
  @override
  final String message;

  const MpidSessionException(this.message);

  @override
  String toString() => message;
}

/// The [BleService] every screen, card and group run uses, with the Mattel
/// MPID session underneath the MPID service.
///
/// A Lumalou's spec states its commands as the decrypted BODY of a frame, and
/// Rust renders exactly that body. A body is not what the unit hears: each
/// write is a frame sealed under a key agreed on this connection, numbered by
/// a counter the client keeps, and each notification is a frame to open. A
/// stateless encoder has neither, so the session lives here, with the link,
/// and the rest of the app writes and subscribes as it would to any device —
/// which is what lets the generic cards and group ops drive the light at all.
///
/// On the MPID service:
///
/// - a write to the command characteristic is sealed, opening the session
///   first if this link has none: subscribe, read the factory token, agree a
///   key in Rust, write the session characteristic, then ENABLE_RX and one
///   REQUEST_GLOBAL_STATE, at the spec's pacing. The session counts as open
///   only once a frame from the unit decrypts under it; a unit that answers
///   nothing, or answers what does not decrypt, fails the open.
/// - a subscription to the notify characteristic opens the session too, and
///   hears decrypted bodies. Frames that do not open are dropped and logged.
/// - writes to the token and session characteristics are refused: the layer
///   owns them, and a stray write would desynchronise the session.
///
/// Anywhere on a unit that carries the MPID service, the Nordic DFU service
/// is refused outright (the spec reports a wrong write bricks the unit).
///
/// Every other service and device passes straight through to [inner].
class MattelMpidBleService
    implements
        BleService,
        BleAuthorizationWatcher,
        BleConnectCanceller,
        BlePacketWriter {
  final BleService inner;
  final MpidCodec codec;

  /// Bound on each GATT step of the open.
  final Duration ioTimeout;

  /// How long the unit gets to send its first frame once ENABLE_RX and the
  /// state request are out. It streams the clock about once a second.
  final Duration confirmTimeout;

  /// Stands in for `Future.delayed`, so tests run the spec's pacing without
  /// the wall clock.
  final Future<void> Function(Duration) _sleep;

  /// The clock the pacing is measured on.
  final DateTime Function() _now;

  late final rust.MpidChannelsDto channels = codec.channels();

  final _links = <String, _MpidLink>{};
  final _mpidDevices = <String>{};

  MattelMpidBleService(
    this.inner, {
    this.codec = const RustMpidCodec(),
    this.ioTimeout = const Duration(seconds: 8),
    this.confirmTimeout = const Duration(seconds: 4),
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  /// Which traffic is the session's, decided without a call into Rust: every
  /// write and subscription in the app passes this check, and only the MPID
  /// service's own go on to need the codec. A test holds these to Rust's.
  static const mpidServiceUuid = '4cea0001-c678-4202-b5d3-712dbb5e5b14';
  static const dfuServiceUuid = '00001530-1212-efde-1523-785feabcd123';

  bool _isMpid(String serviceUuid) =>
      normalizeUuid(serviceUuid) == mpidServiceUuid;

  bool _is(String charUuid, String declared) =>
      normalizeUuid(charUuid) == normalizeUuid(declared);

  _MpidLink _link(String deviceId, String serviceUuid) => _links.putIfAbsent(
    deviceId,
    () => _MpidLink(this, deviceId, serviceUuid),
  );

  /// Whether [deviceId] holds an open session right now. For tests and logs.
  bool hasSession(String deviceId) => _links[deviceId]?._session != null;

  // ── The MPID service ────────────────────────────────────────────────────

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    _refuseUnwritable(deviceId, serviceUuid, charUuid);
    if (_isMpid(serviceUuid) && _is(charUuid, channels.txUuid)) {
      return _link(deviceId, serviceUuid).send(value);
    }
    return inner.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
  }

  @override
  Future<void> writeCharacteristicPackets(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<List<int>> packets, {
    void Function()? onPacketWritten,
  }) async {
    _refuseUnwritable(deviceId, serviceUuid, charUuid);
    if (_isMpid(serviceUuid) && _is(charUuid, channels.txUuid)) {
      final link = _link(deviceId, serviceUuid);
      for (final packet in packets) {
        await link.send(packet);
        onPacketWritten?.call();
      }
      return;
    }
    final writer = inner;
    if (writer is BlePacketWriter) {
      return writer.writeCharacteristicPackets(
        deviceId,
        serviceUuid,
        charUuid,
        packets,
        onPacketWritten: onPacketWritten,
      );
    }
    for (final packet in packets) {
      await inner.writeCharacteristic(deviceId, serviceUuid, charUuid, packet);
      onPacketWritten?.call();
    }
  }

  void _refuseUnwritable(String deviceId, String serviceUuid, String charUuid) {
    if (_mpidDevices.contains(deviceId) &&
        normalizeUuid(serviceUuid) == dfuServiceUuid) {
      throw const MpidSessionException(
        "This unit's firmware-update service is never written to: a wrong "
        'write can leave it unable to start.',
      );
    }
    if (_isMpid(serviceUuid) &&
        (_is(charUuid, channels.sessionUuid) ||
            _is(charUuid, channels.tokenUuid))) {
      throw const MpidSessionException(
        'The session characteristics belong to the encrypted session; '
        'send a command instead.',
      );
    }
  }

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    if (_isMpid(serviceUuid) && _is(charUuid, channels.rxUuid)) {
      return _link(deviceId, serviceUuid).bodies();
    }
    return inner.subscribeCharacteristic(deviceId, serviceUuid, charUuid);
  }

  @override
  List<List<int>> recentNotifications(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    if (_isMpid(serviceUuid) && _is(charUuid, channels.rxUuid)) {
      return _links[deviceId]?.recent.toList() ?? const [];
    }
    return inner.recentNotifications(deviceId, serviceUuid, charUuid);
  }

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    final services = await inner.discoverServices(deviceId);
    if (services.any((s) => _isMpid(s.uuid))) _mpidDevices.add(deviceId);
    return services;
  }

  // ── Everything else is the inner service's ──────────────────────────────

  @override
  Future<bool> requestPermissions() => inner.requestPermissions();

  @override
  Stream<IoTDevice> scan({
    Duration? timeout = const Duration(
      seconds: AppConstants.defaultScanDuration,
    ),
    ScanIntensity intensity = ScanIntensity.active,
  }) => inner.scan(timeout: timeout, intensity: intensity);

  @override
  Future<void> stopScan() => inner.stopScan();

  @override
  Stream<bool> adapterReady() => inner.adapterReady();

  @override
  Future<void> connect(String deviceId) => inner.connect(deviceId);

  @override
  Future<void> disconnect(String deviceId) => inner.disconnect(deviceId);

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      inner.connectionState(deviceId);

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) => inner.readCharacteristic(deviceId, serviceUuid, charUuid);

  @override
  Future<int> mtu(String deviceId) => inner.mtu(deviceId);

  @override
  Future<int> readRssi(String deviceId) => inner.readRssi(deviceId);

  @override
  Stream<bool> adapterUnauthorized() {
    final watcher = inner;
    return watcher is BleAuthorizationWatcher
        ? watcher.adapterUnauthorized()
        : const Stream.empty();
  }

  @override
  Future<bool> isAuthorized() async {
    final watcher = inner;
    return watcher is BleAuthorizationWatcher ? watcher.isAuthorized() : true;
  }

  @override
  Future<void> cancelConnect(String deviceId) async {
    final canceller = inner;
    if (canceller is BleConnectCanceller) {
      await canceller.cancelConnect(deviceId);
    }
  }
}

/// One device's session: the agreed values, the frame counter, the write
/// queue, and the decrypted notification stream.
class _MpidLink {
  final MattelMpidBleService layer;
  final String deviceId;
  final String serviceUuid;

  _MpidLink(this.layer, this.deviceId, this.serviceUuid);

  rust.MpidSessionDto? _session;
  Future<void>? _opening;
  int _seq = 0;
  DateTime? _lastWrite;
  Future<void> _queue = Future.value();

  StreamSubscription<List<int>>? _raw;
  StreamSubscription<BleConnectionState>? _state;
  final _out = StreamController<List<int>>.broadcast();
  Completer<void>? _firstFrame;

  /// The last few decrypted bodies, for [BleService.recentNotifications].
  final recent = ListQueue<List<int>>();
  static const _recentCap = 16;

  /// The last GLOBAL_STATE body, replayed to each new subscriber: a card that
  /// mounts after the connect-time state request was answered still gets
  /// the state rather than waiting for the unit to change.
  List<int>? _lastState;

  rust.MpidChannelsDto get _channels => layer.channels;
  BleService get _ble => layer.inner;

  Stream<List<int>> bodies() {
    // Closed by its listener's cancel, like any single-subscription stream
    // handed out: the subscriber owns it.
    // ignore: close_sinks
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? forward;
    controller = StreamController<List<int>>(
      onListen: () {
        forward = _out.stream.listen(
          controller.add,
          onError: controller.addError,
        );
        final last = _lastState;
        if (last != null) controller.add(last);
        ensureOpen().catchError((Object e, StackTrace st) {
          if (!controller.isClosed) controller.addError(e, st);
        });
      },
      onCancel: () => forward?.cancel(),
    );
    return controller.stream;
  }

  Future<void> ensureOpen() {
    if (_session != null) return Future.value();
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<void> _open() async {
    final channels = _channels;
    final io = layer.ioTimeout;
    try {
      _firstFrame = Completer<void>();
      final notifications = _ble.subscribeCharacteristic(
        deviceId,
        serviceUuid,
        channels.rxUuid,
      );
      _raw = notifications.listen(
        _onFrame,
        onError: (Object e) {
          Log.ble.debug('MPID notifications on $deviceId failed: $e');
        },
      );
      if (notifications is BleReadyNotificationStream) {
        await notifications.ready.timeout(io);
      }
      _state ??= _ble.connectionState(deviceId).listen((state) {
        if (state == BleConnectionState.disconnected) _reset();
      });

      final token = await _ble
          .readCharacteristic(deviceId, serviceUuid, channels.tokenUuid)
          .timeout(io);
      final rust.MpidSessionDto session;
      try {
        session = await layer.codec.startSession(token);
      } catch (e) {
        Log.ble.warning('MPID token from $deviceId refused: $e');
        throw const MpidSessionException(
          'The unit did not hand over a factory token this app can use, so '
          'no encrypted session could be opened.',
        );
      }
      await _ble
          .writeCharacteristic(
            deviceId,
            serviceUuid,
            channels.sessionUuid,
            session.sessionWrite,
          )
          .timeout(io);
      await layer._sleep(Duration(milliseconds: channels.afterSessionWriteMs));

      _session = session;
      _seq = 0;
      await _writeSealed(channels.enableRx);
      await layer._sleep(Duration(milliseconds: channels.afterEnableRxMs));
      await _writeSealed(channels.requestGlobalState);

      try {
        await _firstFrame!.future.timeout(layer.confirmTimeout);
      } on TimeoutException {
        throw const MpidSessionException(
          'The unit did not answer the encrypted session. Another phone may '
          'be connected to it, or it may not be a Lumalou.',
        );
      }
      Log.ble.info('MPID session open on $deviceId');
    } catch (e) {
      _reset();
      if (e is TimeoutException) {
        throw const MpidSessionException(
          'The unit stopped answering while the encrypted session was being '
          'opened.',
        );
      }
      rethrow;
    }
  }

  void _onFrame(List<int> frame) {
    final session = _session;
    if (session == null) return;
    final Uint8List body;
    try {
      body = layer.codec.open(session, frame);
    } catch (e) {
      Log.ble.debug(
        'dropped an MPID frame from $deviceId that did not open: $e',
      );
      return;
    }
    final first = _firstFrame;
    if (first != null && !first.isCompleted) first.complete();
    if (_isGlobalState(body)) _lastState = body;
    recent.addLast(body);
    while (recent.length > _recentCap) {
      recent.removeFirst();
    }
    _out.add(body);
  }

  /// `01 50 fe n 02 ...`: an application response whose opcode is
  /// GLOBAL_STATE (the spec's `format_match`).
  static bool _isGlobalState(List<int> body) =>
      body.length > 4 &&
      body[0] == 0x01 &&
      body[1] == 0x50 &&
      body[2] == 0xFE &&
      body[4] == 0x02;

  /// Seal and write one command body, after the session is open, one at a
  /// time and no closer together than the spec's pacing.
  Future<void> send(List<int> body) {
    final done = _queue.catchError((Object _) {}).then((_) async {
      await ensureOpen();
      await _writeSealed(body);
    });
    _queue = done;
    return done;
  }

  Future<void> _writeSealed(List<int> body) async {
    final session = _session;
    if (session == null) {
      throw const MpidSessionException('The encrypted session is not open.');
    }
    final gap = Duration(milliseconds: _channels.betweenCommandsMs);
    final last = _lastWrite;
    if (last != null) {
      final waited = layer._now().difference(last);
      if (waited < gap) await layer._sleep(gap - waited);
    }
    final Uint8List frame;
    try {
      frame = layer.codec.seal(session, _seq + 1, body);
    } catch (e) {
      Log.ble.warning('refused an MPID body for $deviceId: $e');
      throw const MpidSessionException(
        'That is not a command this unit is known to take, so it was not '
        'sent.',
      );
    }
    _seq++;
    _lastWrite = layer._now();
    await _ble
        .writeCharacteristic(deviceId, serviceUuid, _channels.txUuid, frame)
        .timeout(layer.ioTimeout);
  }

  /// Forget the session: the link it was agreed on is gone (or never came
  /// up), and the next use agrees a new one.
  void _reset() {
    _session = null;
    _lastState = null;
    _lastWrite = null;
    _seq = 0;
    unawaited(_raw?.cancel());
    _raw = null;
    unawaited(_state?.cancel());
    _state = null;
    recent.clear();
  }
}
