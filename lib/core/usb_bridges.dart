// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Which USB-serial chip a programming cable is built on.

/// The bridge chip inside a USB-serial cable.
///
/// The chip identifies the cable, never the radio: every radio family here
/// is programmed through the same handful of chips. It is still worth
/// naming, because "which chip is this cable?" is the first question when
/// one does not work.
class UsbBridge {
  final String name;

  /// Something worth saying next to the name, when there is something.
  final String? caution;

  const UsbBridge(this.name, {this.caution});
}

/// Known bridges by USB vendor and product id.
const Map<(int, int), UsbBridge> _bridges = {
  (0x1A86, 0x7523): UsbBridge('WCH CH340'),
  (0x1A86, 0x5523): UsbBridge('WCH CH341'),
  (0x10C4, 0xEA60): UsbBridge('Silicon Labs CP210x'),
  (0x0403, 0x6001): UsbBridge('FTDI FT232R'),
  (0x067B, 0x2303): UsbBridge(
    'Prolific PL2303',
    caution: 'Counterfeit PL2303 chips are common in cheap programming '
        'cables, and some drivers refuse them. If this cable is not '
        'recognised, one built on a CH340 or CP210x usually is.',
  ),
};

/// The bridge a device with these ids is built on, or null when either id
/// is unknown or the pair is not one this table has.
UsbBridge? usbBridgeFor(int? vendorId, int? productId) {
  if (vendorId == null || productId == null) return null;
  return _bridges[(vendorId, productId)];
}

/// `1a86:7523`, the way USB ids are usually written.
String usbIdLabel(int vendorId, int productId) =>
    '${vendorId.toRadixString(16).padLeft(4, '0')}:'
    '${productId.toRadixString(16).padLeft(4, '0')}';
