// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../core/find_device.dart' show signalBars;
import '../models/iot_device.dart';

/// The scan's working set: every device heard from this session, how long
/// ago each was last heard, and which signal band each is held in.
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
///
/// Wall-clock time, but only the stretches of it a scan was listening through.
/// Silence is evidence about a device only while something could have heard
/// it. With the scan stopped — by the user, by a tab switch, by the app going
/// to the background — every device is "silent" at once, and a list that
/// counted that time flagged every row "Not seen for 45s" within a minute of
/// the Stop press and had dropped them all by the end of a phone call. So the
/// manager is told when listening starts and stops (see [listening]), and the
/// clock the freshness checks read stands still in between.
///
/// The signal band is the manager's judgement, not the latest reading's, for
/// the same reason the list sorts by band rather than by dBm: the rows have
/// to stay still enough to tap. See [signalBandOf].
class DeviceManager {
  final Map<String, IoTDevice> _devices = {};

  /// Each tracked device's signal, by id. Kept beside [_devices] rather than
  /// on the immutable [IoTDevice] because it is this manager's running
  /// judgement, not a fact about the sighting.
  final Map<String, _Signal> _signals = {};

  /// The instant listening stopped, or null while a scan is listening.
  ///
  /// Null to begin with: a manager listens until told otherwise, so a caller
  /// that never pauses gets plain wall-clock ageing.
  DateTime? _pausedAt;

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

  /// Weight of the newest reading in a device's smoothed rssi.
  ///
  /// The reading a continuous scan reports wanders several dB between
  /// advertisements while nothing physically moves. 0.3 follows a genuine
  /// move within a handful of advertisements and cuts a single outlier to a
  /// fraction of itself.
  static const double signalSmoothing = 0.3;

  /// How far past a band boundary the smoothed reading must be before the
  /// band changes, in dB.
  ///
  /// Smoothing narrows the wander; it does not move it off the boundaries.
  /// A device whose average sits at -70 would still change band every few
  /// advertisements, and each change is its row jumping a group. Four dB is
  /// under half a band, so a genuine move of one band still shows, and it
  /// is more than the jitter left after smoothing.
  static const int signalBandHysteresisDb = 4;

  /// Shortest time a device keeps a band once it has changed.
  ///
  /// The margin holds a device that hovers; this holds one that went through
  /// a boundary and straight back — a phone lifted and set down — which
  /// would otherwise re-sort the list twice in a few seconds. Counted on the
  /// listening clock, like freshness: a pause is not time the reading had to
  /// settle in.
  static const Duration signalBandDwell = Duration(seconds: 10);

  List<IoTDevice> get devices {
    final list = _devices.values.toList();
    list.sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  int get count => _devices.length;

  void addOrUpdate(IoTDevice device) {
    final known = _devices[device.id];
    // A known device keeps its original discoveredAt. Each scan invocation
    // stamps first-seen from its own start — and the scan restarts routinely
    // (the burst downshift, a tab return, a lifecycle resume) — so taking the
    // new stamp would reset every kept row's age to post-restart arrival
    // order, reshuffling same-band rows once per restart. The list's ordering
    // promises a row moves only when the device genuinely does; the session's
    // first sighting is the stamp that keeps that promise.
    _devices[device.id] = known == null
        ? device
        : _restamped(
            device,
            discoveredAt: known.discoveredAt,
            lastSeen: device.lastSeen,
          );
    _track(device);
  }

  IoTDevice? getById(String id) => _devices[id];

  void remove(String id) {
    _devices.remove(id);
    // With it goes its signal history: a device seen again after being
    // dropped is a fresh sighting, and averaging it with readings from
    // before it went quiet would start its row in a band it is no longer in.
    _signals.remove(id);
  }

  void clear() {
    _devices.clear();
    _signals.clear();
  }

  /// Whether a scan is listening for these devices — see [listening].
  bool get isListening => _pausedAt == null;

  /// Tell the manager whether a scan is listening for its devices, as of
  /// [now].
  ///
  /// Off, the clock every freshness check reads freezes at [now], so nothing
  /// crosses a threshold while nobody could have heard it. On again, every
  /// device's [IoTDevice.lastSeen] moves forward by the length of the pause,
  /// so its age carries on from where it stood when listening stopped instead
  /// of jumping by the whole pause. A caller holding an [IoTDevice] from
  /// before the pause reads it back from the manager afterwards: the shifted
  /// copy is the one whose age is right. The stamp a band's dwell is counted
  /// from moves the same way, so a band that changed just before a pause is
  /// still held for its dwell after it.
  ///
  /// Both directions are idempotent, because the scan screen reaches them
  /// from several directions: a scan restarts without ever having stopped
  /// (the burst downshift), and a stop can be the user's, the lifecycle's and
  /// the stream's own onDone in quick succession. A second stop must not move
  /// the freeze point, and a second start must not shift the stamps again.
  ///
  /// The ambient duty cycle counts as listening. Android's balanced mode
  /// receives about a quarter of each ~4s cycle; those gaps are invisible
  /// from here, and they are already the reason [staleAfter] is 90s rather
  /// than 40s.
  void listening(bool on, DateTime now) {
    if (!on) {
      _pausedAt ??= now;
      return;
    }
    final pausedAt = _pausedAt;
    if (pausedAt == null) return;
    _pausedAt = null;
    _devices.updateAll((_, device) {
      // A sighting stamped inside the pause is nothing the screen produces
      // (its stop cancels delivery first) but nothing this API forbids
      // either, and it WAS heard then: only the rest of the pause is not
      // silence. Shifting it by the whole pause would date it past [now].
      final pause = _unheard(device.lastSeen, pausedAt, now);
      if (pause <= Duration.zero) return device;
      return _restamped(
        device,
        discoveredAt: device.discoveredAt,
        lastSeen: device.lastSeen.add(pause),
      );
    });
    for (final signal in _signals.values) {
      final since = signal.bandSince;
      if (since == null) continue;
      final pause = _unheard(since, pausedAt, now);
      if (pause > Duration.zero) signal.bandSince = since.add(pause);
    }
  }

  /// How much of the pause from [pausedAt] to [now] came after [stamp]: the
  /// stretch a stamp has to move forward by so that only listening time
  /// separates it from what follows.
  static Duration _unheard(DateTime stamp, DateTime pausedAt, DateTime now) =>
      now.difference(stamp.isAfter(pausedAt) ? stamp : pausedAt);

  /// The instant freshness is measured against: [now] while listening, the
  /// moment listening stopped while not.
  DateTime _heardUntil(DateTime now) => _pausedAt ?? now;

  /// How long [device] has gone unheard while something was listening, as of
  /// [now].
  ///
  /// The one age the screen prints and classifies by. [IoTDevice.ageAt] is
  /// wall time, and reads high by every pause since the sighting — a row
  /// captioned from it would say "Not seen for 5m" over a device the radio
  /// stopped listening for 5m ago.
  Duration ageOf(IoTDevice device, DateTime now) =>
      device.ageAt(_heardUntil(now));

  /// Whether [device] has been silent long enough to warrant a warning.
  ///
  /// Takes an explicit [now] so the policy is one testable expression, and so
  /// a single rendering pass classifies every row against the same instant
  /// instead of drifting across the list. An instance method rather than a
  /// static one because the answer depends on this manager's listening
  /// history, not on the device alone.
  bool isStale(IoTDevice device, DateTime now) =>
      ageOf(device, now) >= staleAfter;

  /// Whether [device] has been silent long enough to be dropped.
  bool isGone(IoTDevice device, DateTime now) =>
      ageOf(device, now) >= forgetAfter;

  /// Drop everything silent past [forgetAfter], reporting whether anything
  /// went. The caller repaints on true.
  bool forgetGone(DateTime now) {
    final gone = [
      for (final device in _devices.values)
        if (isGone(device, now)) device.id,
    ];
    for (final id in gone) {
      remove(id);
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

  /// The signal band [device] is drawn in and sorted by: 1 (weakest) to 4.
  ///
  /// [signalBars] of the latest reading is the right band for a device drawn
  /// once, and the wrong one for a row on a live list: a device whose
  /// reading hovers around a boundary flips band on every advertisement, and
  /// the list re-sorts each time, so the row under a finger changed between
  /// deciding to tap and tapping (seen on an iPhone). The band is held here
  /// instead, per device, and moves only when the smoothed reading is
  /// [signalBandHysteresisDb] past a boundary and the band has stood for
  /// [signalBandDwell]. A first sighting classifies outright, so a new row
  /// appears where it belongs rather than at the bottom for ten seconds.
  ///
  /// The bars a row draws and the band it sorts into both come from here, so
  /// they cannot disagree; the dBm the row prints beside them is still the
  /// instantaneous reading. A device this manager is not tracking bands its
  /// own reading.
  int signalBandOf(IoTDevice device) =>
      _signals[device.id]?.band ?? signalBars(device.rssi);

  /// Fold [sighting] into its device's smoothed reading, and move the band
  /// when the reading and the dwell both allow.
  void _track(IoTDevice sighting) {
    final signal = _signals[sighting.id];
    if (signal == null) {
      _signals[sighting.id] = _Signal(
        smoothed: sighting.rssi.toDouble(),
        band: signalBars(sighting.rssi),
      );
      return;
    }
    signal.smoothed =
        signalSmoothing * sighting.rssi +
        (1 - signalSmoothing) * signal.smoothed;
    final band = _bandFor(signal.smoothed, held: signal.band);
    if (band == signal.band) return;
    // Measured by the sighting's own stamp rather than a clock read here: it
    // is the instant the freshness checks already treat as "heard", and it
    // lives in the timeline [listening] shifts past pauses — so a pause does
    // not count towards the dwell, the same way it does not count as
    // silence.
    final since = signal.bandSince;
    if (since != null &&
        sighting.lastSeen.difference(since) < signalBandDwell) {
      return;
    }
    signal.band = band;
    signal.bandSince = sighting.lastSeen;
  }

  /// The band a device held in [held] belongs in on a smoothed reading of
  /// [smoothed]: [held], unless the reading is at least
  /// [signalBandHysteresisDb] past a boundary out of it.
  static int _bandFor(double smoothed, {required int held}) {
    // Handicap the reading against the move. Marked down by the margin and
    // still banding above the held band, it has cleared the boundary by the
    // margin — and likewise marked up and still banding below it. Within the
    // margin of a boundary, both read as the held band.
    final up = signalBars(smoothed - signalBandHysteresisDb);
    if (up > held) return up;
    final down = signalBars(smoothed + signalBandHysteresisDb);
    if (down < held) return down;
    return held;
  }

  /// [device] with its stamps replaced.
  ///
  /// IoTDevice is immutable and its model file is shared with the transports,
  /// so the two callers that rewrite a stamp — a re-sighting keeping its first
  /// discoveredAt, a resume moving lastSeen past a pause — rebuild it here.
  static IoTDevice _restamped(
    IoTDevice device, {
    required DateTime discoveredAt,
    required DateTime lastSeen,
  }) => IoTDevice(
    id: device.id,
    name: device.name,
    rssi: device.rssi,
    isConnectable: device.isConnectable,
    discoveredAt: discoveredAt,
    lastSeen: lastSeen,
    serviceUuids: device.serviceUuids,
    companyIds: device.companyIds,
    manufacturerData: device.manufacturerData,
  );
}

/// One device's signal as the list judges it — see
/// [DeviceManager.signalBandOf].
class _Signal {
  /// Exponential moving average of the readings, in dBm.
  double smoothed;

  /// The band the device is held in, 1 to 4.
  int band;

  /// When [band] last changed, in the timeline of [IoTDevice.lastSeen] (and
  /// shifted past pauses like it), or null while the device is still in the
  /// band its first sighting put it in. That classification is not a change,
  /// so nothing holds a band before its first real move: a device whose
  /// first packet happened to be a weak one corrects itself as soon as the
  /// readings justify it.
  DateTime? bandSince;

  _Signal({required this.smoothed, required this.band});
}
