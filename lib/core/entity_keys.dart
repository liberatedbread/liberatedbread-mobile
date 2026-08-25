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
    required String? Function(E) keyOf,
    required String Function(E) nameOf,
  })  : _entities = List.of(entities),
        _keyOf = keyOf,
        _nameOf = nameOf;

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
  static const List<String> powerSlots = ['power', 'power_on', 'power_off'];

  /// Back and Home are the pair every remote has; Exit sits with them because
  /// it is the same gesture one level further out.
  static const List<String> navSlots = ['back', 'home', 'exit'];

  /// The D-pad, clockwise from the top with OK in the middle.
  static const List<String> padSlots = ['up', 'left', 'ok', 'right', 'down'];

  /// Under the pad: the keys that act on what is on screen right now.
  static const List<String> underPadSlots = [
    'replay',
    'options',
    'menu',
    'info',
  ];
  static const List<String> transportSlots = [
    'rewind',
    'play_pause',
    'fast_forward',
  ];
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
  ];

  /// The treadmill card's slots: the transport verbs and the speed setpoint.
  static const List<String> treadmillSlots = [
    'start',
    'pause',
    'stop',
    'speed'
  ];

  /// Display names each key historically matched — the remote card's rows,
  /// verbatim, plus the treadmill card's. Additive-only.
  static const Map<String, Set<String>> _fallbackNames = {
    'power': {'Power'},
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
    'play_pause': {'Play/Pause'},
    'fast_forward': {'Fast Forward'},
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
