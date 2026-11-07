// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/log.dart';
import '../models/svc_report.dart';

/// The outcome of [SvcReportService.submit].
@immutable
sealed class SvcReportSubmitResult {
  const SvcReportSubmitResult();
}

/// The backend stored the report (or already had it: a retried POST of the
/// same report id answers the same way).
final class SvcReportAccepted extends SvcReportSubmitResult {
  const SvcReportAccepted();
}

/// It did not, and [reason] says why in words fit for a log line.
final class SvcReportFailed extends SvcReportSubmitResult {
  final String reason;
  const SvcReportFailed(this.reason);
}

/// Posts an unexpected-services report to the svc-reports backend.
///
/// Called only from a tap, never in the background. Every failure resolves
/// to [SvcReportFailed] rather than a throw, because the banner hands the
/// same report to the mail app regardless and must not lose that half to an
/// exception in this one.
class SvcReportService {
  final http.Client _client;
  final Duration timeout;

  SvcReportService({
    required this._client,
    this.timeout = const Duration(seconds: 15),
  });

  Future<SvcReportSubmitResult> submit(
    String endpoint,
    SvcReport report,
  ) async {
    final uri = Uri.tryParse(endpoint.trim());
    // https only: the payload is small and anonymous, but it is still the
    // user's, and there is no reason for this endpoint to ever be plaintext.
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return const SvcReportFailed('not a valid https URL');
    }
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode(report.toJson()),
          )
          .timeout(timeout);
    } on TimeoutException {
      Log.reports.info('report ${report.reportId}: timed out');
      return const SvcReportFailed('timed out');
    } on Object catch (e) {
      Log.reports.info('report ${report.reportId}: network error', error: e);
      return const SvcReportFailed('network error');
    }
    if (response.statusCode == 200 || response.statusCode == 201) {
      Log.reports.info('report ${report.reportId}: accepted');
      return const SvcReportAccepted();
    }
    Log.reports.warning(
      'report ${report.reportId}: HTTP ${response.statusCode}',
    );
    return SvcReportFailed('HTTP ${response.statusCode}');
  }
}
