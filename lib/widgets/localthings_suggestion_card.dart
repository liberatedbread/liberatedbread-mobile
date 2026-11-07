// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/localthings.dart';
import '../providers/ha_provider.dart';
import '../providers/localthings_provider.dart';

/// Points a SmartThings household that runs Home Assistant at LocalThings.
///
/// Mounted by the Wi-Fi scan once it has seen a SmartThings advertisement.
/// It renders only when there is a Home Assistant to install LocalThings
/// into: one connected in the app's settings, or one announcing itself on the
/// network ([discoveredHaUrl]). A SmartThings hub with no Home Assistant in
/// sight gets nothing here — sending someone to install a home server to
/// rescue a washer is a different conversation, and the hub's own details say
/// where to read about it.
///
/// When Home Assistant is connected the card asks it (over `/api/components`)
/// whether LocalThings is already loaded, and turns from "get it" into "add
/// an appliance" when it is.
class LocalThingsSuggestionCard extends ConsumerWidget {
  /// A Home Assistant this scan found over mDNS, as [homeAssistantUrlOf]
  /// resolved it. Null when the scan found none.
  final String? discoveredHaUrl;

  /// Opens a link. The screen's, so a refusal is reported the same way as
  /// every other link it opens.
  final void Function(Uri uri) onOpen;

  const LocalThingsSuggestionCard({
    super.key,
    required this.discoveredHaUrl,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(localThingsStatusProvider).valueOrNull;
    final configuredUrl = ref.watch(haConfigProvider).valueOrNull?.baseUrl;
    final haConnected =
        status != null && status != LocalThingsStatus.noHomeAssistant;
    // Nothing to install into, or nothing known yet and nothing discovered.
    if (!haConnected && discoveredHaUrl == null) {
      return const SizedBox.shrink();
    }
    // The address the user connected the app to beats one a TXT record
    // advertised: it is the one already proven to work from this phone.
    final haUrl = (configuredUrl != null && configuredUrl.isNotEmpty)
        ? configuredUrl
        : discoveredHaUrl;
    final addAppliance = localThingsAddApplianceUrl(haBaseUrl: haUrl);

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final installed = status == LocalThingsStatus.installed;
    final foreground = scheme.onTertiaryContainer;

    final title = installed
        ? 'LocalThings is in your Home Assistant'
        : 'Take your Samsung appliances local';
    final body = installed
        ? 'Add your Samsung washer, dryer, fridge, oven or air conditioner '
              'there by its IP address. LocalThings talks to it on this '
              'network, with no Samsung account. The SmartThings hub itself '
              'stays on the cloud.'
        : 'SmartThings and Home Assistant are both on this network. '
              'LocalThings is a Home Assistant integration that controls '
              'Samsung washers, dryers, fridges, ovens and air conditioners '
              'over your own network, with no Samsung account. It does not '
              'drive the SmartThings hub or the Zigbee and Z-Wave devices '
              'paired to it.';

    return Card(
      key: const Key('localthings-suggestion'),
      color: scheme.tertiaryContainer,
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  installed ? Icons.check_circle_outline : Icons.home_outlined,
                  color: foreground,
                  size: 20,
                ),
                const SizedBox(width: 8),
                // Expanded so the title wraps at large text sizes instead of
                // overflowing beside the icon.
                Expanded(
                  child: Text(
                    title,
                    style: text.titleSmall?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(body, style: text.bodySmall?.copyWith(color: foreground)),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                if (installed)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: foreground),
                    onPressed: () => onOpen(addAppliance),
                    child: const Text('Add an appliance'),
                  )
                else ...[
                  // "Already have it?" only when nobody could say: a Home
                  // Assistant that answered "not installed" has no appliance
                  // flow to start.
                  if (status != LocalThingsStatus.notInstalled)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: foreground),
                      onPressed: () => onOpen(addAppliance),
                      child: const Text('Already installed? Add one'),
                    ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: foreground),
                    onPressed: () => onOpen(localThingsHacsUrl),
                    child: const Text('Get LocalThings'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
