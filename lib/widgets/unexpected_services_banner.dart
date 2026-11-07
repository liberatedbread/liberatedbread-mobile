// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/log.dart';
import '../core/mono_text.dart';
import '../models/svc_report.dart';
import '../providers/ble_provider.dart' show isMockMode;
import '../providers/ha_provider.dart' show urlOpenerProvider;
import '../providers/svc_report_provider.dart';
import '../services/svc_report_service.dart';

/// "Oh hey — unexpected services": a device exposed services its matched
/// spec does not describe, and the user can tell us in one tap.
///
/// **Send report** does both at once — posts the report to the svc-reports
/// backend and opens the user's mail app with the same report addressed to
/// us, so whichever half works, we hear about it. **Email only** skips the
/// server. **What's sent?** shows the payload verbatim before anything leaves
/// the phone.
///
/// Renders nothing for a null [report] or one the user already sent or
/// dismissed (by [SvcReport.dedupeKey], so a different surprise on the same
/// spec still asks).
class UnexpectedServicesBanner extends ConsumerStatefulWidget {
  final SvcReport? report;

  /// Outer spacing, so a screen can drop the banner into its list without a
  /// wrapper that would take up room when the banner renders nothing.
  final EdgeInsetsGeometry padding;

  const UnexpectedServicesBanner({
    super.key,
    required this.report,
    this.padding = const EdgeInsets.only(bottom: 12),
  });

  @override
  ConsumerState<UnexpectedServicesBanner> createState() =>
      _UnexpectedServicesBannerState();
}

class _UnexpectedServicesBannerState
    extends ConsumerState<UnexpectedServicesBanner> {
  /// Fixed for this banner's life, so the details dialog, the POST and the
  /// email all name the same report — and a second tap after a failure is a
  /// retry the backend can recognise, not a duplicate.
  String _reportId = newReportId();
  String? _forKey;
  bool _busy = false;

  SvcReport? get _report {
    final draft = widget.report;
    if (draft == null) return null;
    if (_forKey != draft.dedupeKey) {
      // A different surprise: a different report.
      _forKey = draft.dedupeKey;
      _reportId = newReportId();
    }
    return SvcReport(
      reportId: _reportId,
      transport: draft.transport,
      specKey: draft.specKey,
      specDeviceName: draft.specDeviceName,
      specManufacturer: draft.specManufacturer,
      advertisedName: draft.advertisedName,
      unexpected: draft.unexpected,
      discovered: draft.discovered,
      declared: draft.declared,
      appVersion: draft.appVersion,
      platform: draft.platform,
    );
  }

  Future<bool> _email(SvcReport report) async {
    try {
      return await ref.read(urlOpenerProvider)(
        report.mailtoUri(AppConstants.svcReportsEmail),
      );
    } on Exception catch (e) {
      // url_launcher says "nothing handles mailto" with false on one
      // platform and a PlatformException on another; both mean the same.
      Log.reports.info('no mail app for report ${report.reportId}', error: e);
      return false;
    }
  }

  Future<bool> _post(SvcReport report) async {
    // Mock mode is the app's "no external dependencies" switch (see
    // AdBannerNotifier); a demo build does not file reports for real.
    if (isMockMode) {
      Log.reports.info('mock mode: not posting report ${report.reportId}');
      return true;
    }
    final result = await ref
        .read(svcReportServiceProvider)
        .submit(AppConstants.svcReportsUrl, report);
    return result is SvcReportAccepted;
  }

  Future<void> _send({required bool toServer}) async {
    final report = _report;
    if (report == null || _busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    // Simultaneously: the POST is in flight while the mail app opens.
    final posted = toServer ? _post(report) : Future.value(false);
    final emailed = await _email(report);
    final serverOk = await posted;
    if (!mounted) return;
    setState(() => _busy = false);

    final String message;
    if (toServer && serverOk && emailed) {
      message = 'Report sent — thanks! Your email to us is ready to send too.';
    } else if (toServer && serverOk) {
      message = 'Report sent — thanks!';
    } else if (emailed) {
      message = toServer
          ? "Couldn't reach our server, but the email has everything — "
                'just hit send.'
          : 'Your email to us is ready — just hit send.';
    } else {
      message = toServer
          ? "Couldn't send the report. Check your connection and try again."
          : 'No mail app to open.';
    }
    final handled = serverOk || emailed;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        // Email only, and there is no mail app: offer the other route.
        action: !toServer && !emailed
            ? SnackBarAction(
                label: 'Send to server',
                onPressed: () => unawaited(_send(toServer: true)),
              )
            : null,
      ),
    );
    if (handled) {
      await ref
          .read(svcReportHandledProvider.notifier)
          .markHandled(report.dedupeKey);
    }
  }

  Future<void> _showDetails(SvcReport report) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text("What's sent"),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Exactly this, and nothing else. No Bluetooth or network '
              'address, no hostname, and nothing you named the device.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              report.toPrettyJson(),
              style: monoTextStyleOf(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text(
              'Sent to ${Uri.parse(AppConstants.svcReportsUrl).host} and/or '
              '${AppConstants.svcReportsEmail}.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final report = _report;
    if (report == null) return const SizedBox.shrink();
    final handled = ref.watch(svcReportHandledProvider);
    if (handled.contains(report.dedupeKey)) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final count = report.unexpected.length;
    final what = count == 1 ? 'a service' : '$count services';

    return Padding(
      padding: widget.padding,
      child: Card(
        margin: EdgeInsets.zero,
        color: scheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.travel_explore,
                    color: scheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Oh hey — unexpected services',
                      style: text.titleSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    icon: const Icon(Icons.close),
                    color: scheme.onSecondaryContainer,
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            ref
                                .read(svcReportHandledProvider.notifier)
                                .markHandled(report.dedupeKey),
                          ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  'This device shows $what that its '
                  '${report.specManufacturer} ${report.specDeviceName} spec '
                  "doesn't describe. Telling us helps fix the spec — the "
                  'report identifies the device type, not you.',
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_send(toServer: true)),
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    label: const Text('Send report'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_send(toServer: false)),
                    child: const Text('Email only'),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_showDetails(report)),
                    child: const Text("What's sent?"),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
