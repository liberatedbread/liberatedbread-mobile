// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
class AppConstants {
  AppConstants._();
  static const String appName = 'Liberated Bread';
  static const String appTagline = 'Own your devices, don\'t let them own you.';
  static const String appVersion = '0.1.0';
  // 30s, not 10: some controllers (e.g. the SmartDawn/Daniao curtain) advertise
  // slowly, and a short window ended before they appeared.
  static const int defaultScanDuration = 30;
  static const int nearbyRssiThreshold = -70;

  /// App identifier sent to Home Assistant's mobile_app registration.
  static const String haAppId = 'ca.pigscanfly.liberatedbread';

  /// Tailscale's guide for putting Home Assistant on a tailnet.
  static const String tailscaleHaKbUrl =
      'https://tailscale.com/kb/1123/home-assistant';

  /// Default source for the downloadable device-spec pack. Points at a JSON
  /// manifest (see [SpecPackService]); user-overridable in spec-pack settings.
  static const String defaultSpecPackUrl =
      'https://raw.githubusercontent.com/PigsCanFlyLabs/opengreeniot-device-specs/main/pack.json';

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
