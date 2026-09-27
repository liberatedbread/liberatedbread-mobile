// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A flutter_blue_plus backend that drives peripherals over raw ATT bearers
// (att_channel.dart) instead of through a platform Bluetooth stack.
//
// WHERE IT SITS, AND WHY THERE
//
// flutter_blue_plus is federated: every call it makes goes through
// FlutterBluePlusPlatform.instance and every answer comes back as an event on
// one of that instance's streams. This class IS such an instance. On Linux
// the router (direct_att_router.dart) hands it the devices BlueZ cannot
// enumerate and keeps BlueZ for everything else, so from flutter_blue_plus
// upward — RealBleService's claims, notify shares, retries, pairing and
// write-type rules, every screen — the code that drives the device is the
// code that drives it on an iPhone. Only the transport underneath differs.
//
// That position fixes the contract. flutter_blue_plus correlates each reply
// by (remoteId, primaryServiceUuid, serviceUuid, characteristicUuid,
// instanceId[, descriptorUuid]) and starts its own timeout only after the
// platform call RETURNS; it holds a process-wide lock across the call; it
// binds to the instance's streams once for the life of the process. So:
//
// - GATT operations are blocking: the ATT exchange completes, the correlated
//   event is emitted, then the call returns — as flutter_blue_plus_linux does
//   over D-Bus. A late reply can then never satisfy the next request.
// - connect returns at once and reports the link on the stream later, as the
//   iOS and Android plugins do, so flutter_blue_plus's timeout and its
//   cancel-by-disconnect both work.
// - Streams are created once, never closed, never errored.
// - Errors come out in the shapes RealBleService already classifies on every
//   platform: an ATT Error Response carries its ATT code (0x05/0x08/0x0F read
//   as "pair first"), a peer that never answers a read or write is
//   flutter_blue_plus's own timeout ("the device did not answer"), a link
//   that goes away is a disconnect (flutter_blue_plus's deviceIsDisconnected).
// - The discovery table looks like the one BlueZ and CoreBluetooth publish:
//   primary services only, Generic Access / Generic Attribute hidden,
//   same-UUID characteristics numbered by instanceId, CCCDs listed so
//   `isNotifying` works.
//
// Nothing here knows about any particular device.

import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart'
    show ErrorPlatform, FbpErrorCode, FlutterBluePlusException;
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import '../../core/log.dart';
import 'att_channel.dart';
import 'att_client.dart';
import 'att_pdu.dart';
import 'direct_att_registry.dart';

/// Whether [address] is an LE random address (true) or public (false).
typedef AddressTypeResolver = Future<bool> Function(String address);

/// Called when a connect keeps failing with EBUSY — the kernel refusing a
/// second ATT channel on a link bluetoothd already holds one on. The router
/// answers it by asking BlueZ to let the link go.
typedef BusyLinkHandler = Future<void> Function(String deviceId);

enum _LinkState { connecting, connected, disconnecting, closed }

/// One characteristic as flutter_blue_plus addresses it.
class _Char {
  final Guid serviceUuid;
  final Guid characteristicUuid;
  final int instanceId;
  final AttCharacteristic att;
  const _Char(
    this.serviceUuid,
    this.characteristicUuid,
    this.instanceId,
    this.att,
  );
}

/// A walked GATT table, indexed the ways requests and events need it.
class _Table {
  /// Every service walked, each with its characteristics as
  /// flutter_blue_plus names them, in handle order.
  final List<(AttService, List<_Char>)> services = [];
  final Map<String, _Char> _byKey = {};
  final Map<int, _Char> byValueHandle = {};
  int? serviceChangedHandle;

  _Table(List<AttService> walked) {
    final serviceChanged = uuid16ToString(GattType.serviceChanged);
    for (final service in walked) {
      final serviceUuid = Guid(service.uuid);
      final seen = <String, int>{};
      final chars = <_Char>[];
      for (final char in service.characteristics) {
        if (char.uuid == serviceChanged) {
          serviceChangedHandle ??= char.valueHandle;
        }
        // The Linux and iOS plugins' scheme: the index among same-UUID
        // characteristics of the service. Keeping it means a device's
        // characteristics have the same names whichever path serves it.
        final instanceId = seen[char.uuid] ?? 0;
        seen[char.uuid] = instanceId + 1;
        final entry = _Char(serviceUuid, Guid(char.uuid), instanceId, char);
        chars.add(entry);
        // Two services with one UUID cannot be told apart by
        // flutter_blue_plus on any platform; like CoreBluetooth, the first
        // one answers to the name.
        _byKey.putIfAbsent(
          _key(serviceUuid, entry.characteristicUuid, instanceId),
          () => entry,
        );
        byValueHandle[char.valueHandle] = entry;
      }
      services.add((service, chars));
    }
  }

  static String _key(Guid service, Guid characteristic, int instanceId) =>
      '${service.str128}|${characteristic.str128}|$instanceId';

  _Char? find(Guid service, Guid characteristic, int instanceId) =>
      _byKey[_key(service, characteristic, instanceId)];

  static final Set<String> _hidden = {
    uuid16ToString(GattType.genericAccess),
    uuid16ToString(GattType.genericAttribute),
  };

  /// The services flutter_blue_plus is shown: the table minus the two the
  /// stack itself owns. BlueZ keeps Generic Access and Generic Attribute to
  /// itself and CoreBluetooth hides them too, so an app never sees them on
  /// the platforms it is written against; the router also reads an empty
  /// result here as "nothing an app could use".
  List<BmBluetoothService> toBm(DeviceIdentifier remoteId) => [
    for (final (service, chars) in services)
      if (!_hidden.contains(service.uuid))
        BmBluetoothService(
          remoteId: remoteId,
          primaryServiceUuid: null,
          serviceUuid: Guid(service.uuid),
          characteristics: [
            for (final c in chars)
              BmBluetoothCharacteristic(
                remoteId: remoteId,
                primaryServiceUuid: null,
                serviceUuid: c.serviceUuid,
                characteristicUuid: c.characteristicUuid,
                instanceId: c.instanceId,
                descriptors: [
                  for (final d in c.att.descriptors)
                    BmBluetoothDescriptor(
                      remoteId: remoteId,
                      primaryServiceUuid: null,
                      serviceUuid: c.serviceUuid,
                      characteristicUuid: c.characteristicUuid,
                      // flutter_blue_plus finds a characteristic's CCCD by
                      // the CHARACTERISTIC's instanceId (isNotifying).
                      instanceId: c.instanceId,
                      descriptorUuid: Guid(d.uuid),
                    ),
                ],
                properties: _properties(c.att.properties),
              ),
          ],
        ),
  ];

  static BmCharacteristicProperties _properties(int p) =>
      BmCharacteristicProperties(
        broadcast: p & 0x01 != 0,
        read: p & GattProperty.read != 0,
        writeWithoutResponse: p & GattProperty.writeWithoutResponse != 0,
        write: p & GattProperty.write != 0,
        notify: p & GattProperty.notify != 0,
        indicate: p & GattProperty.indicate != 0,
        authenticatedSignedWrites: p & 0x40 != 0,
        extendedProperties: p & 0x80 != 0,
        notifyEncryptionRequired: false,
        indicateEncryptionRequired: false,
      );
}

class _Link {
  /// The spelling flutter_blue_plus used for this device, echoed on every
  /// event: its DeviceIdentifier hashes case-sensitively.
  final DeviceIdentifier remoteId;

  /// Whether flutter_blue_plus must be told when the link comes up. False
  /// for a hand-over, where it already believes the device is connected.
  bool announce;

  _LinkState state = _LinkState.connecting;
  final Completer<void> cancel = Completer<void>();
  final Completer<bool> opened = Completer<bool>();

  /// Completes once the link's end has been reported (or it ended without
  /// needing a report). See [DirectAttPlatform._afterLinkLoss].
  final Completer<void> ended = Completer<void>();
  AttChannel? channel;
  AttClient? client;
  _Table? table;
  Future<_Table>? walking;
  bool closedLocally = false;
  // Cancelled in _close; the lint only sees cancels in the subscribing
  // function.
  // ignore: cancel_subscriptions
  StreamSubscription<AttValueEvent>? values;
  // ignore: cancel_subscriptions
  StreamSubscription<int>? mtus;

  _Link(this.remoteId, {required this.announce});
}

/// A lookup that found nothing flutter_blue_plus asked for.
class _NotFound implements Exception {
  final String message;
  const _NotFound(this.message);
  @override
  String toString() => message;
}

/// flutter_blue_plus over raw ATT bearers. See the file comment.
final class DirectAttPlatform extends FlutterBluePlusPlatform {
  final AttChannelFactory _channels;
  final AddressTypeResolver _isRandomAddress;
  final BusyLinkHandler? onBusy;

  /// How long an L2CAP connect may take before it is abandoned.
  final Duration connectTimeout;

  /// How long one ATT request may go unanswered. A timeout closes the bearer
  /// (the spec's rule, and bluetoothd's), so this is also how long a silent
  /// peripheral holds an operation.
  final Duration requestTimeout;

  /// How long pairing / encryption on demand may take (an agent prompt can
  /// be waiting on a person).
  final Duration securityTimeout;

  /// EBUSY retries: bluetoothd lets go of its ATT channel within about two
  /// seconds of giving up on a device, and a connect inside that window is
  /// refused.
  final int busyRetries;
  final Duration busyRetryDelay;

  final Map<String, _Link> _links = {};

  /// Devices whose last failed open had got as far as a connected socket.
  final Set<String> _cameUp = {};

  final _connection = StreamController<BmConnectionStateResponse>.broadcast();
  final _discovered = StreamController<BmDiscoverServicesResult>.broadcast();
  final _received = StreamController<BmCharacteristicData>.broadcast();
  final _written = StreamController<BmCharacteristicData>.broadcast();
  final _descRead = StreamController<BmDescriptorData>.broadcast();
  final _descWritten = StreamController<BmDescriptorData>.broadcast();
  final _mtu = StreamController<BmMtuChangedResponse>.broadcast();
  final _rssi = StreamController<BmReadRssiResult>.broadcast();
  final _servicesReset = StreamController<BmBluetoothDevice>.broadcast();

  static final Guid _cccdUuid = Guid(
    uuid16ToString(GattType.clientCharacteristicConfiguration),
  );

  DirectAttPlatform(
    this._channels, {
    AddressTypeResolver? isRandomAddress,
    this.onBusy,
    this.connectTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 15),
    this.securityTimeout = const Duration(seconds: 30),
    this.busyRetries = 5,
    this.busyRetryDelay = const Duration(milliseconds: 600),
  }) : _isRandomAddress = isRandomAddress ?? ((_) async => false);

  static String _k(DeviceIdentifier id) =>
      DirectAttRegistry.normalizeDeviceId(id.str);

  /// Whether a link to [deviceId] exists in any state short of closed —
  /// the router's test for "BlueZ's events about this device are noise".
  bool hasLink(String deviceId) =>
      _links.containsKey(DirectAttRegistry.normalizeDeviceId(deviceId));

  /// Whether the last attempt to open [deviceId] that failed had a link up
  /// (it failed during setup — an unanswered MTU exchange, say) rather than
  /// never connecting. The router retries only the latter.
  bool lastAttemptCameUp(String deviceId) =>
      _cameUp.contains(DirectAttRegistry.normalizeDeviceId(deviceId));

  /// Whether [deviceId]'s link is up.
  bool isConnected(String deviceId) =>
      _links[DirectAttRegistry.normalizeDeviceId(deviceId)]?.state ==
      _LinkState.connected;

  /// The negotiated ATT MTU of [deviceId]'s link, or null when there is none.
  int? mtuOf(String deviceId) =>
      _links[DirectAttRegistry.normalizeDeviceId(deviceId)]?.client?.mtu;

  // ---- streams ---------------------------------------------------------

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      _connection.stream;
  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices =>
      _discovered.stream;
  @override
  Stream<BmCharacteristicData> get onCharacteristicReceived => _received.stream;
  @override
  Stream<BmCharacteristicData> get onCharacteristicWritten => _written.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorRead => _descRead.stream;
  @override
  Stream<BmDescriptorData> get onDescriptorWritten => _descWritten.stream;
  @override
  Stream<BmMtuChangedResponse> get onMtuChanged => _mtu.stream;
  @override
  Stream<BmReadRssiResult> get onReadRssi => _rssi.stream;
  @override
  Stream<BmBluetoothDevice> get onServicesReset => _servicesReset.stream;

  // ---- the adapter, when this is installed on its own (tests) -----------

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;

  @override
  Future<BmBluetoothAdapterState> getAdapterState(
    BmBluetoothAdapterStateRequest request,
  ) async => BmBluetoothAdapterState(adapterState: BmAdapterStateEnum.on);

  @override
  Future<bool> setLogLevel(BmSetLogLevelRequest request) async => true;

  @override
  Future<bool> setOptions(BmSetOptionsRequest request) async => true;

  // ---- connection -------------------------------------------------------

  @override
  Future<bool> connect(BmConnectRequest request) async {
    final existing = _links[_k(request.remoteId)];
    if (existing != null) {
      switch (existing.state) {
        case _LinkState.connected:
          return false;
        case _LinkState.connecting:
          if (existing.cancel.isCompleted) {
            // Cancelled (flutter_blue_plus timed its connect out) but still
            // unwinding. Its report belongs to a connect that has already
            // thrown; joining it would hand THIS connect that
            // "connection canceled". Silence it and start afresh.
            existing.announce = false;
            await existing.ended.future.timeout(
              connectTimeout,
              onTimeout: () {},
            );
            break;
          }
          // A hand-over in flight becomes a connect someone is waiting on.
          existing.announce = true;
          return true;
        case _LinkState.disconnecting:
        case _LinkState.closed:
          await existing.channel?.closed;
      }
    }
    final link = _Link(request.remoteId, announce: true);
    _links[_k(request.remoteId)] = link;
    unawaited(_open(link));
    return true;
  }

  /// Open a link to [remoteId] WITHOUT announcing it: the router's hand-over
  /// from BlueZ, where flutter_blue_plus already believes the device is
  /// connected and must see no connect, and — if this works — no disconnect
  /// either. Completes with whether the link came up.
  Future<bool> takeOver(DeviceIdentifier remoteId) async {
    final existing = _links[_k(remoteId)];
    if (existing != null && existing.state != _LinkState.closed) {
      if (existing.state == _LinkState.connected) return true;
      if (existing.state == _LinkState.connecting) {
        return existing.opened.future;
      }
      await existing.channel?.closed;
    }
    final link = _Link(remoteId, announce: false);
    _links[_k(remoteId)] = link;
    unawaited(_open(link));
    return link.opened.future;
  }

  /// Drop a link [takeOver] opened for a hand-over that did not work out,
  /// telling flutter_blue_plus nothing: it never learned of the link.
  Future<void> abandon(DeviceIdentifier remoteId) async {
    final link = _links[_k(remoteId)];
    if (link == null) return;
    link.announce = false;
    link.closedLocally = true;
    if (!link.cancel.isCompleted) link.cancel.complete();
    _links.remove(_k(remoteId));
    link.state = _LinkState.closed;
    await _teardown(link);
    if (!link.ended.isCompleted) link.ended.complete();
  }

  Future<void> _open(_Link link) async {
    final address = _k(link.remoteId);
    Log.ble.info('opening a direct ATT channel to ${link.remoteId}');
    try {
      final random = await _isRandomAddress(address);
      final channel = await _connectChannel(link, address, random);
      link.channel = channel;
      if (link.cancel.isCompleted) {
        await channel.close();
        throw const AttChannelException(
          'connect',
          'connection canceled',
          errno: 125,
        );
      }
      final client = AttClient(
        channel,
        log: (m) => Log.ble.debug('${link.remoteId}: $m'),
        requestTimeout: requestTimeout,
        securityTimeout: securityTimeout,
      );
      link.client = client;
      link.values = client.notifications.listen((e) => _onValue(link, e));
      unawaited(channel.closed.then((_) => _onClosed(link)));
      Object? exchangeFailure;
      try {
        final mtu = await client.exchangeMtu();
        Log.ble.debug('direct ATT mtu for ${link.remoteId}: $mtu');
      } catch (e) {
        // Not fatal: 23 works, just in smaller pieces. A timeout here has
        // already closed the bearer, which the check below catches.
        exchangeFailure = e;
        Log.ble.debug('MTU exchange with ${link.remoteId} failed', error: e);
      }
      if (!client.isOpen || link.cancel.isCompleted) {
        throw AttChannelException(
          'connect',
          link.cancel.isCompleted
              ? 'connection canceled'
              : exchangeFailure is AttTimeoutException
              ? 'the device never answered the MTU exchange, so the link '
                    'was closed (an ATT timeout ends the bearer)'
              : 'the device disconnected while the link was being set up',
          errno: link.cancel.isCompleted ? 125 : channel.closeErrno,
        );
      }
      // A peer-initiated Exchange MTU later moves it too.
      link.mtus = client.mtuChanges.listen((mtu) => _emitMtu(link, mtu));
      link.state = _LinkState.connected;
      // Before "connected", so mtuNow is right the moment connect() returns.
      _emitMtu(link, client.mtu);
      if (link.announce) _emitState(link, BmConnectionStateEnum.connected);
      Log.ble.info('direct ATT channel to ${link.remoteId} is up');
      link.opened.complete(true);
    } catch (e) {
      final canceled =
          link.cancel.isCompleted ||
          (e is AttChannelException && e.errno == 125);
      Log.ble.warning(
        'direct ATT connect to ${link.remoteId} '
        '${canceled ? 'canceled' : 'failed'}',
        error: e,
      );
      if (identical(_links[address], link)) _links.remove(address);
      if (link.channel != null) {
        _cameUp.add(address);
      } else {
        _cameUp.remove(address);
      }
      final wasOpen = link.state != _LinkState.closed;
      link.state = _LinkState.closed;
      await _teardown(link);
      if (wasOpen && link.announce) {
        _emitState(
          link,
          BmConnectionStateEnum.disconnected,
          code: canceled ? bmUserCanceledErrorCode : _errnoOf(e),
          reason: canceled ? 'connection canceled' : _describe(e),
        );
      }
      if (!link.opened.isCompleted) link.opened.complete(false);
      if (!link.ended.isCompleted) link.ended.complete();
    }
  }

  Future<AttChannel> _connectChannel(
    _Link link,
    String address,
    bool random,
  ) async {
    var busy = 0;
    while (true) {
      try {
        return await _channels.connect(
          address,
          randomAddress: random,
          timeout: connectTimeout,
          cancel: link.cancel.future,
        );
      } on AttChannelException catch (e) {
        if (!e.isBusy || busy >= busyRetries || link.cancel.isCompleted) {
          rethrow;
        }
        busy++;
        Log.ble.debug(
          '$address: the kernel refused a second ATT channel (EBUSY) — '
          'bluetoothd still holds one; retry $busy',
        );
        if (busy == 2) {
          try {
            await onBusy?.call(link.remoteId.str);
          } catch (e) {
            Log.ble.debug('busy-link handler for $address failed', error: e);
          }
        }
        await Future<void>.delayed(busyRetryDelay);
      }
    }
  }

  /// The bearer is gone. Reported one event-loop turn later, on purpose:
  /// the operations the loss ended are failing in this same turn, and each
  /// must get its own answer to flutter_blue_plus first — above all a
  /// request parked on a pairing the peer refused, whose error is "pair
  /// first", not "the link dropped" (the kernel drops the link on a refused
  /// pairing, so both arrive together). flutter_blue_plus's guard would
  /// otherwise see the disconnect first and report that instead.
  void _onClosed(_Link link) => Timer.run(() => _closeNow(link));

  void _closeNow(_Link link) {
    // A link still being set up is _open's to report: its setup exchange
    // fails with the bearer, and its failure path emits the one event the
    // waiting connect needs. Marking it closed here would silence that.
    if (link.state == _LinkState.closed ||
        link.state == _LinkState.connecting) {
      return;
    }
    final address = _k(link.remoteId);
    if (identical(_links[address], link)) _links.remove(address);
    link.state = _LinkState.closed;
    unawaited(_teardown(link));
    Log.ble.info('direct ATT channel to ${link.remoteId} closed');
    if (link.closedLocally) {
      _emitState(
        link,
        BmConnectionStateEnum.disconnected,
        code: bmUserCanceledErrorCode,
        reason: 'connection canceled',
      );
    } else {
      final errno = link.channel?.closeErrno;
      _emitState(
        link,
        BmConnectionStateEnum.disconnected,
        code: errno ?? 0,
        reason: errno == null
            ? 'the direct ATT link closed'
            : 'the direct ATT link was lost (errno $errno)',
      );
    }
    if (!link.ended.isCompleted) link.ended.complete();
  }

  Future<void> _teardown(_Link link) async {
    await link.values?.cancel();
    await link.mtus?.cancel();
    link.values = null;
    link.mtus = null;
    final client = link.client;
    if (client != null) {
      await client.close();
    } else {
      await link.channel?.close();
    }
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    final link = _links[_k(request.remoteId)];
    if (link == null) return false;
    switch (link.state) {
      case _LinkState.connecting:
        link.closedLocally = true;
        if (!link.cancel.isCompleted) link.cancel.complete();
        // Past the socket connect, the setup exchange could otherwise hold
        // the cancel for a whole request timeout.
        unawaited(link.client?.close() ?? link.channel?.close());
        // _open reports the cancel, when someone was told it was coming.
        return link.announce;
      case _LinkState.connected:
        link.closedLocally = true;
        link.state = _LinkState.disconnecting;
        await link.client?.close();
        return true;
      case _LinkState.disconnecting:
        return true;
      case _LinkState.closed:
        return false;
    }
  }

  /// Close every link, reporting each as disconnected. For tests, which
  /// share one flutter_blue_plus (and so one of these) per file.
  Future<void> debugReset() async {
    for (final link in _links.values.toList()) {
      link.closedLocally = true;
      if (link.state == _LinkState.connecting) {
        if (!link.cancel.isCompleted) link.cancel.complete();
        await link.opened.future;
      } else if (link.state == _LinkState.connected) {
        link.state = _LinkState.disconnecting;
        await link.client?.close();
      }
    }
    // Let the disconnects reach flutter_blue_plus before the next test.
    await Future<void>.delayed(Duration.zero);
    _links.clear();
  }

  // ---- discovery --------------------------------------------------------

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    final services = await discoverForHandOver(request.remoteId);
    if (services != null) publishDiscovery(request.remoteId, services);
    return true;
  }

  /// Walk [remoteId]'s table and return what [discoverServices] would
  /// publish, without publishing it — or null when the walk failed (a
  /// failure result has then been published only if the link is still up;
  /// a lost link is reported as a disconnect instead). The router uses this
  /// to decide a hand-over before flutter_blue_plus hears anything.
  Future<List<BmBluetoothService>?> discoverForHandOver(
    DeviceIdentifier remoteId, {
    bool publishFailure = true,
  }) async {
    final link = _live(remoteId);
    if (link == null) {
      if (publishFailure) {
        _discovered.add(
          _discoveryFailure(remoteId, 0, 'device is not connected'),
        );
      }
      return null;
    }
    try {
      return (await _tableOf(link)).toBm(remoteId);
    } on AttErrorException catch (e) {
      if (publishFailure) {
        _discovered.add(
          _discoveryFailure(remoteId, e.errorCode, _describeAtt(e)),
        );
      }
    } on AttFormatException catch (e) {
      if (publishFailure) {
        _discovered.add(_discoveryFailure(remoteId, 0, e.toString()));
      }
    } catch (e) {
      // A lost or timed-out bearer: the disconnect event says it.
      Log.ble.debug('direct ATT discovery on $remoteId ended', error: e);
      await _afterLinkLoss(link);
    }
    return null;
  }

  /// Publish [services] as [remoteId]'s discovery result.
  void publishDiscovery(
    DeviceIdentifier remoteId,
    List<BmBluetoothService> services,
  ) => _discovered.add(
    BmDiscoverServicesResult(
      remoteId: remoteId,
      services: services,
      success: true,
      errorCode: 0,
      errorString: '',
    ),
  );

  BmDiscoverServicesResult _discoveryFailure(
    DeviceIdentifier remoteId,
    int code,
    String text,
  ) => BmDiscoverServicesResult(
    remoteId: remoteId,
    services: const [],
    success: false,
    errorCode: code,
    errorString: text,
  );

  Future<_Table> _tableOf(_Link link) {
    final cached = link.table;
    if (cached != null) return Future.value(cached);
    return link.walking ??= _walk(link).whenComplete(() => link.walking = null);
  }

  Future<_Table> _walk(_Link link) async {
    final stopwatch = Stopwatch()..start();
    final services = await link.client!.discoverServices();
    final table = _Table(services);
    Log.ble.info(
      'direct ATT discovered ${services.length} service(s) on '
      '${link.remoteId} in ${stopwatch.elapsedMilliseconds}ms',
    );
    for (final s in services) {
      Log.ble.debug(
        '  service ${s.uuid}: ${s.characteristics.length} characteristic(s) '
        '[${s.characteristics.map((c) => c.uuid).join(', ')}]',
      );
    }
    await _subscribeServiceChanged(link, table);
    if (link.state == _LinkState.connected) link.table = table;
    return table;
  }

  /// Ask for Service Changed indications, as bluetoothd's and
  /// CoreBluetooth's GATT clients do: a compliant peer only indicates a
  /// rebuilt database to a client that enabled the CCCD (Core Vol 3 Part G,
  /// 7.1), and an unbonded client's CCCD starts every link at zero. Only
  /// when the characteristic really offers indications and has a CCCD — a
  /// peer that never answers the write would cost the link (the ATT timeout
  /// rule) — and never through the security retry: some of these devices
  /// support no encryption, and asking one to pair drops the link. A
  /// refusal is logged, never fatal.
  Future<void> _subscribeServiceChanged(_Link link, _Table table) async {
    final handle = table.serviceChangedHandle;
    if (handle == null) return;
    final sc = table.byValueHandle[handle]!.att;
    final cccd = sc.cccdHandle;
    if (!sc.canIndicate || cccd == null) return;
    try {
      await link.client!.write(cccd, const [0x02, 0x00], secure: false);
      Log.ble.debug('${link.remoteId}: Service Changed indications on');
    } on AttErrorException catch (e) {
      Log.ble.debug('${link.remoteId} refused Service Changed indications: $e');
    }
  }

  // ---- GATT -------------------------------------------------------------

  @override
  Future<bool> readCharacteristic(BmReadCharacteristicRequest request) async {
    BmCharacteristicData result(
      List<int> value, {
      bool ok = true,
      int code = 0,
      String text = '',
    }) => BmCharacteristicData(
      remoteId: request.remoteId,
      primaryServiceUuid: request.primaryServiceUuid,
      serviceUuid: request.serviceUuid,
      characteristicUuid: request.characteristicUuid,
      instanceId: request.instanceId,
      value: value,
      success: ok,
      errorCode: code,
      errorString: text,
    );
    await _gatt(
      request.remoteId,
      'readCharacteristic',
      silentIsTimeout: true,
      run: (link, table) async {
        final c = _char(
          table,
          request.serviceUuid,
          request.characteristicUuid,
          request.instanceId,
        );
        final value = await link.client!.read(c.att.valueHandle);
        _received.add(result(List.unmodifiable(value)));
      },
      fail: (code, text) =>
          _received.add(result(const [], ok: false, code: code, text: text)),
    );
    return true;
  }

  @override
  Future<bool> writeCharacteristic(BmWriteCharacteristicRequest request) async {
    BmCharacteristicData result({
      bool ok = true,
      int code = 0,
      String text = '',
    }) => BmCharacteristicData(
      remoteId: request.remoteId,
      primaryServiceUuid: request.primaryServiceUuid,
      serviceUuid: request.serviceUuid,
      characteristicUuid: request.characteristicUuid,
      instanceId: request.instanceId,
      value: ok ? List.unmodifiable(request.value) : const [],
      success: ok,
      errorCode: code,
      errorString: text,
    );
    await _gatt(
      request.remoteId,
      'writeCharacteristic',
      silentIsTimeout: true,
      run: (link, table) async {
        final c = _char(
          table,
          request.serviceUuid,
          request.characteristicUuid,
          request.instanceId,
        );
        // As flutter_blue_plus_linux asks BlueZ: the type the caller chose,
        // and a Write Request longer than one PDU becomes a queued (long)
        // write rather than an error. A Write Command cannot be queued, so
        // an oversize one fails.
        if (request.writeType == BmWriteType.withResponse) {
          await link.client!.write(c.att.valueHandle, request.value);
        } else {
          link.client!.writeWithoutResponse(c.att.valueHandle, request.value);
        }
        // flutter_blue_plus waits for this even for a write without
        // response.
        _written.add(result());
      },
      fail: (code, text) =>
          _written.add(result(ok: false, code: code, text: text)),
    );
    return true;
  }

  @override
  Future<bool> setNotifyValue(BmSetNotifyValueRequest request) async {
    BmDescriptorData result(
      List<int> value, {
      bool ok = true,
      int code = 0,
      String text = '',
    }) => BmDescriptorData(
      remoteId: request.remoteId,
      primaryServiceUuid: request.primaryServiceUuid,
      serviceUuid: request.serviceUuid,
      characteristicUuid: request.characteristicUuid,
      instanceId: request.instanceId,
      descriptorUuid: _cccdUuid,
      value: value,
      success: ok,
      errorCode: code,
      errorString: text,
    );
    var hasCccd = true;
    await _gatt(
      request.remoteId,
      'setNotifyValue',
      // A CCCD write the peer never answers closes the bearer; what the
      // caller hears is the disconnect. (flutter_blue_plus's timeout shape
      // would be swallowed here: RealBleService tolerates exactly that one
      // on Linux, for a backend that never confirmed CCCD writes.)
      silentIsTimeout: false,
      run: (link, table) async {
        final c = _char(
          table,
          request.serviceUuid,
          request.characteristicUuid,
          request.instanceId,
        );
        if (!c.att.canNotify && !c.att.canIndicate) {
          throw _NotFound(
            'characteristic ${request.characteristicUuid} supports neither '
            'notifications nor indications',
          );
        }
        final cccd = c.att.cccdHandle;
        if (cccd == null) {
          // Some firmware notifies without a CCCD; the values are forwarded
          // regardless. flutter_blue_plus takes false as "no CCCD to wait
          // for", exactly as it does from BlueZ.
          hasCccd = false;
          return;
        }
        // Notify when the characteristic offers it, indicate otherwise:
        // the choice iOS and flutter_blue_plus's own docs make.
        final flags = !request.enable ? 0 : (c.att.canNotify ? 0x0001 : 0x0002);
        await link.client!.writeCccd(cccd, flags);
        _descWritten.add(result([flags & 0xFF, flags >> 8]));
      },
      fail: (code, text) =>
          _descWritten.add(result(const [], ok: false, code: code, text: text)),
    );
    return hasCccd;
  }

  @override
  Future<bool> readDescriptor(BmReadDescriptorRequest request) async {
    BmDescriptorData result(
      List<int> value, {
      bool ok = true,
      int code = 0,
      String text = '',
    }) => BmDescriptorData(
      remoteId: request.remoteId,
      primaryServiceUuid: request.primaryServiceUuid,
      serviceUuid: request.serviceUuid,
      characteristicUuid: request.characteristicUuid,
      instanceId: request.instanceId,
      descriptorUuid: request.descriptorUuid,
      value: value,
      success: ok,
      errorCode: code,
      errorString: text,
    );
    await _gatt(
      request.remoteId,
      'readDescriptor',
      silentIsTimeout: false,
      run: (link, table) async {
        final c = _char(
          table,
          request.serviceUuid,
          request.characteristicUuid,
          request.instanceId,
        );
        final handle = _descriptor(c, request.descriptorUuid);
        final value = await link.client!.read(handle);
        _descRead.add(result(List.unmodifiable(value)));
      },
      fail: (code, text) =>
          _descRead.add(result(const [], ok: false, code: code, text: text)),
    );
    return true;
  }

  @override
  Future<bool> writeDescriptor(BmWriteDescriptorRequest request) async {
    BmDescriptorData result({bool ok = true, int code = 0, String text = ''}) =>
        BmDescriptorData(
          remoteId: request.remoteId,
          primaryServiceUuid: request.primaryServiceUuid,
          serviceUuid: request.serviceUuid,
          characteristicUuid: request.characteristicUuid,
          instanceId: request.instanceId,
          descriptorUuid: request.descriptorUuid,
          value: ok ? List.unmodifiable(request.value) : const [],
          success: ok,
          errorCode: code,
          errorString: text,
        );
    await _gatt(
      request.remoteId,
      'writeDescriptor',
      silentIsTimeout: false,
      run: (link, table) async {
        final c = _char(
          table,
          request.serviceUuid,
          request.characteristicUuid,
          request.instanceId,
        );
        final handle = _descriptor(c, request.descriptorUuid);
        await link.client!.write(handle, request.value);
        _descWritten.add(result());
      },
      fail: (code, text) =>
          _descWritten.add(result(ok: false, code: code, text: text)),
    );
    return true;
  }

  @override
  Future<bool> readRssi(BmReadRssiRequest request) async {
    // A raw ATT bearer carries no RSSI; reading one takes an HCI socket,
    // which is root's. An honest failure routes the Find Device view into
    // its signal-lost path.
    _rssi.add(
      BmReadRssiResult(
        remoteId: request.remoteId,
        rssi: 0,
        success: false,
        errorCode: 0,
        errorString: 'RSSI is not readable over a direct ATT channel',
      ),
    );
    return true;
  }

  @override
  Future<bool> requestMtu(BmMtuChangeRequest request) async {
    // flutter_blue_plus only asks on Android. The link already exchanged
    // the largest MTU both sides allow when it came up.
    final link = _live(request.remoteId);
    if (link != null) _emitMtu(link, link.client!.mtu);
    return link != null;
  }

  @override
  Future<bool> clearGattCache(BmClearGattCacheRequest request) async {
    _live(request.remoteId)?.table = null;
    return true;
  }

  /// Run one GATT operation and turn its failure into the shape the caller
  /// classifies. See the file comment for the vocabulary.
  Future<void> _gatt(
    DeviceIdentifier remoteId,
    String function, {
    required bool silentIsTimeout,
    required Future<void> Function(_Link link, _Table table) run,
    required void Function(int code, String text) fail,
  }) async {
    final link = _live(remoteId);
    if (link == null) {
      fail(0, 'device is not connected');
      return;
    }
    try {
      await run(link, await _tableOf(link));
    } on AttErrorException catch (e) {
      Log.ble.debug('$remoteId $function: $e');
      fail(e.errorCode, _describeAtt(e));
    } on AttTimeoutException {
      await _afterLinkLoss(link);
      if (silentIsTimeout) {
        throw FlutterBluePlusException(
          ErrorPlatform.fbp,
          function,
          FbpErrorCode.timeout.index,
          'Timed out after ${requestTimeout.inSeconds}s: the device never '
          'answered, and the link has been closed as the ATT spec requires',
        );
      }
      // Otherwise the closed bearer is reported as a disconnect.
    } on AttLinkClosedException {
      // Reported as a disconnect.
      await _afterLinkLoss(link);
    } on AttChannelException catch (e) {
      // Usually the bearer dying under the operation, which the disconnect
      // reports. But a live socket can refuse one send — while the kernel is
      // raising the link's security, say — and then this operation failed
      // on its own and must say so, or flutter_blue_plus waits it out.
      if (link.client?.isOpen ?? false) {
        fail(e.errno ?? 0, e.toString());
      } else {
        await _afterLinkLoss(link);
      }
    } on _NotFound catch (e) {
      fail(0, e.message);
    } on AttFormatException catch (e) {
      fail(0, e.toString());
    } on ArgumentError catch (e) {
      fail(0, e.message?.toString() ?? e.toString());
    }
  }

  /// Return only once flutter_blue_plus has HEARD that [link] is gone.
  ///
  /// An operation that dies with its link emits nothing of its own: the
  /// disconnect is the answer, and flutter_blue_plus turns it into
  /// deviceIsDisconnected — through a guard it subscribes the moment this
  /// call returns, seeded from its cached connection state. A disconnect
  /// still in flight at that moment is in neither place: queued only for the
  /// listeners that existed when it was added, and not yet in the cache. The
  /// guard would then wait out the whole operation timeout for an event it
  /// can no longer receive. So wait for the report, then let the event loop
  /// deliver it (every hop is a microtask; a zero timer runs after them).
  Future<void> _afterLinkLoss(_Link link) async {
    await link.ended.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  _Char _char(
    _Table table,
    Guid service,
    Guid characteristic,
    int instanceId,
  ) =>
      table.find(service, characteristic, instanceId) ??
      (throw _NotFound(
        'characteristic $characteristic (instance $instanceId) not found in '
        'service $service',
      ));

  int _descriptor(_Char c, Guid descriptor) {
    for (final d in c.att.descriptors) {
      if (Guid(d.uuid) == descriptor) return d.handle;
    }
    throw _NotFound(
      'descriptor $descriptor not found on characteristic '
      '${c.characteristicUuid}',
    );
  }

  _Link? _live(DeviceIdentifier remoteId) {
    final link = _links[_k(remoteId)];
    return link != null && link.state == _LinkState.connected ? link : null;
  }

  // ---- events from the peer ----------------------------------------------

  void _onValue(_Link link, AttValueEvent event) {
    final table = link.table;
    if (table == null) {
      // A value before (or during a re-walk of) the table cannot be named
      // in flutter_blue_plus's terms. Subscriptions are only made after a
      // walk, so this is a stray.
      Log.ble.debug(
        '${link.remoteId}: dropping a value for handle '
        '0x${event.handle.toRadixString(16)} before discovery',
      );
      return;
    }
    if (event.handle == table.serviceChangedHandle) {
      // The peer rebuilt its database. Forget the table and say so;
      // flutter_blue_plus drops its copy and RealBleService rediscovers.
      Log.ble.info('${link.remoteId} reported Service Changed');
      link.table = null;
      _servicesReset.add(
        BmBluetoothDevice(remoteId: link.remoteId, platformName: null),
      );
      return;
    }
    final c = table.byValueHandle[event.handle];
    if (c == null) return;
    _received.add(
      BmCharacteristicData(
        remoteId: link.remoteId,
        primaryServiceUuid: null,
        serviceUuid: c.serviceUuid,
        characteristicUuid: c.characteristicUuid,
        instanceId: c.instanceId,
        value: List.unmodifiable(event.value),
        success: true,
        errorCode: 0,
        errorString: '',
      ),
    );
  }

  void _emitMtu(_Link link, int mtu) =>
      _mtu.add(BmMtuChangedResponse(remoteId: link.remoteId, mtu: mtu));

  void _emitState(
    _Link link,
    BmConnectionStateEnum state, {
    int? code,
    String? reason,
  }) => _connection.add(
    BmConnectionStateResponse(
      remoteId: link.remoteId,
      connectionState: state,
      disconnectReasonCode: state == BmConnectionStateEnum.connected
          ? null
          : code,
      disconnectReasonString: state == BmConnectionStateEnum.connected
          ? null
          : reason,
    ),
  );

  static int _errnoOf(Object e) =>
      e is AttChannelException ? (e.errno ?? 0) : 0;

  static String _describe(Object e) => switch (e) {
    AttChannelException(:final message, :final errno) =>
      errno == null ? message : '$message (errno $errno)',
    _ => e.toString(),
  };

  static String _describeAtt(AttErrorException e) =>
      'ATT error 0x${e.errorCode.toRadixString(16).padLeft(2, '0')} '
      '(${AttError.describe(e.errorCode)})';
}
