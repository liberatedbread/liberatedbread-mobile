// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What kind of thing is this, and which icon says so?

import 'package:flutter/material.dart';

/// Broad device classes, mirroring the `device.category` vocabulary in the
/// protocol-specs schema.
///
/// The vocabulary is owned upstream, in `device-specs/schema.json`, and this
/// enum is a *view* of it rather than a second definition: [parse] maps the
/// spec's string onto a member and answers `null` for anything it does not
/// recognise. That asymmetry is deliberate. A spec pack refreshed at runtime
/// can carry a category added upstream after this build shipped, and the app
/// must keep working with such a device — it just draws the generic icon for
/// it until the app catches up. Rejecting the spec, or throwing on an
/// unfamiliar value, would lose the whole device over its icon.
enum DeviceCategory {
  appliance(Icons.blender_outlined, 'Appliance'),
  camera(Icons.videocam_outlined, 'Camera'),
  climate(Icons.air_outlined, 'Climate'),
  display(Icons.grid_on_outlined, 'Display'),
  energy(Icons.solar_power_outlined, 'Energy'),
  fitness(Icons.fitness_center_outlined, 'Fitness'),
  health(Icons.favorite_outline, 'Health'),
  hub(Icons.hub_outlined, 'Hub'),
  irrigation(Icons.water_drop_outlined, 'Irrigation'),
  light(Icons.lightbulb_outline, 'Light'),
  lock(Icons.lock_outline, 'Lock'),
  motor(Icons.settings_outlined, 'Motor'),

  /// Routers, switches, access points and the NVR/NAS appliances that ship
  /// alongside them. These are identify-only in the catalogue — a UniFi or
  /// MikroTik device answers a discovery probe with its model and name, and
  /// that is the whole surface; nothing here is controllable.
  network(Icons.router_outlined, 'Network'),
  printer(Icons.print_outlined, 'Printer'),

  /// A published-protocol reference (SAE J1979, ISO 14229, ISO 15765-2), not a
  /// device. Nothing advertises one, so this never reaches a scan result — the
  /// value exists so that a reference spec arriving in the UI by some other
  /// route is labelled honestly rather than mistaken for hardware.
  reference(Icons.menu_book_outlined, 'Protocol reference'),
  robot(Icons.smart_toy_outlined, 'Robot'),
  scale(Icons.monitor_weight_outlined, 'Scale'),
  sensor(Icons.sensors_outlined, 'Sensor'),
  speaker(Icons.speaker_outlined, 'Speaker'),
  switch_(Icons.toggle_on_outlined, 'Switch'),
  tool(Icons.handyman_outlined, 'Tool'),
  tracker(Icons.my_location_outlined, 'Tracker'),

  /// Walking pads and under-desk treadmills (KingSmith's WalkingPad family is
  /// the vendored example): motorised exercise equipment, which is why the
  /// specs carry `advanced` command flags this app turns into confirmation
  /// dialogs. The walking figure rather than the running one — these devices
  /// top out at walking speeds.
  treadmill(Icons.directions_walk_outlined, 'Treadmill'),
  tv(Icons.tv_outlined, 'TV'),
  vehicle(Icons.directions_car_outlined, 'Vehicle'),
  wearable(Icons.checkroom_outlined, 'Wearable'),
  other(Icons.devices_other_outlined, 'Device');

  /// The icon drawn for a device of this class.
  final IconData icon;

  /// Short human label, e.g. "Light · Acme Corp" on the device screen.
  final String label;

  const DeviceCategory(this.icon, this.label);

  /// The spec's spelling of this category — the wire value, which for
  /// [DeviceCategory.switch_] is `switch` (Dart reserves the bare word).
  String get wireName => this == DeviceCategory.switch_ ? 'switch' : name;

  /// [label] pluralized: "Lights" reads right where "Light" would not, in
  /// section titles for the automatic by-kind groups. Categories whose label
  /// is a mass noun keep it.
  String get pluralLabel => switch (this) {
        DeviceCategory.switch_ => 'Switches',
        DeviceCategory.climate ||
        DeviceCategory.energy ||
        DeviceCategory.fitness ||
        DeviceCategory.health ||
        DeviceCategory.irrigation =>
          label,
        _ => '${label}s',
      };

  /// Resolve a `device.category` string, or null when it is absent, empty, or
  /// a value this build does not know.
  static DeviceCategory? parse(String? raw) {
    if (raw == null) return null;
    final key = raw.trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final category in DeviceCategory.values) {
      if (category.wireName == key) return category;
    }
    return null;
  }
}

/// The icon for a device the catalogue could not place.
///
/// Deliberately the Bluetooth glyph rather than a "?" or a blank: it says the
/// true thing — something is advertising on BLE — instead of implying the
/// device is broken. It is also what makes every *other* icon mean something,
/// since a non-default icon can then only come from a matched spec.
const IconData unknownDeviceIcon = Icons.bluetooth;
