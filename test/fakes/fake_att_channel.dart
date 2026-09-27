// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A scripted ATT peripheral behind the [AttChannel] seam: a handle table and
// enough of an ATT server to answer what a GATT client sends, so
// lib/services/direct_att/ runs for real in `flutter test` — discovery walk,
// request/response pairing, long writes, security on demand, notifications,
// the peer's own requests — against a device that answers like hardware
// does, including the ways some hardware does not.
//
// The default peripheral is spec-compliant and empty; tests build the table
// they need with the builders. [FakeAttPeripheral.ldm330] is the one preset:
// the Johnson LDM330 laser meter this path was written for, transcribed
// handle-for-handle from captures/jlx/setup-and-capture.pcapng, and — unlike
// the default — silent on a Read By Type for Server Supported Features
// (0x2b3a) and Database Hash (0x2b2a), exactly as the real one is, which is
// how a test can prove the client never sends those requests.
//
// The fake is also a referee. What a real peripheral would punish with
// silence or a dropped link is recorded in [FakeAttPeripheral.violations]
// instead — a request sent before the previous one was answered, a PDU over
// the link's MTU, a request sent mid-pairing — so a test can assert the list
// is empty and catch the regression the moment it is written.
//
// Link state is per link, as on hardware: every new [FakeAttChannel] starts
// at MTU 23, security level 1, and (unless the peripheral is bonded) every
// CCCD at 0, so a reconnect can never inherit what the last link negotiated.
// And the CCCDs mean something: a characteristic that has one notifies or
// indicates only once the client has set the bit for it, as a compliant
// server does (Vol 3 Part G 3.3.3.3) — so a test that forgets to subscribe,
// Service Changed included, hears nothing, exactly as on hardware.
//
// The channel side is the production channel's contract, kernel quirks
// included: while pairing runs, sends fail with ENOTCONN as a socket in
// BT_CONFIG does, and a failed pairing closes the channel as
// L2capAttChannel.elevateSecurity does.

import 'dart:async';
import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/direct_att/att_channel.dart';
import 'package:liberated_bread_mobile/services/direct_att/att_pdu.dart';

/// One attribute in the fake's table.
class FakeAttAttribute {
  final int handle;
  final String type;
  Uint8List value;
  final bool readable;
  final bool writable;

  /// The ATT error to answer reads/writes with instead of serving them.
  int? accessError;

  /// The link security level (see [AttChannel.securityLevel]) below which
  /// reads and writes are refused with [securityError].
  int? requiredSecurity;

  /// What a too-weak link is told: 0x05 insufficient authentication by
  /// default, or 0x0F insufficient encryption / 0x0C key size.
  int securityError;

  FakeAttAttribute({
    required this.handle,
    required this.type,
    required List<int> value,
    this.readable = true,
    this.writable = false,
    this.accessError,
    this.requiredSecurity,
    this.securityError = AttError.insufficientAuthentication,
  }) : value = Uint8List.fromList(value);
}

/// A write the peripheral applied: a Write Request, a Write Command, or a
/// whole committed long write (one entry per attribute).
typedef FakeAttWrite = ({int handle, List<int> value, bool withResponse});

/// What a Read Blob at a non-zero offset gets on an attribute short enough
/// to have fitted one Read Response (<= MTU-1 bytes). Servers differ: many
/// serve the tail, some answer Attribute Not Long.
enum FakeBlobOnShortAttribute { data, attributeNotLong }

/// One Prepare Write queued on the link.
typedef _Prepared = ({int handle, int offset, Uint8List value});

/// A request the PEER sent the client, awaiting the client's answer.
typedef _PeerRequest = ({Uint8List pdu, Completer<Uint8List> answer});

/// The peripheral: an attribute table and an ATT server over it.
class FakeAttPeripheral {
  final Map<int, FakeAttAttribute> attributes = {};

  /// What the peripheral's side of the MTU exchange says.
  int serverRxMtu;

  /// The MTU in force on the current link (23 until an exchange raises it;
  /// back to 23 on every new link).
  int mtu = 23;

  /// Attribute types the peripheral never answers a Read By Type for — no
  /// response, no error, nothing. Empty (compliant) unless a test or the
  /// [FakeAttPeripheral.ldm330] preset opts in.
  final Set<int> silentReadByTypes;

  /// Request opcodes the peripheral swallows entirely.
  final Set<int> silentOpcodes = {};

  /// Answer the MTU exchange with "request not supported", as a pre-4.2
  /// peripheral does.
  bool refusesMtuExchange = false;

  /// How long every response takes to arrive. Zero delivers on a later
  /// microtask, as a socket would at the earliest.
  Duration responseLatency = Duration.zero;

  /// Whether Prepare/Execute Write (long writes) are supported; when not,
  /// both are answered Request Not Supported.
  bool supportsQueuedWrites = true;

  /// Echo every Prepare Write with its first byte flipped — the corruption
  /// the echo exists to catch.
  bool corruptsPrepareWriteEcho = false;

  /// See [FakeBlobOnShortAttribute].
  FakeBlobOnShortAttribute blobOnShortAttribute = FakeBlobOnShortAttribute.data;

  /// Answer every Read Blob with the value's first MTU-1 bytes whatever the
  /// offset asked — a read handler that ignores ValueOffset. A client with
  /// no cap on a long read never reaches the end.
  bool blobIgnoresOffset = false;

  /// Answer Read By Group Type, Read By Type and Find Information from the
  /// start of the table (handle 0x0001, up to the End Handle asked)
  /// whatever Starting Handle was asked — a canned page, as some hand-rolled
  /// ATT servers send. A client that trusts the page to move it forward
  /// asks for the same handles forever.
  bool ignoresStartHandle = false;

  /// Notify and indicate whatever the CCCD says, as firmware that never
  /// consults its own does. Off (compliant) by default: see [notify].
  bool ignoresCccd = false;

  /// The current link's security level (1 on every new link; see
  /// [AttChannel.securityLevel]).
  int linkSecurity = 1;

  /// Whether a pairing ([AttChannel.elevateSecurity]) succeeds. When not,
  /// the elevation completes false and the channel closes, as the
  /// production channel closes a socket its failed elevation left stuck in
  /// BT_CONFIG. (A PEER refusing pairing makes the kernel drop the link
  /// instead: [dropLink] with EACCES, 13, mid-[pairingDelay].)
  bool acceptsPairing = true;

  /// How long pairing takes to succeed or be refused. Meanwhile the
  /// channel refuses sends with ENOTCONN (107) as a socket in BT_CONFIG
  /// does — until pairing ends, or until the peer sends a PDU, which the
  /// kernel takes as the channel being ready again (l2cap_chan_ready).
  Duration pairingDelay = Duration.zero;

  /// Whether the kernel turns an elevation down before it starts
  /// (setsockopt(BT_SECURITY) failing at once — a link with no SMP channel,
  /// say). The elevation completes false at once and, nothing having
  /// changed state, the link stays up.
  bool smpUnavailable = false;

  /// Whether the peripheral holds a bond with the client: set by a
  /// successful pairing, and what keeps CCCD values across links.
  bool bonded = false;

  /// Every security level the client asked the link for, in order.
  final List<int> elevations = [];

  /// Whether the peripheral advertises with a random address. A connect
  /// with the other address type never reaches it.
  bool randomAddress;

  /// Every request PDU received, in order (commands are in [commands]).
  final List<Uint8List> requests = [];

  /// Every command PDU received (Write Command, Signed Write Command).
  final List<Uint8List> commands = [];

  /// Every write applied, in order.
  final List<FakeAttWrite> writes = [];

  /// Handle Value Confirmations received.
  int confirmations = 0;

  /// Protocol violations by the client (see the file comment). Kept across
  /// links, so one assertion at the end of a test covers all of them.
  final List<String> violations = [];

  /// Every PDU the client sent answering one of the peripheral's own
  /// requests ([sendRequestToClient]), in order.
  final List<Uint8List> clientResponses = [];

  /// The Service Changed value handle, once [gattService] has built one.
  int? serviceChangedHandle;

  /// The Service Changed CCCD's handle, once [gattService] has built one:
  /// what a client must set to 0x0002 before [indicateServiceChanged]
  /// reaches it.
  int? serviceChangedCccdHandle;

  FakeAttChannel? _channel;

  // Per-link server state, reset by _attach.
  int? _unanswered;
  bool _elevating = false;
  final List<_Prepared> _prepareQueue = [];
  final List<_PeerRequest> _peerRequests = [];

  FakeAttPeripheral({
    this.serverRxMtu = 23,
    Set<int>? silentReadByTypes,
    this.randomAddress = false,
  }) : silentReadByTypes = silentReadByTypes ?? {};

  /// The Read By Type targets the LDM330 never answers: Server Supported
  /// Features and Database Hash, the probes bluetoothd opens with.
  static const Set<int> ldm330SilentReadByTypes = {0x2b3a, 0x2b2a};

  /// The LDM330's GATT table, handle for handle, with its silence quirk.
  factory FakeAttPeripheral.ldm330({int serverRxMtu = 23}) {
    final p = FakeAttPeripheral(
      serverRxMtu: serverRxMtu,
      silentReadByTypes: {...ldm330SilentReadByTypes},
    );
    p
      ..service(0x0001, 0x0007, 0x1800)
      ..characteristic(
        0x0002,
        0x0003,
        0x02,
        0x2a00,
        'Laser Distance Meter'.codeUnits,
      )
      ..characteristic(0x0004, 0x0005, 0x02, 0x2a01, const [0x00, 0x00])
      ..characteristic(0x0006, 0x0007, 0x02, 0x2a04, const [
        0x50,
        0x00,
        0xa0,
        0x00,
        0x00,
        0x00,
        0xe8,
        0x03,
      ])
      ..service(0x0010, 0x001c, 0x180a)
      ..characteristic(0x0011, 0x0012, 0x02, 0x2a29, 'Precaster'.codeUnits)
      ..characteristic(0x0013, 0x0014, 0x02, 0x2a24, 'BT A8105'.codeUnits)
      ..characteristic(0x0015, 0x0016, 0x02, 0x2a25, '00001'.codeUnits)
      ..characteristic(0x0017, 0x0018, 0x02, 0x2a27, 'A810501'.codeUnits)
      ..characteristic(0x0019, 0x001a, 0x02, 0x2a26, '0001'.codeUnits)
      ..characteristic(0x001b, 0x001c, 0x02, 0x2a28, '1000'.codeUnits)
      ..service(0x002a, 0x002c, 0x1803)
      ..characteristic(0x002b, 0x002c, 0x0a, 0x2a06, const [0x00])
      ..service(0x002d, 0x002f, 0x1802)
      ..characteristic(0x002e, 0x002f, 0x04, 0x2a06, const [0x00])
      ..service(0x0030, 0x0033, 0x1804)
      ..characteristic(0x0031, 0x0032, 0x12, 0x2a07, const [0x00])
      ..descriptor(0x0033, 0x2902)
      ..service(0x0034, 0x0037, 0x180f)
      ..characteristic(0x0035, 0x0036, 0x12, 0x2a19, const [100])
      ..descriptor(0x0037, 0x2902)
      ..service(0x0039, 0x003e, 0x180d)
      ..characteristic(0x003a, 0x003b, 0x10, 0x2a37, const [])
      ..descriptor(0x003c, 0x2902)
      ..characteristic(0x003d, 0x003e, 0x02, 0x2a38, const [0x01])
      ..service(0x0050, 0x0055, 0xf150)
      ..characteristic(0x0051, 0x0052, 0x10, 0xf154, const [])
      ..descriptor(0x0053, 0x2902)
      ..characteristic(0x0054, 0x0055, 0x0c, 0xf151, const [])
      ..service(0x0060, 0x0065, 0xfff3)
      ..characteristic(0x0061, 0x0062, 0x10, 0xfff4, const [])
      ..descriptor(0x0063, 0x2902)
      ..characteristic(0x0064, 0x0065, 0x0c, 0xfff5, const []);
    return p;
  }

  /// The LDM330's f154 notify value handle and f151 command value handle.
  static const int ldm330DataHandle = 0x0052;
  static const int ldm330DataCccd = 0x0053;
  static const int ldm330CommandHandle = 0x0055;

  // ---- table builders -------------------------------------------------

  /// A primary service declaration at [start] covering [start]..[end], its
  /// UUID [uuid16] — or [uuid128] when given (then [uuid16] is ignored).
  void service(int start, int end, int uuid16, {String? uuid128}) {
    attributes[start] = FakeAttAttribute(
      handle: start,
      type: uuid16ToString(GattType.primaryService),
      value: uuid128 == null ? _le16(uuid16) : _uuid128Bytes(uuid128),
    );
    _serviceEnds[start] = end;
  }

  /// A characteristic: its declaration at [declHandle] and its value at
  /// [valueHandle], readable/writable as [properties] say.
  void characteristic(
    int declHandle,
    int valueHandle,
    int properties,
    int uuid16,
    List<int> value, {
    String? uuid128,
    int? accessError,
    int? requiredSecurity,
    int securityError = AttError.insufficientAuthentication,
  }) {
    final uuidBytes = uuid128 == null ? _le16(uuid16) : _uuid128Bytes(uuid128);
    attributes[declHandle] = FakeAttAttribute(
      handle: declHandle,
      type: uuid16ToString(GattType.characteristic),
      value: [properties, valueHandle & 0xff, valueHandle >> 8, ...uuidBytes],
    );
    attributes[valueHandle] = FakeAttAttribute(
      handle: valueHandle,
      type: uuid128?.toLowerCase() ?? uuid16ToString(uuid16),
      value: value,
      readable: properties & GattProperty.read != 0,
      writable:
          properties &
              (GattProperty.write | GattProperty.writeWithoutResponse) !=
          0,
      accessError: accessError,
      requiredSecurity: requiredSecurity,
      securityError: securityError,
    );
  }

  /// A descriptor at [handle] of type [uuid16] — or [uuid128] when given
  /// (then [uuid16] is ignored). Readable and writable.
  void descriptor(
    int handle,
    int uuid16, {
    List<int> value = const [0, 0],
    String? uuid128,
    int? accessError,
    int? requiredSecurity,
    int securityError = AttError.insufficientAuthentication,
  }) {
    attributes[handle] = FakeAttAttribute(
      handle: handle,
      type: uuid128?.toLowerCase() ?? uuid16ToString(uuid16),
      value: value,
      writable: true,
      accessError: accessError,
      requiredSecurity: requiredSecurity,
      securityError: securityError,
    );
  }

  /// The GATT service (0x1801) at [start]..[start]+3: the service, a
  /// Service Changed characteristic (indicate only; value at [start]+2,
  /// kept in [serviceChangedHandle]) and its CCCD at [start]+3.
  void gattService(int start) {
    service(start, start + 3, GattType.genericAttribute);
    characteristic(
      start + 1,
      start + 2,
      GattProperty.indicate,
      GattType.serviceChanged,
      const [0, 0, 0, 0],
    );
    descriptor(start + 3, GattType.clientCharacteristicConfiguration);
    serviceChangedHandle = start + 2;
    serviceChangedCccdHandle = start + 3;
  }

  final Map<int, int> _serviceEnds = {};

  // ---- peer-initiated traffic -----------------------------------------

  /// Push a notification (or indication) for [handle] to the connected
  /// client, cut to MTU-3 bytes as a real server must. Nothing happens when
  /// nobody is connected — nor, as on a compliant server, when [handle]'s
  /// characteristic has a CCCD whose bit for this (0x0001 notify, 0x0002
  /// indicate) the client has not set on this link. A characteristic with
  /// no CCCD delivers anyway: firmware that notifies without one exists.
  /// [ignoresCccd] delivers regardless.
  void notify(int handle, List<int> value, {bool indicate = false}) {
    final cccdHandle = ignoresCccd ? null : cccdHandleOf(handle);
    if (cccdHandle != null && cccd(cccdHandle) & (indicate ? 2 : 1) == 0) {
      return;
    }
    final room = mtu - 3;
    final pdu = Uint8List.fromList([
      indicate
          ? AttOpcode.handleValueIndication
          : AttOpcode.handleValueNotification,
      handle & 0xff,
      handle >> 8,
      ...(value.length > room ? value.sublist(0, room) : value),
    ]);
    _channel?.deliver(pdu);
  }

  /// Indicate Service Changed for [start]..[end]: "the attributes in this
  /// range are not what you discovered". Needs [gattService], and reaches
  /// the client only once it has enabled indications on
  /// [serviceChangedCccdHandle] (see [notify]).
  void indicateServiceChanged(int start, int end) {
    final handle = serviceChangedHandle;
    if (handle == null) {
      throw StateError('no Service Changed characteristic: call gattService');
    }
    notify(handle, [..._le16(start), ..._le16(end)], indicate: true);
  }

  /// Send the client a request of the peripheral's own (Exchange MTU,
  /// discovery, a read...) — what a peripheral acting as a GATT client
  /// does. Completes with the client's answer: the next PDU it sends that
  /// answers [pdu]'s opcode (a response, an Error Response, or for an
  /// indication its confirmation). Fails if the link goes first.
  Future<Uint8List> sendRequestToClient(List<int> pdu) {
    final channel = _channel;
    if (channel == null || !channel.isOpen) {
      throw StateError('no client connected');
    }
    final bytes = Uint8List.fromList(pdu);
    final answer = Completer<Uint8List>();
    _peerRequests.add((pdu: bytes, answer: answer));
    channel.deliver(bytes);
    return answer.future;
  }

  /// The CCCD value the client has written for [cccdHandle] (0 when none).
  int cccd(int cccdHandle) {
    final v = attributes[cccdHandle]?.value;
    if (v == null || v.length < 2) return 0;
    return v[0] | (v[1] << 8);
  }

  /// The CCCD of the characteristic whose value is at [valueHandle]: the
  /// first 0x2902 after the value and before the next declaration. Null
  /// when it has none, or [valueHandle] is no characteristic's value.
  int? cccdHandleOf(int valueHandle) {
    final declType = uuid16ToString(GattType.characteristic);
    final isValue = attributes.values.any(
      (a) =>
          a.type == declType &&
          a.value.length >= 3 &&
          _u16(a.value, 1) == valueHandle,
    );
    if (!isValue) return null;
    final ends = {
      declType,
      uuid16ToString(GattType.primaryService),
      uuid16ToString(GattType.secondaryService),
      uuid16ToString(GattType.include),
    };
    final cccdType = uuid16ToString(GattType.clientCharacteristicConfiguration);
    for (final a in _sorted()) {
      if (a.handle <= valueHandle) continue;
      if (ends.contains(a.type)) return null;
      if (a.type == cccdType) return a.handle;
    }
    return null;
  }

  /// Hang up on the client, as a peripheral that powers down does; [errno]
  /// is what the client's channel reports as [AttChannel.closeErrno].
  void dropLink({int? errno}) => _channel?.peerClosed(errno: errno);

  bool get isConnected => _channel != null;

  // ---- link lifecycle -------------------------------------------------

  void _attach(FakeAttChannel channel) {
    _detach();
    _channel = channel;
    mtu = 23;
    linkSecurity = 1;
    if (!bonded) {
      final cccdType = uuid16ToString(
        GattType.clientCharacteristicConfiguration,
      );
      for (final a in attributes.values) {
        if (a.type == cccdType) a.value = Uint8List(2);
      }
    }
  }

  void _detach([FakeAttChannel? only]) {
    if (only != null && !identical(_channel, only)) return;
    _channel = null;
    _unanswered = null;
    _elevating = false;
    _prepareQueue.clear();
    final orphans = [..._peerRequests];
    _peerRequests.clear();
    for (final r in orphans) {
      r.answer.completeError(
        StateError('the link closed before the client answered'),
      );
    }
  }

  /// Every PDU the client sends lands here: requests are served, commands
  /// applied, anything else is the client answering the peripheral.
  void _fromClient(FakeAttChannel channel, Uint8List pdu) {
    if (pdu.isEmpty) {
      violations.add('client sent an empty PDU');
      return;
    }
    final op = pdu[0];
    final name = '0x${op.toRadixString(16).padLeft(2, '0')}';
    if (pdu.length > mtu) {
      violations.add(
        'client sent a ${pdu.length}-byte PDU $name on a link with MTU $mtu',
      );
    }
    if (AttDecode.isRequest(op)) {
      if (_elevating) {
        violations.add('client sent request $name while pairing was running');
      }
      final previous = _unanswered;
      if (previous != null) {
        violations.add(
          'client sent request $name while '
          '0x${previous.toRadixString(16).padLeft(2, '0')} was unanswered '
          '(one transaction at a time, Vol 3 Part F 3.3.2)',
        );
      }
      _unanswered = op;
      final response = handle(pdu);
      if (response != null) _respond(channel, response);
      return;
    }
    if (AttDecode.isCommand(op)) {
      commands.add(pdu);
      if (op == AttOpcode.writeCommand) _write(pdu, withResponse: false);
      return;
    }
    if (op == AttOpcode.handleValueConfirmation) {
      confirmations++;
      _answeredByClient(pdu, AttOpcode.handleValueIndication);
      return;
    }
    int? answers;
    try {
      answers = AttDecode.requestOpcodeOf(pdu);
    } on AttFormatException {
      answers = null;
    }
    _answeredByClient(pdu, answers);
  }

  void _answeredByClient(Uint8List pdu, int? answers) {
    final i = _peerRequests.indexWhere((r) => r.pdu[0] == answers);
    if (i < 0) {
      if (pdu[0] != AttOpcode.handleValueConfirmation) {
        violations.add(
          'client sent 0x${pdu[0].toRadixString(16).padLeft(2, '0')} '
          'answering nothing the peripheral asked',
        );
      }
      return;
    }
    final request = _peerRequests.removeAt(i);
    clientResponses.add(pdu);
    if (request.pdu[0] == AttOpcode.exchangeMtuRequest &&
        pdu[0] == AttOpcode.exchangeMtuResponse &&
        pdu.length >= 3 &&
        request.pdu.length >= 3) {
      final ours = _u16(request.pdu, 1);
      final theirs = _u16(pdu, 1);
      final settled = ours < theirs ? ours : theirs;
      mtu = settled < 23 ? 23 : settled;
    }
    request.answer.complete(pdu);
  }

  void _respond(FakeAttChannel channel, Uint8List response) {
    void deliver() => channel.deliver(response);
    if (responseLatency == Duration.zero) {
      scheduleMicrotask(deliver);
    } else {
      Timer(responseLatency, deliver);
    }
  }

  /// A PDU is reaching the client: if it answers the request outstanding,
  /// the next request may go.
  void _delivered(Uint8List pdu) {
    final unanswered = _unanswered;
    if (unanswered == null) return;
    int? answers;
    try {
      answers = AttDecode.requestOpcodeOf(pdu);
    } on AttFormatException {
      return;
    }
    if (answers == unanswered) _unanswered = null;
  }

  // ---- the ATT server -------------------------------------------------

  /// The response to [request], or null for silence. Records [request] in
  /// [requests].
  Uint8List? handle(Uint8List request) {
    requests.add(request);
    final op = request[0];
    if (silentOpcodes.contains(op)) return null;
    switch (op) {
      case AttOpcode.exchangeMtuRequest:
        if (refusesMtuExchange) {
          return _error(op, 0, AttError.requestNotSupported);
        }
        final client = _u16(request, 1);
        final settled = client < serverRxMtu ? client : serverRxMtu;
        mtu = settled < 23 ? 23 : settled;
        return Uint8List.fromList([
          AttOpcode.exchangeMtuResponse,
          serverRxMtu & 0xff,
          serverRxMtu >> 8,
        ]);
      case AttOpcode.readByGroupTypeRequest:
        return _readByGroupType(request);
      case AttOpcode.readByTypeRequest:
        return _readByType(request);
      case AttOpcode.findInformationRequest:
        return _findInformation(request);
      case AttOpcode.readRequest:
        return _read(request, _u16(request, 1), 0);
      case AttOpcode.readBlobRequest:
        return _read(request, _u16(request, 1), _u16(request, 3));
      case AttOpcode.writeRequest:
        return _write(request, withResponse: true);
      case AttOpcode.prepareWriteRequest:
        return _prepareWrite(request);
      case AttOpcode.executeWriteRequest:
        return _executeWrite(request);
      default:
        return _error(op, 0, AttError.requestNotSupported);
    }
  }

  /// A range starting at 0 or ending before it starts: Invalid Handle.
  static Uint8List? _badRange(Uint8List req, int start, int end) =>
      start == 0 || start > end
      ? _error(req[0], start, AttError.invalidHandle)
      : null;

  /// Where a discovery request's page begins: its Starting Handle, or the
  /// table's start for a peripheral that [ignoresStartHandle].
  int _pageStart(int asked) => ignoresStartHandle ? 0x0001 : asked;

  Uint8List _readByGroupType(Uint8List req) {
    final asked = _u16(req, 1);
    final end = _u16(req, 3);
    final bad = _badRange(req, asked, end);
    if (bad != null) return bad;
    final start = _pageStart(asked);
    final type = uuidFromAttBytes(req.sublist(5));
    if (type != uuid16ToString(GattType.primaryService)) {
      return _error(req[0], asked, AttError.unsupportedGroupType);
    }
    final out = <int>[];
    int? entryLength;
    for (final a in _sorted()) {
      if (a.handle < start || a.handle > end || a.type != type) continue;
      final length = 4 + a.value.length;
      if (entryLength != null && length != entryLength) break;
      if (out.length + length > mtu - 2) break;
      entryLength = length;
      final svcEnd = _serviceEnds[a.handle]!;
      out.addAll([a.handle & 0xff, a.handle >> 8, svcEnd & 0xff, svcEnd >> 8]);
      out.addAll(a.value);
    }
    if (out.isEmpty) return _error(req[0], asked, AttError.attributeNotFound);
    return Uint8List.fromList([
      AttOpcode.readByGroupTypeResponse,
      entryLength!,
      ...out,
    ]);
  }

  Uint8List? _readByType(Uint8List req) {
    final asked = _u16(req, 1);
    final end = _u16(req, 3);
    final typeBytes = req.sublist(5);
    if (typeBytes.length == 2 &&
        silentReadByTypes.contains(typeBytes[0] | (typeBytes[1] << 8))) {
      return null;
    }
    final bad = _badRange(req, asked, end);
    if (bad != null) return bad;
    final start = _pageStart(asked);
    final type = uuidFromAttBytes(typeBytes);
    final out = <int>[];
    int? entryLength;
    for (final a in _sorted()) {
      if (a.handle < start || a.handle > end || a.type != type) continue;
      final length = 2 + a.value.length;
      if (entryLength != null && length != entryLength) break;
      if (out.length + length > mtu - 2) break;
      entryLength = length;
      out.addAll([a.handle & 0xff, a.handle >> 8, ...a.value]);
    }
    if (out.isEmpty) return _error(req[0], asked, AttError.attributeNotFound);
    return Uint8List.fromList([
      AttOpcode.readByTypeResponse,
      entryLength!,
      ...out,
    ]);
  }

  Uint8List _findInformation(Uint8List req) {
    final asked = _u16(req, 1);
    final end = _u16(req, 3);
    final bad = _badRange(req, asked, end);
    if (bad != null) return bad;
    final start = _pageStart(asked);
    final out = <int>[];
    int? format;
    for (final a in _sorted()) {
      if (a.handle < start || a.handle > end) continue;
      final short =
          a.type.endsWith(bluetoothBaseUuidSuffix) && a.type.startsWith('0000');
      final thisFormat = short ? 1 : 2;
      if (format != null && thisFormat != format) break;
      final length = short ? 4 : 18;
      if (out.length + length > mtu - 2) break;
      format = thisFormat;
      out.addAll([a.handle & 0xff, a.handle >> 8]);
      out.addAll(
        short
            ? _le16(int.parse(a.type.substring(4, 8), radix: 16))
            : _uuid128Bytes(a.type),
      );
    }
    if (out.isEmpty) return _error(req[0], asked, AttError.attributeNotFound);
    return Uint8List.fromList([
      AttOpcode.findInformationResponse,
      format!,
      ...out,
    ]);
  }

  /// Why the current link may not have [a]'s value, or null when it may.
  int? _securityDenied(FakeAttAttribute a) {
    final need = a.requiredSecurity;
    return need != null && linkSecurity < need ? a.securityError : null;
  }

  Uint8List _read(Uint8List req, int handle, int asked) {
    final a = attributes[handle];
    if (a == null) return _error(req[0], handle, AttError.invalidHandle);
    if (a.accessError != null) return _error(req[0], handle, a.accessError!);
    if (!a.readable) return _error(req[0], handle, AttError.readNotPermitted);
    final denied = _securityDenied(a);
    if (denied != null) return _error(req[0], handle, denied);
    final offset = blobIgnoresOffset ? 0 : asked;
    if (offset > a.value.length) {
      return _error(req[0], handle, AttError.invalidOffset);
    }
    final limit = mtu - 1;
    if (req[0] == AttOpcode.readBlobRequest &&
        offset > 0 &&
        a.value.length <= limit &&
        blobOnShortAttribute == FakeBlobOnShortAttribute.attributeNotLong) {
      return _error(req[0], handle, AttError.attributeNotLong);
    }
    final slice = a.value.sublist(offset);
    return Uint8List.fromList([
      req[0] == AttOpcode.readRequest
          ? AttOpcode.readResponse
          : AttOpcode.readBlobResponse,
      ...(slice.length > limit ? slice.sublist(0, limit) : slice),
    ]);
  }

  /// Why [a] may not be written on the current link, or null when it may.
  int? _writeDenied(FakeAttAttribute a) {
    if (a.accessError != null) return a.accessError;
    if (!a.writable) return AttError.writeNotPermitted;
    return _securityDenied(a);
  }

  Uint8List? _write(Uint8List req, {required bool withResponse}) {
    final handle = _u16(req, 1);
    final value = req.sublist(3);
    final a = attributes[handle];
    final code = a == null ? AttError.invalidHandle : _writeDenied(a);
    if (code != null) return withResponse ? _error(req[0], handle, code) : null;
    a!.value = Uint8List.fromList(value);
    writes.add((handle: handle, value: value, withResponse: withResponse));
    return withResponse ? Uint8List.fromList([AttOpcode.writeResponse]) : null;
  }

  Uint8List _prepareWrite(Uint8List req) {
    if (!supportsQueuedWrites) {
      return _error(req[0], 0, AttError.requestNotSupported);
    }
    if (req.length < 5) return _error(req[0], 0, AttError.invalidPdu);
    final handle = _u16(req, 1);
    final offset = _u16(req, 3);
    final part = req.sublist(5);
    final a = attributes[handle];
    final code = a == null ? AttError.invalidHandle : _writeDenied(a);
    if (code != null) return _error(req[0], handle, code);
    _prepareQueue.add((handle: handle, offset: offset, value: part));
    final echo = Uint8List.fromList(part);
    if (corruptsPrepareWriteEcho && echo.isNotEmpty) echo[0] ^= 0xFF;
    return Uint8List.fromList([
      AttOpcode.prepareWriteResponse,
      ...req.sublist(1, 5),
      ...echo,
    ]);
  }

  Uint8List _executeWrite(Uint8List req) {
    if (!supportsQueuedWrites) {
      return _error(req[0], 0, AttError.requestNotSupported);
    }
    final flags = req.length >= 2 ? req[1] : -1;
    if (flags == 0x00) {
      _prepareQueue.clear();
      return Uint8List.fromList([AttOpcode.executeWriteResponse]);
    }
    if (flags != 0x01) return _error(req[0], 0, AttError.invalidPdu);
    // Stage every piece in order, then apply all or nothing (3.4.6.3).
    final staged = <int, Uint8List>{};
    for (final p in _prepareQueue) {
      final current = staged[p.handle] ?? attributes[p.handle]!.value;
      if (p.offset > current.length) {
        _prepareQueue.clear();
        return _error(req[0], p.handle, AttError.invalidOffset);
      }
      final next = Uint8List.fromList([
        ...current.sublist(0, p.offset),
        ...p.value,
      ]);
      if (next.length > attMaxAttributeLength) {
        _prepareQueue.clear();
        return _error(req[0], p.handle, AttError.invalidAttributeValueLength);
      }
      staged[p.handle] = next;
    }
    _prepareQueue.clear();
    staged.forEach((handle, value) {
      attributes[handle]!.value = value;
      writes.add((handle: handle, value: value, withResponse: true));
    });
    return Uint8List.fromList([AttOpcode.executeWriteResponse]);
  }

  List<FakeAttAttribute> _sorted() =>
      attributes.values.toList()..sort((a, b) => a.handle - b.handle);

  static Uint8List _error(int op, int handle, int code) =>
      AttEncode.errorResponse(op, handle, code);

  static int _u16(Uint8List b, int i) =>
      b.length >= i + 2 ? b[i] | (b[i + 1] << 8) : 0;
  static List<int> _le16(int v) => [v & 0xff, v >> 8];
  static List<int> _uuid128Bytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    return [
      for (var i = 30; i >= 0; i -= 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }
}

/// An [AttChannel] wired to a [FakeAttPeripheral]. Responses arrive on a
/// later microtask (or after [FakeAttPeripheral.responseLatency]), as they
/// would from a socket. Creating one is a new link: see the file comment.
class FakeAttChannel implements AttChannel {
  final FakeAttPeripheral peripheral;
  final _incoming = StreamController<Uint8List>();
  final _closed = Completer<void>();
  bool _open = true;
  int? _closeErrno;

  /// Whether the socket is in BT_CONFIG: an elevation under way, and no
  /// PDU from the peer since it began (see [FakeAttPeripheral.pairingDelay]).
  bool _btConfig = false;

  /// Every PDU the client sent.
  final List<Uint8List> sent = [];

  FakeAttChannel(this.peripheral) {
    peripheral._attach(this);
  }

  bool get _current => _open && identical(peripheral._channel, this);

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  bool get isOpen => _open;

  @override
  int? get closeErrno => _closeErrno;

  @override
  int get securityLevel => _current ? peripheral.linkSecurity : 1;

  @override
  Future<bool> elevateSecurity(
    int level, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final p = peripheral;
    p.elevations.add(level);
    if (!_current) return false;
    if (p.linkSecurity >= level) return true;
    // Refused before it began: nothing changed state, the link stays up.
    if (p.smpUnavailable) return false;
    p._elevating = true;
    _btConfig = true;
    final outcome = Completer<bool>();
    void settle(bool ok) {
      if (!outcome.isCompleted) outcome.complete(ok);
    }

    final pairing = Timer(p.pairingDelay, () => settle(p.acceptsPairing));
    final giveUp = Timer(timeout, () => settle(false));
    unawaited(closed.then((_) => settle(false)));
    final ok = await outcome.future;
    pairing.cancel();
    giveUp.cancel();
    if (!_current) return false;
    p._elevating = false;
    // A PDU from the peer during the attempt resumed the socket (as the
    // kernel's l2cap_chan_ready does), and a resumed socket is not stuck.
    final stuck = _btConfig;
    _btConfig = false;
    if (!ok) {
      // Refused or given up on: as the production channel does, close a
      // link still stuck refusing every send (AttChannel's elevateSecurity
      // contract) — and leave one the peer already resumed.
      if (stuck) _closeSoon();
      return false;
    }
    p
      ..linkSecurity = level
      ..bonded = true;
    return true;
  }

  @override
  void send(Uint8List pdu) {
    if (!_open) throw const AttChannelException('send', 'closed');
    if (_btConfig) {
      // The kernel refuses to send while it raises the link's security. A
      // request here is also the client breaking discipline, so the referee
      // records it as it would one that got through.
      if (pdu.isNotEmpty && AttDecode.isRequest(pdu[0])) {
        peripheral.violations.add(
          'client sent request 0x${pdu[0].toRadixString(16).padLeft(2, '0')} '
          'while pairing was running',
        );
      }
      throw const AttChannelException(
        'send',
        'the socket is in BT_CONFIG while the link security is raised',
        errno: AttErrno.enotconn,
      );
    }
    final copy = Uint8List.fromList(pdu);
    sent.add(copy);
    peripheral._fromClient(this, copy);
  }

  /// A PDU from the peer — a scripted response, a notification, a request,
  /// or a stray duplicate a test wants the client to ignore.
  void deliver(Uint8List pdu) {
    if (!_open || _incoming.isClosed) return;
    // Any PDU on the ATT channel makes the kernel call l2cap_chan_ready,
    // which puts a socket in BT_CONFIG back to connected mid-pairing.
    _btConfig = false;
    if (identical(peripheral._channel, this)) peripheral._delivered(pdu);
    _incoming.add(pdu);
  }

  /// The peer hung up; [errno] becomes [closeErrno].
  void peerClosed({int? errno}) {
    if (!_open) return;
    _closeErrno = errno;
    _finish();
  }

  @override
  Future<void> close() async => _finish();

  /// The production channel closing itself, as its callers see it: no
  /// sends from this instant, and the link's end — [closed], [incoming]
  /// done — a turn of the event loop later, when its worker isolate's
  /// report arrives. So what was waiting on the link fails first and the
  /// disconnect follows, the order an app sees on Linux. ([close] itself
  /// stays immediate, as the tests driving the fake expect.)
  void _closeSoon() {
    if (!_open) return;
    _open = false;
    Timer.run(_finish);
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _open = false;
    peripheral._detach(this);
    unawaited(_incoming.close());
    _closed.complete();
  }
}

/// Opens [FakeAttChannel]s to the peripherals it knows by address (matched
/// case-insensitively, as the kernel parses the hex).
class FakeAttChannelFactory implements AttChannelFactory {
  final Map<String, FakeAttPeripheral> peripherals = {};

  /// Every connect attempt: the address as given and whether it was
  /// flagged random.
  final List<({String address, bool random})> attempts = [];

  /// Every channel opened, in order.
  final List<FakeAttChannel> channels = [];

  /// When set, every connect fails with this instead.
  AttChannelException? connectError;

  /// How long a connect takes to come up; [AttChannelFactory.connect]'s
  /// timeout and cancel both race it.
  Duration connectLatency = Duration.zero;

  final Map<String, List<AttChannelException>> _failures = {};

  /// Fail the next connects to [address] with [failures], one per attempt,
  /// in order — e.g. EBUSY twice, then success.
  void failNextConnects(String address, List<AttChannelException> failures) =>
      _failures.putIfAbsent(address.toUpperCase(), () => []).addAll(failures);

  FakeAttPeripheral? _peripheral(String address) {
    final key = address.toUpperCase();
    for (final e in peripherals.entries) {
      if (e.key.toUpperCase() == key) return e.value;
    }
    return null;
  }

  @override
  Future<AttChannel> connect(
    String address, {
    required bool randomAddress,
    Duration timeout = const Duration(seconds: 15),
    Future<void>? cancel,
  }) async {
    attempts.add((address: address, random: randomAddress));
    bdaddrBytes(address); // the real factory's ArgumentError, if malformed
    final failure = connectError;
    if (failure != null) throw failure;
    final queued = _failures[address.toUpperCase()];
    if (queued != null && queued.isNotEmpty) throw queued.removeAt(0);
    final peripheral = _peripheral(address);
    if (peripheral == null) {
      throw const AttChannelException('connect', 'no such device', errno: 112);
    }
    if (peripheral.randomAddress != randomAddress) {
      throw AttChannelException(
        'connect',
        'no ${randomAddress ? 'random' : 'public'} address $address',
        errno: AttErrno.econnrefused,
      );
    }
    if (cancel != null || connectLatency > Duration.zero) {
      final outcome = Completer<int?>();
      void settle(int? errno) {
        if (!outcome.isCompleted) outcome.complete(errno);
      }

      final up = Timer(connectLatency, () => settle(null));
      final expire = connectLatency > timeout
          ? Timer(timeout, () => settle(AttErrno.etimedout))
          : null;
      if (cancel != null) {
        unawaited(
          cancel.then<void>(
            (_) => settle(AttErrno.ecanceled),
            onError: (Object _) => settle(AttErrno.ecanceled),
          ),
        );
      }
      final errno = await outcome.future;
      up.cancel();
      expire?.cancel();
      if (errno != null) {
        throw AttChannelException(
          'connect',
          errno == AttErrno.ecanceled
              ? 'connect to $address cancelled'
              : 'connect to $address timed out',
          errno: errno,
        );
      }
    }
    final channel = FakeAttChannel(peripheral);
    channels.add(channel);
    onChannelOpened?.call(address);
    return channel;
  }

  /// Called, synchronously, as each channel comes up — the moment the kernel
  /// makes the ACL, which is when bluetoothd would start reporting it. Lets a
  /// test script bluetoothd's commentary on a direct link at the instant it
  /// happens rather than by the clock.
  void Function(String address)? onChannelOpened;
}
