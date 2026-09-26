// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

import '../core/frequency.dart';
import '../models/suggested_channel.dart';

/// One suggestion, with the provenance that makes it judgeable.
///
/// The badges are the point. A repeater the radio can only listen to, and one
/// it can only key with its limits widened, look identical until something
/// says otherwise -- and the person ticking the box is the one who needs to
/// know, before it is on their radio.
class SuggestedChannelTile extends StatelessWidget {
  final SuggestedChannel suggestion;
  final bool selected;
  final ValueChanged<bool> onSelected;

  const SuggestedChannelTile({
    super.key,
    required this.suggestion,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channel = suggestion.channel;

    return CheckboxListTile(
      value: selected,
      onChanged: (value) => onSelected(value ?? false),
      isThreeLine: true,
      title: Row(
        children: [
          Expanded(child: Text(channel.name)),
          Text(
            '${formatHzAsMegahertz(channel.rxFreqHz)} MHz',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_summary()),
          if (suggestion.details case final String details)
            Text(details, style: theme.textTheme.bodySmall),
          if (!suggestion.txAllowed || suggestion.requiresTxUnlock)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                children: [
                  if (!suggestion.txAllowed)
                    _Badge(
                      label: 'Listen only',
                      color: theme.colorScheme.secondaryContainer,
                      onColor: theme.colorScheme.onSecondaryContainer,
                    ),
                  if (suggestion.requiresTxUnlock)
                    _Badge(
                      label: 'Needs widened range',
                      color: theme.colorScheme.tertiaryContainer,
                      onColor: theme.colorScheme.onTertiaryContainer,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _summary() {
    final channel = suggestion.channel;
    final parts = <String>[
      if (suggestion.distanceKm case final double km)
        '${km < 10 ? km.toStringAsFixed(1) : km.round()} km',
      if (!channel.isSimplex && !channel.rxOnly)
        '${channel.offsetHz > 0 ? '+' : '−'}'
            '${formatHzAsMegahertz(channel.offsetHz.abs())} MHz',
      if (channel.isSimplex && !channel.rxOnly) 'simplex',
      if (!channel.txTone.isNone) 'tone ${channel.txTone.label}',
      if (suggestion.callsign case final String callsign) callsign,
    ];
    return parts.isEmpty ? channel.mode.chirpName : parts.join(' · ');
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color onColor;

  const _Badge({
    required this.label,
    required this.color,
    required this.onColor,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: onColor),
    ),
  );
}
