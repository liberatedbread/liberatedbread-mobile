// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A finer-grained device glyph than [DeviceCategory] gives — the "recognise it
// on sight" icon for devices worth drawing distinctly even when this app does
// not control them (a UniFi access point, a MikroTik router, a NAS, a
// Nintendo console, a 3D printer).

import 'package:flutter/material.dart';

import 'device_category.dart';

/// Resolves a spec's `device.pictogram` token to a glyph — a finer-grained
/// icon than the broad `category`. A NAS, a power strip and a phone are all
/// "network" or "switch" or "other" by category, but each deserves its own
/// picture in the scan list.
///
/// The vocabulary is owned upstream (the token strings live in
/// `device-specs/schema.json`'s `pictogram` description) and this table is a
/// *view* of it, exactly as [DeviceCategory] is a view of the category
/// vocabulary: an unknown token is not an error — it resolves to nothing and
/// the caller falls back to the category icon, then to its own generic glyph.
/// A pictogram added upstream after this build shipped costs only the specific
/// glyph, never the device. That is why the table is deliberately tolerant and
/// never throws.
///
/// Glyph choices are pinned to names verified present in Flutter's bundled
/// Material Icons font (not the newer Material Symbols set, which this app
/// does not ship), in the outlined style the category icons already use. Most
/// tokens map to a Material glyph ([iconFor]); a few need a custom painter the
/// caller draws itself ([isCustom]).
abstract final class DevicePictogram {
  /// token -> glyph. Kebab-case tokens, matching the spec vocabulary.
  static const Map<String, IconData> _glyphs = {
    // Network infrastructure
    'wifi-ap': Icons.wifi_tethering_outlined,
    'access-point': Icons.wifi_tethering_outlined,
    'network-switch': Icons.lan_outlined,
    'switch-network': Icons.lan_outlined,
    'router': Icons.router_outlined,
    'gateway': Icons.router_outlined,
    'firewall': Icons.security_outlined,
    'cloud-key': Icons.vpn_key_outlined, // a UniFi console/controller
    'nvr': Icons.dvr_outlined,
    'nas': Icons.storage_outlined,
    'file-server': Icons.storage_outlined,

    // Cameras
    'ip-camera': Icons.videocam_outlined,
    'cctv': Icons.videocam_outlined,
    'video-doorbell': Icons.doorbell_outlined,
    'doorbell': Icons.doorbell_outlined,

    // Computers / consoles / phones
    'laptop': Icons.laptop_outlined,
    'laptop-apple': Icons.laptop_mac_outlined,
    'macbook': Icons.laptop_mac_outlined,
    'laptop-windows': Icons.laptop_windows_outlined,
    'desktop': Icons.desktop_windows_outlined,
    'desktop-apple': Icons.desktop_mac_outlined,
    'mini-pc': Icons.desktop_mac_outlined,
    'monitor': Icons.desktop_windows_outlined,
    'drawable-display': Icons.grid_on_outlined,
    'game-console': Icons.sports_esports_outlined,
    'handheld-console': Icons.sports_esports_outlined,
    'phone': Icons.smartphone_outlined,

    // Media / voice
    'smart-speaker': Icons.speaker_outlined,
    'voice-assistant': Icons.assistant_outlined,
    'tv': Icons.tv_outlined,
    'streaming-stick': Icons.cast_outlined,

    // Appliances / sensors with a distinctive shape
    'light': Icons.lightbulb_outline,
    'printer': Icons.print_outlined,
    'label-printer': Icons.label_outlined,
    'thermal-printer': Icons.receipt_long_outlined,
    'thermostat': Icons.thermostat_outlined,
    'smoke-alarm': Icons.sensors_outlined, // no smoke-detector glyph
    'garage-door': Icons.garage_outlined,
    'power-station': Icons.battery_charging_full_outlined,
    'battery': Icons.battery_charging_full_outlined,
    'solar-gateway': Icons.solar_power_outlined,
    'air-quality': Icons.air_outlined,
    'co2-sensor': Icons.co2_outlined,
    'robot': Icons.smart_toy_outlined,

    // Lights, by what is lit. The category's bulb stays for bulbs.
    'led-strip': Icons.wb_iridescent_outlined,
    'light-panel': Icons.light_outlined,
    'string-lights': Icons.celebration_outlined,
    'flow-prop': Icons.auto_awesome_outlined,
    'tv-backlight': Icons.nightlight_outlined,
    'grow-light': Icons.eco_outlined,

    // LED displays worn or carried, apart from the panel/sign grid.
    'led-sign': Icons.text_fields_outlined,
    'name-badge': Icons.badge_outlined,
    'led-glasses': Icons.visibility_outlined,
    'led-mask': Icons.masks_outlined,
    'led-helmet': Icons.sports_motorsports_outlined,
    'led-backpack': Icons.backpack_outlined,

    // Sensors, by what they measure.
    'distance-meter': Icons.straighten_outlined,
    'thermometer': Icons.device_thermostat_outlined,
    'meat-thermometer': Icons.outdoor_grill_outlined,
    'soil-sensor': Icons.grass_outlined,
    'tank-sensor': Icons.propane_tank_outlined,
    'battery-monitor': Icons.battery_std_outlined,
    'radon-sensor': Icons.gas_meter_outlined,
    'gas-sensor': Icons.local_fire_department_outlined,

    // Health.
    'blood-pressure': Icons.speed_outlined,
    'pulse-oximeter': Icons.monitor_heart_outlined,
    'glucose-meter': Icons.bloodtype_outlined,

    // Vehicles and drives.
    'scooter': Icons.electric_scooter_outlined,
    'motorcycle': Icons.two_wheeler_outlined,
    'board': Icons.skateboarding_outlined,
    'obd-adapter': Icons.settings_input_component_outlined,
    'ebike-drive': Icons.electric_bike_outlined,
    'blind-motor': Icons.blinds_outlined,

    // Climate and kitchen.
    'air-conditioner': Icons.ac_unit_outlined,
    'air-purifier': Icons.air_outlined,
    'oven': Icons.microwave_outlined,
    'mug': Icons.coffee_outlined,
    'kettle': Icons.coffee_maker_outlined,
    'pressure-cooker': Icons.soup_kitchen_outlined,

    // Personal care and fitness.
    'toothbrush': Icons.brush_outlined,
    'ipl': Icons.face_retouching_natural_outlined,
    'rower': Icons.rowing_outlined,
    'fitness-band': Icons.watch_outlined,
    'smartwatch': Icons.watch_outlined,
    'kitchen-scale': Icons.scale_outlined,

    // Energy.
    'ev-charger': Icons.ev_station_outlined,

    // Everything else with a shape of its own.
    'smart-plug': Icons.power_outlined,
    'robot-vacuum': Icons.cleaning_services_outlined,
    'av-receiver': Icons.speaker_group_outlined,
    'key-finder': Icons.key_outlined,
    'drone': Icons.flight_outlined,
    'toy-car': Icons.toys_outlined,
    'wand': Icons.auto_fix_high_outlined,
    'instrument': Icons.music_note_outlined,
    'pet-toy': Icons.pets_outlined,

    // A device we can place on the network but not categorize further — a
    // Tuya beacon names no product type, only that it is one.
    'smart-device': Icons.devices_other_outlined,
  };

  /// The Material glyph for a pictogram token, or null when the token is
  /// absent, unknown, OR is drawn by a custom widget (see [isCustom]) — in
  /// each case the caller falls back (to a custom widget, then the category
  /// icon, then its own generic glyph).
  static IconData? iconFor(String? token) => _glyphs[_normalize(token)];

  /// Whether this token is drawn by a custom painter rather than a Material
  /// glyph — the caller builds the widget itself (the scan tile draws a
  /// [PowerStripIcon] for `power-strip`, a `ThreeDPrinterIcon` for
  /// `3d-printer`). Material has no faithful glyph for either, so both are
  /// painted.
  static bool isCustom(String? token) {
    final key = _normalize(token);
    return key == 'power-strip' || key == '3d-printer';
  }

  /// The glyph to draw for a device, most specific first: its `pictogram`
  /// token, then its [DeviceCategory] icon, then [fallback] (the caller's
  /// generic glyph, e.g. the scan tab's radio icon).
  ///
  /// [category] is the raw `device.category` string; it is parsed leniently so
  /// an unrecognised category degrades the same way an unrecognised pictogram
  /// does. A custom-painted pictogram falls through to the category here —
  /// this helper answers only in [IconData]; callers that can draw the painter
  /// check [isCustom] themselves.
  static IconData forDevice({
    String? pictogram,
    String? category,
    IconData fallback = unknownDeviceIcon,
  }) {
    return iconFor(pictogram) ??
        DeviceCategory.parse(category)?.icon ??
        fallback;
  }

  /// A pictogram token for a spec that declares none, worked out from its
  /// [category] and [deviceName]; null when nothing more specific than the
  /// category icon fits.
  ///
  /// Most of the catalogue sets no `pictogram`, so every LED sign looked like
  /// every LED panel, a laser distance meter like a thermometer, a scooter
  /// like a car. The spec's own name says which it is. Rules are scoped to a
  /// category so a word cannot stray ("band" is a fitness band under fitness
  /// and nothing under light), and the first that fits wins. A spec's own
  /// token always outranks this — see [forSpec].
  static String? infer({required String deviceName, String? category}) {
    final name = deviceName.toLowerCase();
    final cat = DeviceCategory.parse(category);
    for (final (scope, words, token) in _inferenceRules) {
      if (scope != null && scope != cat) continue;
      if (words.any(name.contains)) return token;
    }
    return null;
  }

  /// [pictogram] when the spec declares one, else [infer]'s answer.
  static String? forSpec({
    required String deviceName,
    String? category,
    String? pictogram,
  }) {
    final declared = _normalize(pictogram);
    return declared ?? infer(deviceName: deviceName, category: category);
  }

  /// (category, name words, token), tried in order. Lower-case words matched
  /// as substrings of the lower-cased spec name; the more specific rule
  /// comes first within a category.
  static const List<(DeviceCategory?, List<String>, String)> _inferenceRules = [
    (DeviceCategory.light, ['tv backlight'], 'tv-backlight'),
    (DeviceCategory.light, ['fairy', 'curtain', 'string'], 'string-lights'),
    (DeviceCategory.light, ['hoop', 'prop', 'flow'], 'flow-prop'),
    (DeviceCategory.light, ['key light', 'light bar'], 'light-panel'),
    (DeviceCategory.light, ['grow light'], 'grow-light'),
    (DeviceCategory.light, ['bulb'], 'light'),
    (
      DeviceCategory.light,
      ['strip', 'pixel', 'controller', 'rgb lights', 'lifx z'],
      'led-strip',
    ),
    (DeviceCategory.display, ['badge'], 'name-badge'),
    (DeviceCategory.display, ['glasses'], 'led-glasses'),
    (DeviceCategory.display, ['mask'], 'led-mask'),
    (DeviceCategory.display, ['helmet'], 'led-helmet'),
    (DeviceCategory.display, ['backpack'], 'led-backpack'),
    (DeviceCategory.display, ['sign'], 'led-sign'),
    (DeviceCategory.wearable, ['glasses'], 'led-glasses'),
    (DeviceCategory.wearable, ['watch'], 'smartwatch'),
    (DeviceCategory.wearable, ['band'], 'fitness-band'),
    (DeviceCategory.sensor, ['distance'], 'distance-meter'),
    (
      DeviceCategory.sensor,
      ['meat', 'bbq', 'chef', 'yummly'],
      'meat-thermometer',
    ),
    (DeviceCategory.sensor, ['soil', 'plant'], 'soil-sensor'),
    (DeviceCategory.sensor, ['gas sensor'], 'gas-sensor'),
    (DeviceCategory.sensor, ['tank'], 'tank-sensor'),
    (DeviceCategory.sensor, ['battery monitor'], 'battery-monitor'),
    (DeviceCategory.sensor, ['radon'], 'radon-sensor'),
    (DeviceCategory.sensor, ['co2'], 'co2-sensor'),
    (DeviceCategory.sensor, ['air quality'], 'air-quality'),
    (DeviceCategory.sensor, ['thermo', 'hygro', 'temp'], 'thermometer'),
    (DeviceCategory.health, ['blood pressure'], 'blood-pressure'),
    (DeviceCategory.health, ['oximeter'], 'pulse-oximeter'),
    (DeviceCategory.health, ['glucose'], 'glucose-meter'),
    (DeviceCategory.vehicle, ['scooter'], 'scooter'),
    (DeviceCategory.vehicle, ['unicycle', 'onewheel'], 'board'),
    (DeviceCategory.vehicle, ['motorcycle', 'triumph'], 'motorcycle'),
    (DeviceCategory.vehicle, ['obd'], 'obd-adapter'),
    (DeviceCategory.motor, ['blind'], 'blind-motor'),
    (DeviceCategory.motor, ['drive'], 'ebike-drive'),
    (DeviceCategory.climate, ['air conditioner'], 'air-conditioner'),
    (DeviceCategory.climate, ['thermostat'], 'thermostat'),
    (DeviceCategory.climate, ['purifier'], 'air-purifier'),
    (DeviceCategory.appliance, ['oven'], 'oven'),
    (DeviceCategory.appliance, ['mug'], 'mug'),
    (DeviceCategory.appliance, ['kettle', 'coffee'], 'kettle'),
    (DeviceCategory.appliance, ['instant pot'], 'pressure-cooker'),
    (DeviceCategory.appliance, ['purifier', 'humidifier'], 'air-purifier'),
    (DeviceCategory.personalCare, ['brush'], 'toothbrush'),
    (DeviceCategory.personalCare, ['ipl', 'silk'], 'ipl'),
    (DeviceCategory.fitness, ['rower', 'concept2'], 'rower'),
    (DeviceCategory.fitness, ['band'], 'fitness-band'),
    (DeviceCategory.scale, ['nutrition', 'kitchen'], 'kitchen-scale'),
    (DeviceCategory.energy, ['charging', 'evse', 'juicebox'], 'ev-charger'),
    (DeviceCategory.energy, ['bms', 'battery'], 'battery'),
    (DeviceCategory.printer, ['label'], 'label-printer'),
    (DeviceCategory.printer, ['thermal'], 'thermal-printer'),
    (DeviceCategory.switch_, ['plug'], 'smart-plug'),
    (DeviceCategory.robot, ['vacuum', 'roomba', 'valetudo'], 'robot-vacuum'),
    (DeviceCategory.speaker, ['receiver'], 'av-receiver'),
    (DeviceCategory.tracker, ['key finder'], 'key-finder'),
    (DeviceCategory.other, ['drone'], 'drone'),
    (DeviceCategory.other, ['race', 'cars'], 'toy-car'),
    (DeviceCategory.other, ['wand'], 'wand'),
    (DeviceCategory.other, ['orba'], 'instrument'),
    (DeviceCategory.other, ['mousr'], 'pet-toy'),
    (DeviceCategory.other, [' nas'], 'nas'),
  ];

  /// The spec vocabulary is kebab-case lowercase; tolerate stray case and
  /// whitespace in hand-written specs rather than losing the glyph over them.
  static String? _normalize(String? token) {
    if (token == null) return null;
    final key = token.trim().toLowerCase();
    return key.isEmpty ? null : key;
  }
}
