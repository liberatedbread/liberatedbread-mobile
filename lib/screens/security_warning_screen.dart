// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/iot_device.dart';
import '../providers/scan_match_provider.dart';
import '../services/spec_codec.dart' show MatchConfidence, SecurityAdvisoryDto;

/// The page a scan result opens when the catalogue matched a spec carrying a
/// `security_advisory` — a device with a known, cited security problem. It
/// replaces the control screen entirely: for these devices the honest action
/// is to explain the risk and, where the vendor shipped one, point at the fix,
/// not to offer buttons.
///
/// The match that brought the user here can be uncertain (these are recognised
/// by an inferred name, not a captured signature), so the wording hedges on
/// [guess]'s confidence rather than asserting the device IS the flawed product.
class SecurityWarningScreen extends StatelessWidget {
  final IoTDevice device;
  final SecurityAdvisoryDto advisory;

  /// The match, for its confidence — a `possible` match warrants "this might
  /// be", a stronger one "this is".
  final ScanGuess guess;

  const SecurityWarningScreen({
    super.key,
    required this.device,
    required this.advisory,
    required this.guess,
  });

  /// The colour a severity is drawn in. `malicious`/`vulnerable` take the
  /// theme's error colour; `reported` a softer caution (tertiary).
  Color _accent(ColorScheme scheme) => switch (advisory.severity) {
        'malicious' || 'vulnerable' => scheme.error,
        _ => scheme.tertiary,
      };

  IconData get _icon => switch (advisory.severity) {
        'malicious' => Icons.gpp_bad_outlined,
        'vulnerable' => Icons.dangerous_outlined,
        _ => Icons.gpp_maybe_outlined,
      };

  String get _severityLabel => switch (advisory.severity) {
        'malicious' => 'Do not trust this device',
        'vulnerable' => 'Known vulnerability',
        _ => 'Reported issue',
      };

  /// How sure we are it is this device. These specs match on an inferred name,
  /// so a low-confidence match is the norm and the page says so.
  String _certaintyLine() {
    final name = guess.deviceName;
    return switch (guess.confidence) {
      MatchConfidence.strong =>
        'This device matches $name, which has the problem below.',
      MatchConfidence.likely =>
        'This device looks like $name, which has the problem below.',
      MatchConfidence.possible =>
        'This might be $name. The match is by name only, so treat it as a '
            'heads-up to check, not a certainty.',
    };
  }

  Future<void> _open(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accent = _accent(scheme);
    final mitigationUrl = advisory.mitigationUrl;
    final mitigationSummary = advisory.mitigationSummary;
    final advisoryUrl = advisory.advisoryUrl;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Security warning')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            // The severity banner: colour + icon + the plain-language label.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withValues(alpha: 0.5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_icon, color: accent, size: 32),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_severityLabel,
                            style: text.titleMedium?.copyWith(
                                color: accent, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(advisory.summary.trim(),
                            style: text.bodyMedium
                                ?.copyWith(color: scheme.onSurface)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(device.displayName,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(_certaintyLine(),
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            if ((advisory.detail ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(advisory.detail!.trim(),
                  style: text.bodyMedium?.copyWith(height: 1.4)),
            ],
            const SizedBox(height: 20),

            // The fix, when the vendor shipped one — the most useful thing on
            // the page for a `vulnerable` device the owner controls.
            if (mitigationSummary != null) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.build_outlined,
                          size: 20, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text('How to fix it',
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 8),
                    Text(mitigationSummary.trim(), style: text.bodyMedium),
                    if (mitigationUrl != null) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => _open(context, mitigationUrl),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Open the fix'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ] else if (advisory.severity != 'malicious') ...[
              // No mitigation given: say so, rather than let the absence imply
              // there is nothing to worry about.
              Text('No fix has been published yet.',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
            ],

            if (advisoryUrl != null)
              OutlinedButton.icon(
                onPressed: () => _open(context, advisoryUrl),
                icon: const Icon(Icons.article_outlined, size: 18),
                label: const Text('Read the advisory'),
              ),
          ],
        ),
      ),
    );
  }
}
