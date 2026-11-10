// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../src/rust/api/readonly_api.dart';
import '../src/rust/protocol/acinfinity.dart';
import 'ble_service.dart';
import 'read_only_ble_session.dart';

const _service = '70d51000-2c7f-4e75-ae8a-d758951ce4e0';
const _command = '70d51001-2c7f-4e75-ae8a-d758951ce4e0';
const _notify = '70d51002-2c7f-4e75-ae8a-d758951ce4e0';

/// The latest status frame and what the controller said it has stored.
@immutable
class AcInfinityReading {
  final AcInfinityStatusDto status;
  final Map<int, AcInfinityStoredDto> stored;

  /// No status frame arrived within the stall window, so this one is old.
  /// A port shown as on may no longer be, which is worth saying out loud.
  final bool stale;

  const AcInfinityReading({
    required this.status,
    this.stored = const {},
    this.stale = false,
  });
}

abstract interface class AcInfinityClient {
  /// Readings as they arrive, with a [ReadOnlyBleException] on the stream when
  /// the session cannot go on. Listening starts the session; closing ends it.
  Stream<AcInfinityReading> watch();

  Future<void> close();
}

/// Reads an AC Infinity UIS controller's climate and ports.
///
/// Every port can switch mains equipment, so this is as close to silent as the
/// protocol allows. Subscribing is what starts the status stream, and that is
/// where climate and port state come from. The only frame this client ever
/// writes is `get_model_data`, once per occupied port of the multi-port
/// controller layout, for the stored levels; [acinfinityEncodeGetModelData]
/// builds opcode 0x01 and nothing else. A power strip's relays and a legacy
/// controller are read from the stream alone.
class AcInfinityBleClient implements AcInfinityClient {
  final ReadOnlyBleSession _session;

  /// The unit's manufacturer payload for company 0x0902, after the company
  /// id. Its device type and protocol revision pick the status layout; without
  /// it only the multi-port controller layout is read.
  final Uint8List? _advertisement;

  /// The stream runs about once a second. A controller that says nothing
  /// usable within this is reported rather than waited on for ever.
  final Duration answerWait;

  /// How long to wait for one read's reply. An unanswered read costs only the
  /// stored levels of that port: the status stream is the real surface.
  final Duration replyWait;

  /// How long without a status frame before the reading is marked stale.
  final Duration staleAfter;

  final _output = StreamController<AcInfinityReading>.broadcast();
  final _stored = <int, AcInfinityStoredDto>{};
  Uint8List _frameBuffer = Uint8List(0);
  Uint8List _statusBuffer = Uint8List(0);
  Future<void> _queue = Future<void>.value();
  AcInfinityStatusDto? _status;
  Timer? _answerTimer;
  Timer? _staleTimer;
  Completer<Uint8List>? _replyWaiter;
  String? _refusedLayout;
  var _sequence = 0;
  bool _started = false;
  bool _readingStored = false;

  AcInfinityBleClient({
    required BleService ble,
    required String deviceId,
    List<int>? advertisement,
    this.answerWait = const Duration(seconds: 10),
    this.replyWait = const Duration(seconds: 3),
    this.staleAfter = const Duration(seconds: 10),
  }) : _advertisement = advertisement == null
           ? null
           : Uint8List.fromList(advertisement),
       _session = ReadOnlyBleSession(
         ble: ble,
         deviceId: deviceId,
         serviceUuid: _service,
         writeUuid: _command,
         notifyUuid: _notify,
       );

  @override
  Stream<AcInfinityReading> watch() {
    if (!_started) {
      _started = true;
      unawaited(_run());
    }
    return _output.stream;
  }

  Future<void> _run() async {
    try {
      await _session.open(
        onBytes: _onBytes,
        onError: _fail,
        missingService:
            'This device does not carry the AC Infinity control service. Its '
            'Bluetooth may need the five-second port button hold first.',
      );
      if (_session.isClosed) return;
      _answerTimer = Timer(answerWait, () {
        _fail(
          ReadOnlyBleException(
            _refusedLayout != null
                ? 'This controller reports status in a layout this app does '
                      'not decode, so nothing is shown rather than a wrong '
                      'reading.'
                : 'The controller did not send any status it could be read '
                      'from.',
          ),
        );
      });
    } on Object catch (e) {
      _fail(e);
    }
  }

  void _onBytes(List<int> bytes) {
    final copy = List<int>.of(bytes);
    _queue = _queue.then((_) => _assemble(copy)).catchError(_fail);
  }

  Future<void> _assemble(List<int> chunk) async {
    if (_session.isClosed) return;
    final fed = await acinfinityFeed(
      frameBuffer: _frameBuffer,
      statusBuffer: _statusBuffer,
      chunk: chunk,
    );
    _frameBuffer = fed.frameBuffer;
    _statusBuffer = fed.statusBuffer;
    for (final frame in fed.frames) {
      if (frame.isNotEmpty && frame.first == 0xa5) {
        final waiter = _replyWaiter;
        _replyWaiter = null;
        waiter?.complete(frame);
      } else {
        await _onStatus(frame);
      }
    }
  }

  Future<void> _onStatus(Uint8List frame) async {
    final AcInfinityStatusDto status;
    try {
      status = await acinfinityDecodeStatus(
        frame: frame,
        advertisement: _advertisement,
      );
    } on Object catch (e) {
      Log.ble.debug('AC Infinity status not decoded', error: e);
      _refusedLayout = e.toString();
      return;
    }
    if (_session.isClosed) return;
    _answerTimer?.cancel();
    _status = status;
    _publish();
    _staleTimer?.cancel();
    _staleTimer = Timer(staleAfter, () => _publish(stale: true));
    if (!_readingStored) {
      _readingStored = true;
      unawaited(_readStored(status));
    }
  }

  void _publish({bool stale = false}) {
    final status = _status;
    if (status == null || _output.isClosed) return;
    _output.add(
      AcInfinityReading(
        status: status,
        stored: Map.unmodifiable(_stored),
        stale: stale,
      ),
    );
  }

  /// One command in flight, waiting for its reply, as the spec asks. Only on
  /// the controller layout, the one upstream ran: strip outlets are relays
  /// with no levels to store, and a legacy unit is app analysis only.
  Future<void> _readStored(AcInfinityStatusDto status) async {
    if (status.layout != AcInfinityLayout.controller) return;
    for (final port in status.ports.where((p) => p.occupied == true)) {
      if (_session.isClosed) return;
      final sequence = _sequence = (_sequence % 0xffff) + 1;
      try {
        final waiter = _replyWaiter = Completer<Uint8List>();
        // close() may fail this before the timeout below is listening.
        waiter.future.ignore();
        await _session.write(
          await acinfinityEncodeGetModelData(
            port: port.port,
            sequence: sequence,
          ),
        );
        final reply = await waiter.future.timeout(replyWait);
        _stored[port.port] = await acinfinityDecodeModelData(
          frame: reply,
          sequence: sequence,
          port: port.port,
        );
        if (_session.isClosed) return;
        _publish();
      } on Object catch (e) {
        _replyWaiter = null;
        Log.ble.debug(
          'AC Infinity stored levels for port ${port.port} not read',
          error: e,
        );
      }
    }
  }

  void _fail(Object error) {
    if (_session.isClosed) return;
    Log.ble.warning('AC Infinity session failed', error: error);
    if (!_output.isClosed) _output.addError(error);
    unawaited(close());
  }

  @override
  Future<void> close() async {
    _answerTimer?.cancel();
    _staleTimer?.cancel();
    final waiter = _replyWaiter;
    _replyWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.completeError(const ReadOnlyBleException('The session closed.'));
    }
    await _session.close();
    if (!_output.isClosed) await _output.close();
  }
}
