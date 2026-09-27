// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
class AppConstants {
  AppConstants._();
  static const String appName = 'Liberated Bread';
  static const String appTagline = 'Own your devices, don\'t let them own you.';

  /// Which build this is: `git describe --tags --always --dirty`, stamped in by
  /// scripts/release.sh — `v0.1.0` on a tag, `v0.1.0-3-g1a2b3c4` three commits
  /// later. Neither store shows users a commit, so this is how a bug report
  /// gets back to source. Anything built another way (`flutter run`, a CI smoke
  /// build, a test) says `dev build` rather than pass for a release.
  static const String appVersion = String.fromEnvironment(
    'LIBERATED_BREAD_BUILD',
    defaultValue: 'dev build',
  );
  // 30s, not 10: some controllers (e.g. the SmartDawn/Daniao curtain) advertise
  // slowly, and a short window ended before they appeared.
  static const int defaultScanDuration = 30;
  static const int nearbyRssiThreshold = -70;

  /// App identifier sent to Home Assistant's mobile_app registration.
  static const String haAppId = 'ca.pigscanfly.liberatedbread';

  /// Tailscale's guide for putting Home Assistant on a tailnet.
  static const String tailscaleHaKbUrl =
      'https://tailscale.com/kb/1123/home-assistant';

  /// Default source for the downloadable device-spec pack. Points at the
  /// manifest CI publishes on the protocol-specs repo's main (see
  /// [SpecPackService] and the repo's scripts/generate_pack.py); each listed
  /// spec path resolves same-origin against this URL. User-overridable in
  /// spec-pack settings.
  static const String defaultSpecPackUrl =
      'https://raw.githubusercontent.com/liberatedbread/liberatedbread-protocol-specs/main/pack.json';

  /// Remote config for the bottom ad banner (see [AdBannerService]). Fetched
  /// in the background on launch so the promotion can change without an
  /// app-store release; the bundled [AdBanner.fallback] covers offline and
  /// first-launch.
  static const String adBannerConfigUrl =
      'https://liberatedbread.com/app/banner.json';

  /// The affiliate shop page the bundled fallback banner points at.
  static const String shopUrl = 'https://liberatedbread.com/shop/';

  /// The disclaimer / terms of use the first-launch gate makes the user accept.
  static const String disclaimerUrl = 'https://liberatedbread.com/disclaimer/';

  /// The privacy policy, linked alongside the disclaimer on the gate. (Kept
  /// https to match the disclaimer — a legal link should not downgrade.)
  static const String privacyUrl = 'https://liberatedbread.com/privacy/';

  /// The accepted-terms version stored on the device (see [termsAcceptedKey]).
  /// Bumping this re-shows the first-launch gate when the disclaimer materially
  /// changes.
  static const int termsVersion = 1;

  /// SharedPreferences key holding the highest [termsVersion] the user has
  /// accepted. Absent or lower than [termsVersion] means the gate is shown.
  static const String termsAcceptedKey = 'terms_accepted_version';
}
