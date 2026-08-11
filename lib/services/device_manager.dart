// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../models/iot_device.dart';

/// The scan's working set: every device heard from this session, and how long
/// ago each was last heard.
///
/// Freshness is measured in wall-clock time rather than in missed scan windows,
/// because there are no windows any more — the scan screen scans continuously,
/// so "how long since this thing last advertised" is the only question with an
/// answer. It has two thresholds, because a device falling silent means two
/// different things depending on how long it has been silent for:
///
///   * past [staleAfter] the row is still shown, with a warning, since BLE
///     advertising is lossy and a device that goes quiet for half a minute is
///     usually still there;
///   * past [forgetAfter] it is dropped, because by then the only thing a tap
///     on it can produce is a connect timeout.
class DeviceManager {
  final Map<String, IoTDevice> _devices = {};

  /// Silence beyond which a device is shown with a warning rather than as a
  /// live result.
  ///
  /// Sized for the AMBIENT scan the tab runs on its own, which duty-cycles
  /// the radio (Android's balanced mode listens roughly a quarter of the
  /// time), not for the continuous listen a Scan press buys. Under a 25% duty
  /// cycle each advertisement has about a one-in-four chance of landing in a
  /// listening window, so a sleepy sensor advertising every 10s is caught on
  /// average once per ~40s — with unlucky stretches well beyond. A threshold
  /// that read honestly under continuous listening (40s did) would flicker
  /// warnings over sleepy devices that are quietly fine. 90s puts the common
  /// unlucky gaps inside the threshold; the price is that an unplugged device
  /// takes a minute and a half to be flagged instead of forty seconds, which
  /// is still while the user is at the screen wondering about it.
  static const Duration staleAfter = Duration(seconds: 90);

  /// Silence beyond which a device is dropped from the list entirely.
  ///
  /// Long enough that walking to the next room and back does not clear the
  /// list, short enough that a session left open does not accumulate every
  /// device the phone has passed all day — which matters more than it sounds,
  /// because BLE privacy addresses rotate every ~15 minutes and each rotation
  /// mints what looks like a brand new device.
  static const Duration forgetAfter = Duration(minutes: 5);

  List<IoTDevice> get devices {
    final list = _devices.values.toList();
    list.sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  int get count => _devices.length;

  void addOrUpdate(IoTDevice device) {
    _devices[device.id] = device;
  }

  IoTDevice? getById(String id) => _devices[id];

  void remove(String id) {
    _devices.remove(id);
  }

  void clear() {
    _devices.clear();
  }

  /// Whether [device] has been silent long enough to warrant a warning.
  ///
  /// Static and taking an explicit [now] so the policy is one testable
  /// expression, and so a single rendering pass classifies every row against
  /// the same instant instead of drifting across the list.
  static bool isStale(IoTDevice device, DateTime now) =>
      device.ageAt(now) >= staleAfter;

  /// Whether [device] has been silent long enough to be dropped.
  static bool isGone(IoTDevice device, DateTime now) =>
      device.ageAt(now) >= forgetAfter;

  /// Drop everything silent past [forgetAfter], reporting whether anything
  /// went. The caller repaints on true.
  bool forgetGone(DateTime now) {
    final gone = [
      for (final device in _devices.values)
        if (isGone(device, now)) device.id,
    ];
    for (final id in gone) {
      _devices.remove(id);
    }
    return gone.isNotEmpty;
  }

  /// The ids currently classed as stale, as of [now].
  ///
  /// Exposed so a caller ticking the clock can tell a repaint-worthy change
  /// (a row just crossed the threshold) from a tick where nothing moved.
  Set<String> staleIds(DateTime now) => {
        for (final device in _devices.values)
          if (isStale(device, now)) device.id,
      };
}
