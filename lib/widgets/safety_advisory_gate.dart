// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/saved_device_provider.dart';
import '../services/spec_codec.dart';

/// Wraps a device's controls with a physical-safety advisory the spec declares
/// (`device.safety_advisory` — an IPL hair-removal handset can permanently burn
/// skin or injure eyes).
///
/// Deliberately unlike the security-advisory path, which replaces the controls
/// with a warning page: a safety advisory does NOT hide the controls, because
/// the device is meant to be used — carefully. A persistent banner sits above
/// [child]; and when the advisory sets `acknowledge_required`, the controls stay
/// behind a one-time "I understand" acknowledgement (remembered per device), an
/// informed-consent gate that still leads to full control.
class SafetyAdvisoryGate extends ConsumerStatefulWidget {
  final SafetyAdvisoryDto advisory;

  /// Stable per-device key the acknowledgement is remembered under (the BLE
  /// device id). Each physical unit is acknowledged once.
  final String ackKey;
  final Widget child;

  const SafetyAdvisoryGate({
    super.key,
    required this.advisory,
    required this.ackKey,
    required this.child,
  });

  static const prefsPrefix = 'safety_ack:';

  @override
  ConsumerState<SafetyAdvisoryGate> createState() => _SafetyAdvisoryGateState();
}

class _SafetyAdvisoryGateState extends ConsumerState<SafetyAdvisoryGate> {
  late bool _acknowledged;

  String get _prefsKey => '${SafetyAdvisoryGate.prefsPrefix}${widget.ackKey}';

  @override
  void initState() {
    super.initState();
    // No acknowledgement asked for => just show the banner over the controls.
    // Otherwise the remembered acknowledgement decides whether the controls are
    // gated. Prefs are resolved eagerly at launch, so this read is synchronous.
    if (!widget.advisory.acknowledgeRequired) {
      _acknowledged = true;
    } else {
      final prefs = ref.read(sharedPreferencesProvider);
      _acknowledged = prefs.getString(_prefsKey) != null;
    }
  }

  Future<void> _acknowledge() async {
    final prefs = ref.read(sharedPreferencesProvider);
    // Store the severity that was acknowledged (presence is what gates); this
    // leaves room to re-prompt if a device's hazard is ever escalated upstream.
    await prefs.setString(_prefsKey, widget.advisory.severity);
    if (mounted) setState(() => _acknowledged = true);
  }

  @override
  Widget build(BuildContext context) {
    // Before acknowledgement the detail is expanded — it is the whole point;
    // afterwards it collapses so the controls stay the focus.
    final banner = _SafetyBanner(
      advisory: widget.advisory,
      initiallyExpanded: !_acknowledged,
    );

    if (_acknowledged) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [banner, Expanded(child: widget.child)],
      );
    }

    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        banner,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: _acknowledge,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('I understand the risks — show controls'),
          ),
        ),
      ],
    );
  }
}

/// The coloured banner itself: severity, one-line summary, and — expanded — the
/// full detail plus the manufacturer safety link and its archived copy.
class _SafetyBanner extends StatelessWidget {
  final SafetyAdvisoryDto advisory;
  final bool initiallyExpanded;

  const _SafetyBanner(
      {required this.advisory, required this.initiallyExpanded});

  Color _accent(ColorScheme s) => switch (advisory.severity) {
        'danger' => s.error,
        'warning' => s.tertiary,
        _ => s.secondary,
      };

  IconData get _icon => switch (advisory.severity) {
        'danger' => Icons.dangerous_outlined,
        'warning' => Icons.warning_amber_outlined,
        _ => Icons.info_outline,
      };

  String get _label => switch (advisory.severity) {
        'danger' => 'Safety warning',
        'warning' => 'Use with care',
        _ => 'Safety note',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accent = _accent(scheme);
    final links = <Widget>[
      if (advisory.advisoryUrl != null)
        _link(context, 'Safety instructions', advisory.advisoryUrl!),
      if (advisory.advisoryArchiveUrl != null)
        _link(context, 'Archived copy', advisory.advisoryArchiveUrl!),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: .5)),
      ),
      clipBehavior: Clip.antiAlias,
      // The ExpansionTile (a ListTile) paints its ink and background on the
      // nearest Material; without a transparent Material here it would paint
      // behind this coloured Container and Flutter asserts. Transparent so the
      // Container's colour still shows through.
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          // Drop the ExpansionTile's default top/bottom divider lines inside the
          // coloured card.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: initiallyExpanded,
            leading: Icon(_icon, color: accent),
            title: Text(
              _label,
              style: text.titleSmall
                  ?.copyWith(color: accent, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(advisory.summary, style: text.bodySmall),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (advisory.detail != null) ...[
                Text(advisory.detail!, style: text.bodyMedium),
                const SizedBox(height: 12),
              ],
              if (links.isNotEmpty)
                Wrap(spacing: 12, runSpacing: 4, children: links),
            ],
          ),
        ),
      ),
    );
  }

  Widget _link(BuildContext context, String label, String url) =>
      OutlinedButton.icon(
        onPressed: () => _open(context, url),
        icon: const Icon(Icons.open_in_new, size: 16),
        label: Text(label),
      );

  Future<void> _open(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }
}
