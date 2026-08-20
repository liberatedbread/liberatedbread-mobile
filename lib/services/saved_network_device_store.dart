// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:shared_preferences/shared_preferences.dart';

import '../models/network_device.dart';
import 'prefs_json_list.dart';

/// A network device the user has opened controls for and wants to keep — the
/// Wi-Fi counterpart of [SavedDevice], and the thing that lets a TV take
/// part in a group while its screen is off.
///
/// The BLE record's one hard question — what survives the scan — is harder
/// here, because a network device's address is a DHCP lease, not an
/// identity. So the record splits in two:
///
///  * [id] is the STABLE identity, chosen once at save time by
///    [stableIdFor]: the advertised MAC when the device published one, else
///    the hostname (which usually embeds a serial), else the advertised
///    name, else — last resort, and honestly weak — the address itself.
///  * [host]/[port]/[ssdpPort]/[ssdpDescriptionPath]/[ssdpTargets] are a
///    CACHE of the last sighting, refreshed every time the device is seen.
///    They are what a group run connects to when the device has not been
///    scanned this session, and a lease change makes them stale, not wrong:
///    the run fails honestly ("could not reach") and the next scan heals
///    them.
class SavedNetworkDevice {
  final String id;
  final String name;
  final DateTime lastSeen;

  /// The matched spec's `device.category` wire string ("tv", "light", …),
  /// recorded when the user opened controls through a spec match. Same
  /// tolerance rule as [SavedDevice.category]: raw string, because a spec
  /// pack newer than this build may say things the enum has not heard of.
  final String? category;

  /// Identity of the matched spec, as `deviceName|manufacturer` — the two
  /// fields network spec matching keys on. What lets a group run re-resolve
  /// the spec (and its entities) for a device that is out of sight.
  final String? specKey;

  /// Last-known address and discovery answers — the cache half. See the
  /// class doc: refreshed on sight, trusted until then.
  final String host;
  final String? hostname;
  final int? port;
  final int? ssdpPort;
  final String? ssdpDescriptionPath;
  final List<String> ssdpTargets;

  const SavedNetworkDevice({
    required this.id,
    required this.name,
    required this.lastSeen,
    required this.host,
    this.hostname,
    this.port,
    this.ssdpPort,
    this.ssdpDescriptionPath,
    this.ssdpTargets = const [],
    this.category,
    this.specKey,
  });

  /// The stable identity for [device] — see the class doc for the ladder.
  static String stableIdFor(NetworkDevice device) {
    final mac = device.advertisedMac;
    if (mac != null) return 'mac:$mac';
    final hostname = device.hostname;
    if (hostname != null && hostname.isNotEmpty) return 'hn:$hostname';
    if (device.name.isNotEmpty) return 'name:${device.name}';
    return 'host:${device.host}';
  }

  /// Rebuild a [NetworkDevice] from the cached sighting, so screens built
  /// for live discoveries (the control screen) can open from a saved row.
  /// The synthesized sighting is as honest as the cache: sources are
  /// derived from what was cached (SSDP fields present means SSDP answered)
  /// and the timestamp is the save's own.
  NetworkDevice toNetworkDevice() => NetworkDevice(
        host: host,
        name: name,
        hostname: hostname,
        port: port,
        ssdpPort: ssdpPort,
        ssdpDescriptionPath: ssdpDescriptionPath,
        ssdpTargets: ssdpTargets,
        sources: {
          if (ssdpPort != null || ssdpTargets.isNotEmpty)
            NetworkDiscoverySource.ssdp
          else
            NetworkDiscoverySource.mdns,
        },
        discoveredAt: lastSeen,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lastSeen': lastSeen.toIso8601String(),
        'host': host,
        if (hostname != null) 'hostname': hostname,
        if (port != null) 'port': port,
        if (ssdpPort != null) 'ssdpPort': ssdpPort,
        if (ssdpDescriptionPath != null)
          'ssdpDescriptionPath': ssdpDescriptionPath,
        if (ssdpTargets.isNotEmpty) 'ssdpTargets': ssdpTargets,
        if (category != null) 'category': category,
        if (specKey != null) 'specKey': specKey,
      };

  /// Returns null for records that can't be read, so one corrupt entry can't
  /// take the whole list down with it — the same tolerance every store in
  /// this app applies.
  static SavedNetworkDevice? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final host = json['host'];
    final lastSeen = json['lastSeen'];
    if (id is! String || id.isEmpty || name is! String) return null;
    if (host is! String || host.isEmpty) return null;
    final parsed = lastSeen is String ? DateTime.tryParse(lastSeen) : null;
    final category = json['category'];
    final specKey = json['specKey'];
    final hostname = json['hostname'];
    final port = json['port'];
    final ssdpPort = json['ssdpPort'];
    final descriptionPath = json['ssdpDescriptionPath'];
    final targets = json['ssdpTargets'];
    return SavedNetworkDevice(
      id: id,
      name: name,
      lastSeen: parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
      host: host,
      hostname: hostname is String && hostname.isNotEmpty ? hostname : null,
      port: port is int ? port : null,
      ssdpPort: ssdpPort is int ? ssdpPort : null,
      ssdpDescriptionPath:
          descriptionPath is String && descriptionPath.isNotEmpty
              ? descriptionPath
              : null,
      ssdpTargets: targets is List
          ? [
              for (final entry in targets)
                if (entry is String && entry.isNotEmpty) entry,
            ]
          : const [],
      category: category is String && category.isNotEmpty ? category : null,
      specKey: specKey is String && specKey.isNotEmpty ? specKey : null,
    );
  }

  /// Identity equality, like every saved record: two snapshots of the same
  /// device are the same device.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SavedNetworkDevice && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Persists saved network devices across launches. Same shape and same
/// reasoning as [SavedDeviceStore]: a JSON array under one key, defensively
/// decoded, ordered by recency.
class SavedNetworkDeviceStore {
  static const _key = 'saved_network_devices_v1';

  final SharedPreferences _prefs;

  SavedNetworkDeviceStore(this._prefs);

  /// Saved devices, most recently seen first.
  List<SavedNetworkDevice> load() =>
      loadPrefsJsonList(_prefs, _key, SavedNetworkDevice.fromJson)
        ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  /// Insert or update [device] (matched by id), keeping the list
  /// newest-first.
  Future<List<SavedNetworkDevice>> save(SavedNetworkDevice device) async {
    final devices = load().where((d) => d.id != device.id).toList()
      ..insert(0, device);
    await _write(devices);
    return devices;
  }

  Future<List<SavedNetworkDevice>> remove(String id) async {
    final devices = load().where((d) => d.id != id).toList();
    await _write(devices);
    return devices;
  }

  Future<void> _write(List<SavedNetworkDevice> devices) =>
      savePrefsJsonList(_prefs, _key, devices, (d) => d.toJson());
}
