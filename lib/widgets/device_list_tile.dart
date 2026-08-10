// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Row and section chrome shared by the three device lists: nearby BLE, saved,
// and Wi-Fi. One component for all of them keeps the lists visually consistent
// and keeps the support-badge wording -- which is the careful part -- in one
// place rather than three.

import 'package:flutter/material.dart';

import '../core/find_device.dart' show signalBars;

/// Section label with a count pill, e.g. "Found · 2".
class SectionHeader extends StatelessWidget {
  final String label;
  final int count;

  const SectionHeader({super.key, required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Text(
          label,
          style: text.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$count',
            style: text.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// A device row — used for both live scan results and saved history entries.
///
/// One component for both keeps the two lists visually consistent; the only
/// difference is the trailing detail (signal vs. last-seen) and whether a
/// forget action is offered.
class DeviceListTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String detail;
  final int? rssi;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onForget;

  /// What the spec catalogue makes of this device, when it makes anything.
  final String? badge;

  /// Whether [badge] is a claim of support or merely a hint. A hint is styled
  /// down deliberately: "Possibly Xiaomi" off the back of a shared OUI must not
  /// look like the same kind of statement as a matched service UUID.
  final bool badgeIsClaim;

  /// What the device broadcast about itself, for one no spec matched — its
  /// maker, the standard services it offers, its address. Observation, not
  /// identification.
  final String? description;

  /// Whether this device has stopped being heard from.
  ///
  /// Replaces the signal meter with a warning glyph, because the two say
  /// contradictory things: the bars would report a signal strength measured
  /// back when the device was last on air, drawn identically to one measured a
  /// moment ago. A row is kept rather than dropped — advertising is lossy and
  /// the device is probably still there — but it should not claim a signal it
  /// no longer has.
  final bool stale;

  /// Spelled-out reason for the [stale] glyph, e.g. "No advertisement for 2m".
  /// Surfaces as the icon's tooltip and its semantic label, so the warning is
  /// not shape-only.
  final String? staleReason;

  const DeviceListTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.detail,
    this.rssi,
    this.icon = Icons.bluetooth,
    this.enabled = true,
    this.onTap,
    this.onForget,
    this.badge,
    this.badgeIsClaim = false,
    this.description,
    this.stale = false,
    this.staleReason,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Unconnectable devices stay visible but recede, so the list still reflects
    // what's on air without inviting a tap that would do nothing.
    final tint = enabled ? scheme.onSurface : scheme.onSurfaceVariant;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: tint, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: tint,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: _SupportBadge(
                              label: badge!,
                              isClaim: badgeIsClaim,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (stale) ...[
                          Tooltip(
                            message: staleReason ?? 'Not seen recently',
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 16,
                              color: scheme.error,
                              semanticLabel: staleReason ?? 'Not seen recently',
                            ),
                          ),
                          const SizedBox(width: 6),
                        ] else if (rssi != null) ...[
                          _SignalBars(rssi: rssi!, color: scheme.secondary),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            subtitle,
                            style: text.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '  ·  $detail',
                          style: text.bodySmall?.copyWith(
                            color:
                                scheme.onSurfaceVariant.withValues(alpha: 0.7),
                            // Tabular figures stop the row jittering as values
                            // update.
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        description!,
                        style: text.bodySmall?.copyWith(
                          color:
                              scheme.onSurfaceVariant.withValues(alpha: 0.75),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (onForget != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 18,
                  tooltip: 'Forget $title',
                  onPressed: onForget,
                )
              else if (onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pill naming what the catalogue thinks a scanned device is.
///
/// Two visual weights, because there are two different statements to make.
/// A claim ("Ember Mug", "Likely Ember Mug") is filled in the accent colour; a
/// hint ("Possibly Xiaomi", from a shared OUI and nothing else) is outlined and
/// muted. Both carry their own wording, so the distinction survives without
/// colour perception.
class _SupportBadge extends StatelessWidget {
  final String label;
  final bool isClaim;

  const _SupportBadge({required this.label, required this.isClaim});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isClaim ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: isClaim ? null : Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.labelSmall?.copyWith(
          color: isClaim
              ? scheme.onSecondaryContainer
              : scheme.onSurfaceVariant.withValues(alpha: 0.8),
          fontWeight: isClaim ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}

/// Four-step signal meter.
///
/// Signal strength is conveyed by bar count as well as colour, so it still
/// reads without colour perception.
class _SignalBars extends StatelessWidget {
  final int rssi;
  final Color color;

  const _SignalBars({required this.rssi, required this.color});

  // Shared with the scan list's ordering, deliberately: the bars a row draws
  // and the band it sorts into must be the same judgement, or a row can sit
  // above another while showing fewer bars.
  int get _filled => signalBars(rssi);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        final on = i < _filled;
        return Container(
          width: 3,
          height: 5.0 + (i * 3),
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: on ? color : color.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

/// The pill-shaped action button both scan screens use for retry / scan again /
/// open settings. One widget so the sizing and icon-gap chrome cannot drift
/// between the tabs — this was previously pasted five times.
class ActionPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const ActionPillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}
