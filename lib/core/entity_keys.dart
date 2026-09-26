// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// Resolves curated-layout slots to entities: the spec's machine token
/// (`entities[].key`) first, a normalized-display-name table second.
///
/// The fallback table is the ONLY place English names survive as layout
/// signal, kept verbatim from the remote card's original hardcoded rows. It
/// is additive-only and dies per-spec as `key`s land upstream: a keyed
/// entity never consults it, and an un-keyed, oddly-named one degrades to
/// the leftover pile — which every consumer must render, so no control is
/// ever dropped.
class EntityKeyIndex<E> {
  final String? Function(E) _keyOf;
  final String Function(E) _nameOf;
  final List<E> _entities;
  final Set<E> _taken = Set.identity();

  EntityKeyIndex(
    Iterable<E> entities, {
    required this._keyOf,
    required this._nameOf,
  }) : _entities = List.of(entities);

  /// The entity filling [key]'s slot, or null. Spec `key` wins over the name
  /// table; a resolved entity is consumed, so two slots can never claim one
  /// control and [leftovers] stays complete.
  E? take(String key) {
    for (final entity in _entities) {
      if (_taken.contains(entity)) continue;
      if (_keyOf(entity) == key) {
        _taken.add(entity);
        return entity;
      }
    }
    final names = _fallbackNames[key];
    if (names == null) return null;
    for (final entity in _entities) {
      if (_taken.contains(entity)) continue;
      // A keyed entity said what it is; its display name is not evidence
      // for a different slot.
      if (_keyOf(entity) != null) continue;
      if (names.contains(_nameOf(entity))) {
        _taken.add(entity);
        return entity;
      }
    }
    return null;
  }

  /// The entities filling [keys]' slots, in order, skipping empty ones.
  List<E> takeAll(List<String> keys) =>
      [for (final key in keys) take(key)].whereType<E>().toList();

  /// Everything never taken, in declaration order — the wrap at the foot of
  /// a curated layout. Never dropped: a control the layout has no slot for
  /// still renders.
  List<E> get leftovers => _entities.where((e) => !_taken.contains(e)).toList();

  /// Whether some curated layout in this app has a slot for [key].
  ///
  /// The layouts themselves are the answer, so [remoteSlots] and
  /// [treadmillSlots] below are what the cards actually consume — declared
  /// here rather than inline so a test can ask the question. Upstream's
  /// vocabulary and this side's layouts are written down in two repositories
  /// and nothing bound them: four tokens (`exit`, `menu`, `info`, `keyboard`)
  /// had already drifted apart, and because an unplaced control still renders
  /// in the leftover wrap, the drift had no symptom at all.
  static bool knowsKey(String key) =>
      remoteSlots.contains(key) || treadmillSlots.contains(key);

  /// The remote card's rows, in the order it fills them. `_remoteCard` builds
  /// each row from the list beside it, so these ARE the layout rather than a
  /// second copy of it — which is what lets [knowsKey] answer honestly.
  ///
  /// `power_toggle` is the raw power key a spec lists beside its stateful
  /// Power switch (Sony, Vizio, Samsung and Hisense call it "Power Key",
  /// Philips "Standby"): a keypress that toggles, which belongs on the remote
  /// with its siblings rather than in the leftover pile below it.
  static const List<String> powerSlots = [
    'power',
    'power_toggle',
    'power_on',
    'power_off',
  ];

  /// Back and Home are the pair every remote has; Exit sits with them because
  /// it is the same gesture one level further out.
  static const List<String> navSlots = ['back', 'home', 'exit'];

  /// The D-pad. Named one cell at a time because that is how the layout takes
  /// them — each goes into its own square of the grid — and the list is
  /// composed from the same names, so [knowsKey] cannot answer for a key no
  /// cell actually asks for.
  static const String upSlot = 'up';
  static const String leftSlot = 'left';
  static const String okSlot = 'ok';
  static const String rightSlot = 'right';
  static const String downSlot = 'down';
  static const List<String> padSlots = [
    upSlot,
    leftSlot,
    okSlot,
    rightSlot,
    downSlot,
  ];

  /// Under the pad: the keys that act on what is on screen right now.
  static const List<String> underPadSlots = [
    'replay',
    'options',
    'menu',
    'info',
  ];

  /// The transport row, in the order a physical remote lays it out. Most
  /// sets have a combined play/pause AND discrete keys, so both are slots;
  /// `pause` and `stop` are the treadmill card's tokens too — the same verb on
  /// a different surface, and each card only ever indexes its own entities.
  static const List<String> transportSlots = [
    'previous',
    'rewind',
    'play',
    'play_pause',
    'pause',
    'stop',
    'fast_forward',
    'next',
    'record',
  ];

  /// The number pad, laid out 1-9 then 0 by the card.
  static const List<String> digitSlots = [
    'num_1',
    'num_2',
    'num_3',
    'num_4',
    'num_5',
    'num_6',
    'num_7',
    'num_8',
    'num_9',
    'num_0',
  ];

  /// The four colour keys, in the order every remote prints them.
  static const List<String> colorSlots = ['red', 'green', 'yellow', 'blue'];
  static const List<String> volumeSlots = ['volume_up', 'mute', 'volume_down'];
  static const List<String> channelSlots = ['channel_up', 'channel_down'];
  static const List<String> miscSlots = ['search', 'find_remote'];
  static const List<String> inputSlots = [
    'input_hdmi1',
    'input_hdmi2',
    'input_hdmi3',
    'input_hdmi4',
    'input_av',
    'input_tuner',
  ];

  /// Every key the remote places, for [knowsKey].
  static const List<String> remoteSlots = [
    ...powerSlots,
    ...navSlots,
    ...padSlots,
    ...underPadSlots,
    ...transportSlots,
    ...volumeSlots,
    ...channelSlots,
    ...miscSlots,
    ...inputSlots,
    ...digitSlots,
    ...colorSlots,
  ];

  /// The treadmill card's slots. Named individually for the same reason as the
  /// D-pad's: the card resolves each verb on its own, against its own fallback
  /// list of command names, so a shared `takeAll` would not describe it.
  static const String startSlot = 'start';
  static const String pauseSlot = 'pause';
  static const String stopSlot = 'stop';
  static const String speedSlot = 'speed';
  static const List<String> treadmillSlots = [
    startSlot,
    pauseSlot,
    stopSlot,
    speedSlot,
  ];

  /// Display names each key historically matched — the remote card's rows,
  /// verbatim, plus the treadmill card's. Additive-only.
  static const Map<String, Set<String>> _fallbackNames = {
    'power': {'Power'},
    'power_toggle': {'Power Key', 'Standby'},
    'power_on': {'Power On'},
    'power_off': {'Power Off'},
    'back': {'Back'},
    'home': {'Home'},
    'exit': {'Exit'},
    'menu': {'Menu'},
    'info': {'Info'},
    'up': {'Up'},
    'down': {'Down'},
    'left': {'Left'},
    'right': {'Right'},
    'ok': {'OK'},
    'replay': {'Replay'},
    'options': {'Options'},
    'rewind': {'Rewind'},
    'play': {'Play'},
    'play_pause': {'Play/Pause'},
    'fast_forward': {'Fast Forward'},
    'previous': {'Previous', 'Skip Previous'},
    'next': {'Next', 'Skip Next'},
    'record': {'Record'},
    'num_0': {'0'},
    'num_1': {'1'},
    'num_2': {'2'},
    'num_3': {'3'},
    'num_4': {'4'},
    'num_5': {'5'},
    'num_6': {'6'},
    'num_7': {'7'},
    'num_8': {'8'},
    'num_9': {'9'},
    'red': {'Red'},
    'green': {'Green'},
    'yellow': {'Yellow'},
    'blue': {'Blue'},
    'volume_up': {'Volume Up'},
    'volume_down': {'Volume Down'},
    'mute': {'Mute'},
    'channel_up': {'Channel Up'},
    'channel_down': {'Channel Down'},
    'search': {'Search'},
    'find_remote': {'Find Remote'},
    'input_hdmi1': {'HDMI 1'},
    'input_hdmi2': {'HDMI 2'},
    'input_hdmi3': {'HDMI 3'},
    'input_hdmi4': {'HDMI 4'},
    'input_av': {'AV'},
    'input_tuner': {'Antenna'},
    'start': {'Start'},
    'pause': {'Pause'},
    'stop': {'Stop'},
    'speed': {'Target Speed', 'Belt Speed'},
  };
}
