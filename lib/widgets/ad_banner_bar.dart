// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../models/ad_banner.dart';
import '../providers/ad_banner_provider.dart';
import '../providers/ha_provider.dart';

/// The small house-ad bar docked under the scan screen — the GLOBAL promotion.
///
/// Renders nothing while there is nothing to show, so it can sit permanently in
/// the Scaffold's bottomNavigationBar slot. Everything about it is non-blocking:
/// the provider seeds synchronously from bundled/cached content, and a tap hands
/// off to the external browser without awaiting it.
class AdBannerBar extends ConsumerWidget {
  const AdBannerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = ref.watch(adBannerProvider);
    return _AdBannerContent(banner: banner);
  }
}

/// The house-ad bar docked under a device screen — the banner TARGETED at that
/// device (label-roll supplies for a label printer, filter kits for a Rabbit
/// Air, …), falling back to the global promotion when nothing targets it.
///
/// [category] and [specKey] come from the device's matched spec
/// (`device.category` and `specKeyFor`); pass what is known and null for the
/// rest — an unmatched device still gets the global banner.
class DeviceAdBannerBar extends ConsumerWidget {
  final String? category;
  final String? specKey;

  const DeviceAdBannerBar({super.key, this.category, this.specKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = ref.watch(
      deviceAdBannerProvider(
        DeviceAdContext(category: category, specKey: specKey),
      ),
    );
    return _AdBannerContent(banner: banner);
  }
}

/// The shared visual. Renders nothing (zero height) when [banner] is null, so
/// both bars can sit permanently in a bottomNavigationBar slot.
class _AdBannerContent extends ConsumerWidget {
  final AdBanner? banner;

  const _AdBannerContent({required this.banner});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = this.banner;
    if (banner == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Material(
      color: scheme.surfaceContainerHigh,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        // The bar is the bottom-most widget, so it owns the bottom inset
        // (gesture bar / home indicator); the Scaffold body's SafeArea no
        // longer reaches down here.
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Expanded(
                // The ad is one link: MergeSemantics folds the InkWell's tap
                // node and the labelled node into one, and the inner content is
                // ExcludeSemantics'd so the message/CTA/tag do not also announce
                // as separate fragments — a screen reader hears "<message> —
                // <cta>, link" once. (Same fix as the light_control_card swatch;
                // this bar had been left out of it.)
                child: MergeSemantics(
                  child: Semantics(
                    link: true,
                    label: '${banner.message} — ${banner.cta}',
                    child: InkWell(
                      onTap: () {
                        final open = ref.read(urlOpenerProvider);
                        // Fire-and-forget like every hand-off to the platform in
                        // this app: a browser that fails to open must not become
                        // an unhandled async error.
                        unawaited(
                          open(banner.url).catchError((Object e) {
                            Log.ads.warning(
                              'could not open ${banner.url}',
                              error: e,
                            );
                            return false;
                          }),
                        );
                      },
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                          child: Row(
                            children: [
                              _AdTag(scheme: scheme),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  banner.message,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(height: 1.3),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Bounded so a long remote CTA (or large
                              // accessibility text) ellipsizes instead of
                              // overflowing — the message must keep some width.
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 120,
                                ),
                                child: Text(
                                  banner.cta,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.labelLarge?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Icon(
                                Icons.chevron_right,
                                size: 18,
                                color: scheme.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Full-size hit target, kept OUT of the link above so a dismiss
              // tap near the ad's own tap area can't misfire into the browser.
              IconButton(
                icon: const Icon(Icons.close),
                iconSize: 18,
                color: scheme.onSurfaceVariant,
                tooltip: 'Dismiss ad',
                onPressed: () => unawaited(
                  ref.read(adBannerStateProvider.notifier).dismiss(banner.id),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny "AD" pill so the bar is honest about being a promotion.
class _AdTag extends StatelessWidget {
  final ColorScheme scheme;

  const _AdTag({required this.scheme});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: scheme.outline),
      ),
      child: Text(
        'AD',
        style: text.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontSize: 10,
        ),
      ),
    );
  }
}
