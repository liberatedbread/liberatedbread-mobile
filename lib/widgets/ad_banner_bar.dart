// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../providers/ad_banner_provider.dart';
import '../providers/ha_provider.dart';

/// The small house-ad bar docked under the scan screen.
///
/// Renders nothing while [adBannerProvider] has nothing to show, so it can sit
/// permanently in the Scaffold's bottomNavigationBar slot. Everything about it
/// is non-blocking: the provider seeds synchronously from bundled/cached
/// content, and a tap hands off to the external browser without awaiting it.
class AdBannerBar extends ConsumerWidget {
  const AdBannerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = ref.watch(adBannerProvider);
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
          child: InkWell(
            onTap: () {
              final open = ref.read(urlOpenerProvider);
              // Fire-and-forget like every hand-off to the platform in this
              // app: a browser that fails to open must not become an unhandled
              // async error.
              unawaited(open(banner.url).catchError((Object e) {
                Log.ads.warning('could not open ${banner.url}', error: e);
                return false;
              }));
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
              child: Row(
                children: [
                  _AdTag(scheme: scheme, text: text),
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
                  Text(
                    banner.cta,
                    style: text.labelLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: scheme.primary),
                  IconButton(
                    icon: const Icon(Icons.close),
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    color: scheme.onSurfaceVariant,
                    tooltip: 'Dismiss ad',
                    onPressed: () =>
                        unawaited(ref.read(adBannerProvider.notifier).dismiss()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiny "AD" pill so the bar is honest about being a promotion.
class _AdTag extends StatelessWidget {
  final ColorScheme scheme;
  final TextTheme text;

  const _AdTag({required this.scheme, required this.text});

  @override
  Widget build(BuildContext context) {
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
          fontSize: 9,
        ),
      ),
    );
  }
}
