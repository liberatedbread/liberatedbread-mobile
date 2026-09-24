// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The one way a URL that did not come from this codebase reaches the OS.
//
// Security-advisory and mitigation links come verbatim out of spec YAML, and
// specs are installable from a user-typed pack URL over plain http. Handing
// such a string straight to url_launcher (UIApplication.open on iOS) means a
// hostile or tampered pack can open `shortcuts://run-shortcut?name=…`,
// `tel:`, `sms:` or `itms-services://` behind a button that only says "Open
// the fix". So every such link goes through here, and only web links get out.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// How [openWebLink] hands a vetted URI to the platform. Injectable so a test
/// can record what would have been launched without a platform channel.
typedef LinkLauncher = Future<bool> Function(Uri uri);

/// The production launcher: the system browser (or the app registered for
/// the host), never an in-app web view.
Future<bool> launchExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Whether [uri] is a link this app is willing to open: http(s) with a host.
///
/// `javascript:`, `data:`, `file:`, custom app schemes and scheme-relative
/// strings all fail this, as does an `https:` with no host — `Uri.tryParse`
/// accepts all of them without complaint.
bool isWebLink(Uri? uri) =>
    uri != null &&
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty;

/// Open [url] in the system browser if it is a web link, else tell the user.
///
/// A launcher that declines and one that throws are the same failure to the
/// user, and get the same SnackBar: url_launcher answers "nothing handles
/// this" with `false` on one platform and a `PlatformException` on another,
/// and neither is allowed out of a tap as an unhandled error.
///
/// The SnackBar is looked up before the first await so a screen that is
/// disposed while the launcher runs still has somewhere to report to.
Future<void> openWebLink(
  BuildContext context,
  String url, {
  LinkLauncher launcher = launchExternally,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.tryParse(url.trim());
  var opened = false;
  if (isWebLink(uri)) {
    try {
      opened = await launcher(uri!);
    } on Exception {
      opened = false;
    }
  }
  if (!opened) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}
