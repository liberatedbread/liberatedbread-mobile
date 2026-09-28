// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import '../providers/network_control_provider.dart';
import '../services/roomba_control_service.dart' show roombaProtocolHandler;

/// Whether [controls] is a Roomba spec, which has a bespoke path —
/// credentials, adoption, a transport choice — that no other MQTT device
/// wants.
///
/// One rule for every screen that asks. Keyed on the spec's own
/// `protocol_handler`, never on the `mqtt` transport, which Hisense, Dyson
/// and Bambu ride too: the launcher's copy of this rule once drifted to the
/// transport and sent a Hisense set announcing a `blid` key to the Roomba
/// wizard while the control screen rightly did not treat it as a robot.
bool isRoombaControls(NetworkControls? controls) =>
    controls?.capabilities?.protocolHandler == roombaProtocolHandler;

/// The BLID a device's discovery [txt] announced, or null when it announced
/// none. Takes the TXT map so a live sighting and a saved record answer alike.
///
/// An EMPTY value counts as absent: a TXT record can carry a bare flag with
/// no value, which the parser stores as `''`, and an empty BLID looks up no
/// password and addresses no robot.
String? announcedBlid(Map<String, String> txt) {
  final blid = txt['blid'];
  return blid == null || blid.isEmpty ? null : blid;
}

/// The BLID to drive a device by as a Roomba, or null when it is not one we
/// can drive: a non-Roomba spec, or a Roomba reached without a BLID. Callers
/// that must tell those two apart use [isRoombaControls] and [announcedBlid].
String? roombaBlidFor(Map<String, String> txt, NetworkControls? controls) =>
    isRoombaControls(controls) ? announcedBlid(txt) : null;
