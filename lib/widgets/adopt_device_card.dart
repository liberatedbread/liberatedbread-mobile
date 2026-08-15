// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/adopt_provider.dart';

/// The entry point to the adoption flow, shown on the Wi-Fi tab.
///
/// Its icon comes alive — a slow rotation — when the OS reports a device's
/// setup network (Wemo…, LIFX…) is actually in range, so a user who has just
/// reset a device sees the app notice it. On platforms that cannot enumerate
/// Wi-Fi (iOS, desktop) the hint provider always yields null, the icon stays
/// still, and the card is a plain, always-available button — no worse than
/// before, and never falsely animated.
class AdoptDeviceCard extends ConsumerStatefulWidget {
  final VoidCallback onTap;

  const AdoptDeviceCard({super.key, required this.onTap});

  @override
  ConsumerState<AdoptDeviceCard> createState() => _AdoptDeviceCardState();
}

class _AdoptDeviceCardState extends ConsumerState<AdoptDeviceCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  void _syncSpin(bool nearby) {
    // Drive the controller from the hint, not from a build flag: repeat() and
    // stop() are idempotent enough that syncing every build is fine, but guard
    // anyway so we do not restart the tween mid-turn on an unrelated rebuild.
    if (nearby && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!nearby && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final nearby = ref.watch(nearbySetupNetworkProvider).valueOrNull;
    final isNearby = nearby != null;
    _syncSpin(isNearby);

    return Card(
      margin: EdgeInsets.zero,
      color:
          isNearby ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              RotationTransition(
                key: const ValueKey('adopt-spin'),
                turns: _spin,
                child: Icon(
                  Icons.wifi_tethering,
                  color:
                      isNearby ? scheme.onSecondaryContainer : scheme.secondary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Adopt a new Wi-Fi device',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isNearby ? scheme.onSecondaryContainer : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isNearby
                          ? 'A "${nearby.profile.ssidPrefix}…" setup network is '
                              'in range — tap to set it up'
                          : 'Set up a reset Wemo or LIFX device on your Wi-Fi',
                      style: text.bodySmall?.copyWith(
                        color: isNearby
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right,
                  color: isNearby
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
