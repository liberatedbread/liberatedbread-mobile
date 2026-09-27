// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A GATT client over an [AttChannel]: one request in flight at a time (ATT
// is strictly request/response), notifications demultiplexed alongside, and
// the discovery walk that turns a peripheral's handle space into services
// and characteristics.
//
// THE DISCOVERY WALK
//
// Primary services by group type, characteristics by type, descriptors by
// Find Information only where a characteristic leaves room for them. That
// is the core of what Android's stack sends, and so the core every vendor
// app has exercised against its device. It is not byte-for-byte Android's:
// Android also sends an Include (0x2802) Read By Type in every service, and
// one more characteristic Read By Type past the last declaration it found.
// Both are skipped here — includes are optional and apps never see them,
// and the trailing request can only earn Attribute Not Found — because
// every extra request is one more thing some firmware mishandles. (The
// LDM330 capture, captures/jlx/setup-and-capture.pcapng, shows the meter
// answering both with Attribute Not Found, so skipping them costs nothing
// there either.) What is NOT sent at all: the Server Supported Features /
// Database Hash probes bluetoothd opens with (the reason this client exists
// — see att_channel.dart) and secondary service discovery.
//
// THE OTHER DIRECTION
//
// On a raw ATT bearer nobody else answers the PEER's requests — bluetoothd's
// GATT server is not attached — and a peer left waiting times its own
// transaction out and drops the link. So the client carries a minimal ATT
// server with an empty database: it answers Exchange MTU properly and every
// other request with the error an empty server gives, immediately and
// independently of its own request queue (ATT allows one transaction in
// flight per direction).
//
// SECURITY ON DEMAND
//
// A link starts unencrypted. When the peer rejects a read or write with
// Insufficient Authentication / Encryption / Encryption Key Size, the
// client raises the link's security and retries that request once — what
// BlueZ's bt_att (change_security), Android's BluetoothGatt and iOS all do.
// Never before the peer asks: some peripherals (the LDM330 among them)
// support no LE encryption, and a pairing attempt only gets the link
// dropped. When raising fails, the request's answer is the peer's original
// error — "pair first" — even though the link is usually gone by then: a
// refused pairing tends to drop it, and a failed elevation closes it (see
// AttChannel.elevateSecurity).
import 'dart:async';
import 'dart:typed_data';

import 'att_channel.dart';
import 'att_pdu.dart';

/// Where this client's diagnostics go. Injected rather than tied to the
/// app's logger so the module stays free of Flutter imports and a plain
/// `dart run` probe can use it.
typedef AttLogger = void Function(String message);

/// The peer answered a request with an ATT Error Response.
class AttErrorException implements Exception {
  final int requestOpcode;
  final int handle;
  final int errorCode;
  const AttErrorException(this.requestOpcode, this.handle, this.errorCode);

  /// Whether the user should be told "pair first": the same codes as
  /// real_ble_service.dart's `_attPairingErrorCodes`. Deliberately NOT the
  /// set [AttClient] raises link security for (`_securityTarget`):
  /// authorization (0x08) is refused by the application, which encryption
  /// cannot fix, and a too-short key (0x0C) is fixed by re-encrypting, not
  /// by the user. Aligning the two would make this disagree with the UI.
  bool get needsPairing =>
      errorCode == AttError.insufficientAuthentication ||
      errorCode == AttError.insufficientAuthorization ||
      errorCode == AttError.insufficientEncryption;

  @override
  String toString() =>
      'AttErrorException(request 0x${requestOpcode.toRadixString(16)}, '
      'handle 0x${handle.toRadixString(16).padLeft(4, '0')}, '
      'error 0x${errorCode.toRadixString(16).padLeft(2, '0')})';
}

/// The peer never answered a request. Per the spec the bearer is unusable
/// after this, so the client has closed it.
class AttTimeoutException implements Exception {
  final int requestOpcode;
  const AttTimeoutException(this.requestOpcode);
  @override
  String toString() =>
      'AttTimeoutException(request 0x${requestOpcode.toRadixString(16)})';
}

/// The link went away before (or while) a request could be answered.
class AttLinkClosedException implements Exception {
  const AttLinkClosedException();
  @override
  String toString() => 'AttLinkClosedException';
}

/// A discovered descriptor.
class AttDescriptor {
  final int handle;
  final String uuid;
  const AttDescriptor(this.handle, this.uuid);
}

/// A discovered characteristic, with the handles needed to drive it.
class AttCharacteristic {
  final String uuid;
  final int declarationHandle;
  final int valueHandle;
  final int properties;
  final List<AttDescriptor> descriptors;

  const AttCharacteristic({
    required this.uuid,
    required this.declarationHandle,
    required this.valueHandle,
    required this.properties,
    required this.descriptors,
  });

  bool get canRead => properties & GattProperty.read != 0;
  bool get canWrite => properties & GattProperty.write != 0;
  bool get canWriteWithoutResponse =>
      properties & GattProperty.writeWithoutResponse != 0;
  bool get canNotify => properties & GattProperty.notify != 0;
  bool get canIndicate => properties & GattProperty.indicate != 0;

  /// The Client Characteristic Configuration descriptor's handle, or null
  /// when the characteristic has none (then it cannot be subscribed).
  int? get cccdHandle {
    final cccd = uuid16ToString(GattType.clientCharacteristicConfiguration);
    for (final d in descriptors) {
      if (d.uuid == cccd) return d.handle;
    }
    return null;
  }
}

/// A discovered service.
class AttService {
  final String uuid;
  final int startHandle;
  final int endHandle;
  final List<AttCharacteristic> characteristics;

  const AttService({
    required this.uuid,
    required this.startHandle,
    required this.endHandle,
    required this.characteristics,
  });
}

class _Pending {
  final Uint8List request;

  /// Whether an ATT error asking for security may raise the link and retry
  /// this request. True for reads and writes; false for discovery and MTU
  /// requests, and for a request that already is the retry.
  bool securable;

  /// While this request waits on a security elevation, the peer's answer
  /// that asked for it. If the link goes before the retry, this — "pair
  /// first" — is still the request's answer: a refused pairing usually
  /// drops the link, and the failure is the pairing, not the radio.
  AttErrorException? refusal;

  final Completer<Uint8List> completer = Completer<Uint8List>();
  Timer? timer;
  _Pending(this.request, {required this.securable});
  int get opcode => request[0];
}

/// A GATT client on one [AttChannel]. See the file comment.
class AttClient {
  final AttChannel _channel;
  final AttLogger _log;
  final Duration requestTimeout;

  /// The Rx MTU this side offers: in its own Exchange MTU Request, and in
  /// its answer to the peer's.
  final int localRxMtu;

  /// Whether an ATT error asking for security raises the link and retries.
  final bool elevateSecurityOnDemand;

  /// How long one security elevation (encryption or pairing) may take.
  final Duration securityTimeout;

  int _mtu = 23;
  final _mtuChanges = StreamController<int>.broadcast();

  final _queue = <_Pending>[];
  _Pending? _inFlight;
  final _notifications = StreamController<AttValueEvent>.broadcast();
  late final StreamSubscription<Uint8List> _incoming;
  bool _closing = false;

  /// One attempt per target level per client, shared by every request that
  /// asks for it; a failed attempt is remembered so later requests fail fast
  /// instead of asking the user to pair again.
  final Map<int, Future<bool>> _elevations = {};

  /// Requests waiting on an elevation before their retry. While any is
  /// waiting the pump sends nothing: the link is mid-SMP (on Linux the
  /// socket refuses sends until it ends), and the retry must go out before
  /// anything queued behind it.
  final List<_Pending> _parked = [];

  AttClient(
    this._channel, {
    AttLogger? log,
    this.requestTimeout = const Duration(seconds: 15),
    this.localRxMtu = attMaxMtu,
    this.elevateSecurityOnDemand = true,
    this.securityTimeout = const Duration(seconds: 30),
  }) : _log = log ?? ((_) {}) {
    if (localRxMtu < 23 || localRxMtu > attMaxMtu) {
      throw ArgumentError.value(localRxMtu, 'localRxMtu', 'must be 23..517');
    }
    _incoming = _channel.incoming.listen(
      _onPdu,
      onDone: _onLinkClosed,
      onError: (Object e) {
        _log('ATT channel error: $e');
        _onLinkClosed();
      },
    );
  }

  /// The ATT MTU in force: 23 until an Exchange MTU — ours ([exchangeMtu])
  /// or the peer's — raises it.
  int get mtu => _mtu;

  /// Each new [mtu], whichever side's exchange changed it. Broadcast.
  Stream<int> get mtuChanges => _mtuChanges.stream;

  void _setMtu(int value) {
    if (value == _mtu) return;
    _mtu = value;
    if (!_mtuChanges.isClosed) _mtuChanges.add(value);
  }

  /// Notifications and indications from the peer. Indications are
  /// confirmed automatically.
  Stream<AttValueEvent> get notifications => _notifications.stream;

  /// Completes when the bearer is gone.
  Future<void> get closed => _channel.closed;

  bool get isOpen => _channel.isOpen && !_closing;

  /// Ask for [clientRxMtu] (default [localRxMtu]); the link settles on the
  /// smaller of the two sides' values. A peer that does not support the
  /// exchange leaves the default in place rather than failing the link.
  Future<int> exchangeMtu([int? clientRxMtu]) async {
    final ours = clientRxMtu ?? localRxMtu;
    try {
      final rsp = await _request(AttEncode.exchangeMtu(ours));
      final server = AttDecode.exchangeMtu(rsp);
      _setMtu(_settledMtu(ours, server));
    } on AttErrorException catch (e) {
      if (e.errorCode != AttError.requestNotSupported) rethrow;
      _log('peer does not support MTU exchange; staying at $mtu');
    }
    return mtu;
  }

  static int _settledMtu(int a, int b) {
    final smaller = a < b ? a : b;
    return smaller < 23 ? 23 : smaller;
  }

  /// Walk the handle space: primary services, their characteristics, and
  /// the descriptors in the gaps between characteristics.
  Future<List<AttService>> discoverServices() async {
    final services = <AttService>[];
    for (final group in await _discoverPrimaryServices()) {
      final characteristics = await _discoverCharacteristics(group);
      services.add(
        AttService(
          uuid: group.uuid,
          startHandle: group.start,
          endHandle: group.end,
          characteristics: characteristics,
        ),
      );
    }
    return services;
  }

  // EVERY DISCOVERY LOOP BELOW MOVES ONLY FORWARD. Each continues from the
  // last handle its page ended on, so a peer that ignores the Starting
  // Handle — a canned first page, as some hand-rolled ATT servers send —
  // or answers with handles behind it would send the walk back to the same
  // place forever, every request answered, so no ATT timeout ever ends it.
  // Each keeps only what lies inside the range it asked for and stops when
  // nothing does, as BlueZ's gatt-helpers.c does ("otherwise we might enter
  // infinite loop"); BlueZ fails the walk there, this keeps what it found.

  Future<List<AttGroupEntry>> _discoverPrimaryServices() async {
    final groups = <AttGroupEntry>[];
    var start = 0x0001;
    while (start <= 0xFFFF) {
      final Uint8List rsp;
      try {
        rsp = await _request(
          AttEncode.readByGroupType(start, 0xFFFF, GattType.primaryService),
        );
      } on AttErrorException catch (e) {
        if (e.errorCode == AttError.attributeNotFound) break;
        rethrow;
      }
      final entries = [
        for (final e in AttDecode.readByGroupType(rsp))
          if (e.start >= start && e.end >= e.start) e,
      ];
      if (entries.isEmpty) break;
      groups.addAll(entries);
      final last = entries.last.end;
      if (last >= 0xFFFF || last < start) break;
      start = last + 1;
    }
    return groups;
  }

  Future<List<AttCharacteristic>> _discoverCharacteristics(
    AttGroupEntry service,
  ) async {
    final decls =
        <({int handle, int properties, int valueHandle, String uuid})>[];
    var start = service.start;
    while (start <= service.end) {
      final Uint8List rsp;
      try {
        rsp = await _request(
          AttEncode.readByType(start, service.end, GattType.characteristic),
        );
      } on AttErrorException catch (e) {
        if (e.errorCode == AttError.attributeNotFound) break;
        rethrow;
      }
      final entries = [
        for (final e in AttDecode.readByType(rsp))
          if (e.handle >= start && e.handle <= service.end) e,
      ];
      if (entries.isEmpty) break;
      for (final e in entries) {
        final decl = AttDecode.characteristicDecl(e.value);
        decls.add((
          handle: e.handle,
          properties: decl.properties,
          valueHandle: decl.valueHandle,
          uuid: decl.uuid,
        ));
      }
      final lastValue = decls.last.valueHandle;
      if (lastValue >= service.end || lastValue < start) break;
      start = lastValue + 1;
    }

    final characteristics = <AttCharacteristic>[];
    for (var i = 0; i < decls.length; i++) {
      final decl = decls[i];
      // Descriptors live between this characteristic's value and the next
      // declaration (or the service end). An empty range means none, and
      // asking would only earn an error — or, on some firmware, silence.
      final descStart = decl.valueHandle + 1;
      final descEnd = i + 1 < decls.length
          ? decls[i + 1].handle - 1
          : service.end;
      final descriptors = descStart <= descEnd
          ? await _discoverDescriptors(descStart, descEnd)
          : const <AttDescriptor>[];
      characteristics.add(
        AttCharacteristic(
          uuid: decl.uuid,
          declarationHandle: decl.handle,
          valueHandle: decl.valueHandle,
          properties: decl.properties,
          descriptors: descriptors,
        ),
      );
    }
    return characteristics;
  }

  Future<List<AttDescriptor>> _discoverDescriptors(int start, int end) async {
    final descriptors = <AttDescriptor>[];
    var next = start;
    while (next <= end) {
      final Uint8List rsp;
      try {
        rsp = await _request(AttEncode.findInformation(next, end));
      } on AttErrorException catch (e) {
        if (e.errorCode == AttError.attributeNotFound) break;
        rethrow;
      }
      final entries = [
        for (final e in AttDecode.findInformation(rsp))
          if (e.handle >= next && e.handle <= end) e,
      ];
      if (entries.isEmpty) break;
      for (final e in entries) {
        descriptors.add(AttDescriptor(e.handle, e.uuid));
      }
      final last = entries.last.handle;
      if (last >= end || last < next) break;
      next = last + 1;
    }
    return descriptors;
  }

  /// Read an attribute's whole value, continuing with Read Blob when the
  /// first response fills the MTU — up to [attMaxAttributeLength] bytes.
  ///
  /// No attribute is longer than that, so the read stops there whatever the
  /// peer sends: one whose handler ignores the Read Blob offset answers
  /// every piece with the same MTU-1 bytes, and nothing else would ever end
  /// the loop — or free whoever awaits it — short of the link dropping.
  /// BlueZ (gatt-client.c, BT_ATT_MAX_VALUE_LEN) and Android
  /// (GATT_MAX_ATTR_LEN) cap it the same way.
  Future<Uint8List> read(int handle) async {
    const cap = attMaxAttributeLength;
    final first = AttDecode.read(await _secured(AttEncode.read(handle)));
    if (first.length >= cap) return first.sublist(0, cap);
    if (first.length < mtu - 1) return first;
    final value = BytesBuilder(copy: false)..add(first);
    while (value.length < cap) {
      final Uint8List part;
      try {
        part = AttDecode.readBlob(
          await _secured(AttEncode.readBlob(handle, value.length)),
        );
      } on AttErrorException catch (e) {
        // "Attribute not long": the value was exactly MTU-1 bytes and the
        // peer has nothing more. "Invalid offset" says the same.
        if (e.errorCode == AttError.attributeNotLong ||
            e.errorCode == AttError.invalidOffset) {
          break;
        }
        rethrow;
      }
      if (part.isEmpty) break;
      value.add(part);
      if (part.length < mtu - 1) break;
    }
    final bytes = value.takeBytes();
    return bytes.length > cap ? bytes.sublist(0, cap) : bytes;
  }

  /// Write with response. A value that does not fit one Write Request
  /// (MTU-3 bytes) goes as a long write: Prepare Write pieces, each echo
  /// checked, then one Execute Write.
  ///
  /// [secure]: whether an ATT error asking for security raises the link
  /// and retries (see the file comment). False for a best-effort write that
  /// must never start a pairing — the Service Changed CCCD, say, on a peer
  /// that may support no LE encryption at all: the error is then simply the
  /// answer.
  Future<void> write(int handle, List<int> value, {bool secure = true}) async {
    // No attribute is longer (Vol 3 Part F 3.2.9), and past 0xFFFF bytes a
    // Prepare Write's 16-bit offset would wrap: refused here, before a
    // lenient peer can commit an oversize value, as BlueZ and Android refuse
    // it locally.
    if (value.length > attMaxAttributeLength) {
      throw ArgumentError.value(
        value.length,
        'value.length',
        'an attribute value is at most $attMaxAttributeLength bytes',
      );
    }
    if (value.length <= mtu - 3) {
      AttDecode.writeResponse(
        await _send(AttEncode.write(handle, value), secure: secure),
      );
      return;
    }
    await _longWrite(handle, value, secure: secure);
  }

  Future<void> _longWrite(
    int handle,
    List<int> value, {
    required bool secure,
  }) async {
    // A Prepare Write carries opcode, handle and offset: MTU-5 value bytes.
    // Sized per piece from the current MTU: the peer's own Exchange MTU
    // Request can LOWER it mid-write (_serve follows the latest exchange, as
    // bt_att does), and a piece sized for the old MTU would then overrun
    // the bearer.
    var queued = false;
    try {
      var offset = 0;
      while (offset < value.length) {
        final room = mtu - 5;
        final end = offset + room < value.length ? offset + room : value.length;
        final part = value.sublist(offset, end);
        final echo = AttDecode.prepareWrite(
          await _send(
            AttEncode.prepareWrite(handle, offset, part),
            secure: secure,
          ),
        );
        queued = true;
        // The echo is the server's receipt for what it queued (3.4.6.2); a
        // mismatch means the bytes it would commit are not ours.
        if (echo.handle != handle ||
            echo.offset != offset ||
            !_sameBytes(echo.value, part)) {
          throw AttFormatException(
            'prepare write echo for 0x${handle.toRadixString(16)} at '
            'offset $offset does not match what was sent',
          );
        }
        offset = end;
      }
    } catch (_) {
      // Leave nothing half-written in the server's queue for the next long
      // write to commit by accident.
      if (queued && isOpen) {
        try {
          AttDecode.executeWriteResponse(
            await _request(AttEncode.executeWrite(commit: false)),
          );
        } catch (e) {
          _log('could not cancel the prepared write: $e');
        }
      }
      rethrow;
    }
    AttDecode.executeWriteResponse(
      await _send(AttEncode.executeWrite(commit: true), secure: secure),
    );
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Write without response: fire and forget on the wire. There is no long
  /// form of a command, so a value longer than MTU-3 bytes is refused
  /// ([ArgumentError]) rather than truncated.
  void writeWithoutResponse(int handle, List<int> value) {
    _ensureOpen();
    if (value.length > mtu - 3) {
      throw ArgumentError.value(
        value.length,
        'value.length',
        'a write without response carries at most MTU-3 (${mtu - 3}) bytes',
      );
    }
    _channel.send(AttEncode.writeCommand(handle, value));
  }

  /// Set a characteristic's CCCD: 0x0001 notifications, 0x0002
  /// indications, 0x0000 neither. Raised on demand like any [write]; a
  /// best-effort one that must never pair is `write(..., secure: false)`.
  Future<void> writeCccd(int cccdHandle, int flags) =>
      write(cccdHandle, [flags & 0xFF, (flags >> 8) & 0xFF]);

  /// Tear the bearer down, failing anything still queued.
  Future<void> close() async {
    if (_closing) return _channel.closed;
    _closing = true;
    await _channel.close();
    _onLinkClosed();
  }

  void _ensureOpen() {
    if (!isOpen) throw const AttLinkClosedException();
  }

  /// A request that is never retried after a security elevation:
  /// discovery and MTU.
  Future<Uint8List> _request(Uint8List pdu) => _enqueue(pdu, securable: false);

  /// A read or write: an ATT error asking for security raises the link and
  /// retries it once (see the file comment).
  Future<Uint8List> _secured(Uint8List pdu) => _send(pdu, secure: true);

  /// A read or write that raises the link on demand only when [secure].
  Future<Uint8List> _send(Uint8List pdu, {required bool secure}) =>
      _enqueue(pdu, securable: secure && elevateSecurityOnDemand);

  Future<Uint8List> _enqueue(Uint8List pdu, {required bool securable}) {
    _ensureOpen();
    final pending = _Pending(pdu, securable: securable);
    _queue.add(pending);
    _pump();
    return pending.completer.future;
  }

  void _pump() {
    if (_inFlight != null || _parked.isNotEmpty || _queue.isEmpty) return;
    final next = _queue.removeAt(0);
    _inFlight = next;
    try {
      _channel.send(next.request);
    } catch (e) {
      _inFlight = null;
      // A send into a link that is gone (the channel says so at once) is a
      // lost link like any other; one the live socket refused — mid-pairing,
      // say — is this request's own failure.
      next.completer.completeError(
        _channel.isOpen ? e : const AttLinkClosedException(),
      );
      _pump();
      return;
    }
    next.timer = Timer(requestTimeout, () => _onTimeout(next));
  }

  void _onTimeout(_Pending pending) {
    if (!identical(_inFlight, pending)) return;
    _log(
      'request 0x${pending.opcode.toRadixString(16)} unanswered after '
      '${requestTimeout.inSeconds}s; the ATT bearer is dead by spec, '
      'closing it',
    );
    _inFlight = null;
    pending.completer.completeError(AttTimeoutException(pending.opcode));
    // Vol 3 Part F, 3.3.3: after a transaction timeout nothing more may be
    // sent on this bearer. Closing it is what bluetoothd does too; the
    // difference is that this client never sends the request that made the
    // meter go quiet in the first place.
    unawaited(close());
  }

  void _onPdu(Uint8List pdu) {
    if (pdu.isEmpty) return;
    final AttValueEvent? event;
    try {
      event = AttDecode.valueEvent(pdu);
    } on AttFormatException catch (e) {
      _log('dropping malformed PDU: $e');
      return;
    }
    if (event != null) {
      if (event.isIndication && _channel.isOpen) {
        try {
          _channel.send(AttEncode.handleValueConfirmation());
        } catch (e) {
          _log('could not confirm indication: $e');
        }
      }
      _notifications.add(event);
      return;
    }
    final op = pdu[0];
    if (AttDecode.isRequest(op)) {
      _serve(pdu);
      return;
    }
    if (AttDecode.isCommand(op) ||
        op == AttOpcode.handleValueConfirmation ||
        op == AttOpcode.multipleHandleValueNotification) {
      // A command needs no answer and ours has no database to apply it to
      // (3.3.1: ignore); a confirmation can only answer an indication, and
      // this side never indicates.
      _log('ignoring peer PDU 0x${op.toRadixString(16)}');
      return;
    }
    final int? answers;
    try {
      answers = AttDecode.requestOpcodeOf(pdu);
    } on AttFormatException catch (e) {
      _log('dropping malformed PDU: $e');
      return;
    }
    if (answers == null) {
      // Not a response, event or command: an opcode this side does not
      // know. BlueZ's bt_att answers those as unsupported requests too.
      _serve(pdu);
      return;
    }
    final inFlight = _inFlight;
    if (inFlight == null || answers != inFlight.opcode) {
      // A late or duplicate response. Dropping it — rather than failing the
      // request in flight — is the lesson of bluez/bluez#2486.
      _log(
        'ignoring unexpected PDU 0x${op.toRadixString(16)}'
        ' (answers 0x${answers.toRadixString(16)})'
        ' with ${inFlight == null ? 'nothing' : '0x${inFlight.opcode.toRadixString(16)}'} in flight',
      );
      return;
    }
    inFlight.timer?.cancel();
    _inFlight = null;
    if (op == AttOpcode.errorResponse) {
      final err = AttDecode.error(pdu);
      final error = AttErrorException(
        err.requestOpcode,
        err.handle,
        err.errorCode,
      );
      final target = inFlight.securable ? _securityTarget(err.errorCode) : null;
      if (target != null) {
        // Parked synchronously, before _pump below can send what is queued
        // behind it: nothing goes out until the elevation is decided and
        // the retry is at the head of the queue.
        _elevateAndRetry(inFlight, error, target);
      } else {
        inFlight.completer.completeError(error);
      }
    } else {
      inFlight.completer.complete(pdu);
    }
    _pump();
  }

  /// The security level to raise the link to for ATT [errorCode], or null
  /// when raising cannot help. Insufficient Authentication on an
  /// unencrypted link and Insufficient Encryption / Key Size both mean
  /// "encrypt" (level 2); Insufficient Authentication on an encrypted link
  /// means the key must be MITM-protected (level 3). Encryption errors on an
  /// already-encrypted link have no higher level to try.
  int? _securityTarget(int errorCode) {
    if (errorCode != AttError.insufficientAuthentication &&
        errorCode != AttError.insufficientEncryption &&
        errorCode != AttError.encryptionKeySizeInsufficient) {
      return null;
    }
    final level = _channel.securityLevel;
    if (level < 2) return 2;
    if (errorCode == AttError.insufficientAuthentication && level < 3) {
      return 3;
    }
    return null;
  }

  void _elevateAndRetry(_Pending pending, AttErrorException error, int target) {
    pending.refusal = error;
    _parked.add(pending);
    final attempt = _elevations.putIfAbsent(target, () {
      _log(
        'peer answered 0x${error.requestOpcode.toRadixString(16)} with '
        '0x${error.errorCode.toRadixString(16).padLeft(2, '0')} '
        '(${AttError.describe(error.errorCode)}); raising the link to '
        'security level $target',
      );
      return _channel
          .elevateSecurity(target, timeout: securityTimeout)
          .catchError((Object e) {
            _log('security elevation failed: $e');
            return false;
          });
    });
    unawaited(
      attempt.then((ok) {
        if (!_parked.remove(pending)) return; // the link closed meanwhile
        if (ok && isOpen) {
          _log(
            'link at security level ${_channel.securityLevel}; retrying '
            '0x${pending.opcode.toRadixString(16)}',
          );
          pending.securable = false; // once
          pending.refusal = null; // raised: a loss from here is just a loss
          _queue.insert(0, pending);
        } else {
          _log('could not raise the link to level $target');
          pending.completer.completeError(error);
        }
        _pump();
      }),
    );
  }

  /// Answer a request from the PEER as a server with an empty database
  /// would (see the file comment). Sent straight to the channel: it is the
  /// other direction's transaction and must not wait behind ours.
  void _serve(Uint8List pdu) {
    final op = pdu[0];
    // The first handle a request names (a range's start, or the attribute
    // it reads or writes): what an Error Response reports as "in error".
    final handle = pdu.length >= 3 ? pdu[1] | (pdu[2] << 8) : 0;
    Uint8List error(int code) => AttEncode.errorResponse(op, handle, code);
    final Uint8List response;
    switch (op) {
      case AttOpcode.exchangeMtuRequest:
        if (pdu.length < 3) {
          response = error(AttError.invalidPdu);
          break;
        }
        final peerRxMtu = handle; // the same two bytes, by layout
        response = AttEncode.exchangeMtuResponse(localRxMtu);
        _setMtu(_settledMtu(peerRxMtu, localRxMtu));
      case AttOpcode.findInformationRequest:
      case AttOpcode.findByTypeValueRequest:
      case AttOpcode.readByTypeRequest:
      case AttOpcode.readByGroupTypeRequest:
        final end = pdu.length >= 5 ? pdu[3] | (pdu[4] << 8) : 0;
        // A range starting at 0 or ending before it starts is the one
        // malformed range the spec names an error for (3.4.3.1 et al.).
        response = error(
          pdu.length < 5
              ? AttError.invalidPdu
              : handle == 0 || handle > end
              ? AttError.invalidHandle
              : AttError.attributeNotFound,
        );
      case AttOpcode.readRequest:
      case AttOpcode.readBlobRequest:
      case AttOpcode.readMultipleRequest:
      case AttOpcode.readMultipleVariableRequest:
      case AttOpcode.writeRequest:
      case AttOpcode.prepareWriteRequest:
        response = error(AttError.invalidHandle);
      case AttOpcode.executeWriteRequest:
        // Nothing can have been queued: every Prepare Write was refused.
        response = Uint8List.fromList([AttOpcode.executeWriteResponse]);
      default:
        response = AttEncode.errorResponse(op, 0, AttError.requestNotSupported);
    }
    _log(
      'answered peer request 0x${op.toRadixString(16)} with '
      '0x${response[0].toRadixString(16)}'
      '${response[0] == AttOpcode.errorResponse ? ' (${AttError.describe(response[4])})' : ''}',
    );
    if (!_channel.isOpen) return;
    try {
      _channel.send(response);
    } catch (e) {
      _log('could not answer peer request 0x${op.toRadixString(16)}: $e');
    }
  }

  void _onLinkClosed() {
    final inFlight = _inFlight;
    _inFlight = null;
    inFlight?.timer?.cancel();
    if (inFlight != null && !inFlight.completer.isCompleted) {
      inFlight.completer.completeError(const AttLinkClosedException());
    }
    // A request parked on an elevation keeps the answer that asked for it:
    // the link going mid-pairing is, as a rule, the pairing failing (see
    // _Pending.refusal).
    for (final pending in [..._parked, ..._queue]) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          pending.refusal ?? const AttLinkClosedException(),
        );
      }
    }
    _parked.clear();
    _queue.clear();
    unawaited(_incoming.cancel());
    if (!_notifications.isClosed) unawaited(_notifications.close());
    if (!_mtuChanges.isClosed) unawaited(_mtuChanges.close());
  }
}
