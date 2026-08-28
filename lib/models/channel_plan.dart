// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A named, ordered set of channels destined for one radio.

import 'radio_channel.dart';

/// The user's working copy of a radio's memory.
///
/// Order is the whole point: slot 1 is slot 1, and dragging a channel up moves
/// it on the radio. So the channels are a `List` and every operation on a plan
/// preserves position rather than re-sorting.
class ChannelPlan {
  final String id;
  final String name;

  /// Which radio this plan was built for. Kept as the profile id rather than
  /// the profile so a plan survives a build that renames or re-specs one, and
  /// so a plan for a radio this build no longer knows still loads.
  final String radioProfileId;

  final List<RadioChannel> channels;

  /// Whether this plan was assembled with the transmit-range unlock on.
  ///
  /// Recorded on the plan, not just in settings, because the flag can be
  /// turned off afterwards and the plan would then look ordinary while still
  /// containing channels the radio can only reach unlocked. The UI banners it.
  final bool builtWithTxUnlock;

  final DateTime createdAt;
  final DateTime modifiedAt;

  const ChannelPlan({
    required this.id,
    required this.name,
    required this.radioProfileId,
    required this.channels,
    required this.createdAt,
    required this.modifiedAt,
    this.builtWithTxUnlock = false,
  });

  int get length => channels.length;
  bool get isEmpty => channels.isEmpty;

  ChannelPlan copyWith({
    String? name,
    String? radioProfileId,
    List<RadioChannel>? channels,
    bool? builtWithTxUnlock,
    DateTime? modifiedAt,
  }) =>
      ChannelPlan(
        id: id,
        name: name ?? this.name,
        radioProfileId: radioProfileId ?? this.radioProfileId,
        channels: channels ?? this.channels,
        builtWithTxUnlock: builtWithTxUnlock ?? this.builtWithTxUnlock,
        createdAt: createdAt,
        modifiedAt: modifiedAt ?? this.modifiedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'radioProfileId': radioProfileId,
        'channels': [for (final channel in channels) channel.toJson()],
        if (builtWithTxUnlock) 'builtWithTxUnlock': true,
        'createdAt': createdAt.toIso8601String(),
        'modifiedAt': modifiedAt.toIso8601String(),
      };

  /// Returns null for a plan that cannot be read. Individual channels degrade
  /// on their own: an unreadable channel is skipped and the rest of the plan
  /// survives, which matters more here than anywhere else in the app — a plan
  /// is minutes of someone's work, not a cached scan result.
  static ChannelPlan? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final profileId = json['radioProfileId'];
    if (id is! String || id.isEmpty || name is! String) return null;
    if (profileId is! String || profileId.isEmpty) return null;

    final channels = <RadioChannel>[];
    final raw = json['channels'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map<String, dynamic>) continue;
        final channel = RadioChannel.fromJson(entry);
        if (channel != null) channels.add(channel);
      }
    }

    final created = json['createdAt'];
    final modified = json['modifiedAt'];
    final createdAt = created is String ? DateTime.tryParse(created) : null;
    final modifiedAt = modified is String ? DateTime.tryParse(modified) : null;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);

    return ChannelPlan(
      id: id,
      name: name,
      radioProfileId: profileId,
      channels: channels,
      builtWithTxUnlock: json['builtWithTxUnlock'] == true,
      createdAt: createdAt ?? epoch,
      modifiedAt: modifiedAt ?? createdAt ?? epoch,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ChannelPlan && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ChannelPlan($id, $name, ${channels.length} channels)';
}
