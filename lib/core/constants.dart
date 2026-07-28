// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
class AppConstants {
  AppConstants._();
  static const String appName = 'Liberated Bread';
  static const String appTagline = 'Own your devices, don\'t let them own you.';
  static const String appVersion = '0.1.0';
  static const int defaultScanDuration = 10;
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
}
