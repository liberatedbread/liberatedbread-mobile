// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// LocalThings: where this app sends a SmartThings household that also runs
// Home Assistant.
//
// The SmartThings Hub v2 is identify_only in the spec catalogue — every local
// endpoint it serves wants a cloud-issued Samsung bearer token — so the app
// has nothing to offer for the hub itself. The Samsung APPLIANCES on the same
// account are another matter: LocalThings (github.com/mbillow/localthings) is
// a Home Assistant integration that drives Samsung washers, dryers, fridges,
// air conditioners, ovens and more over the LAN (OCF over CoAP/DTLS; HTTPS on
// TCP 8888 for 2018–2022 units) with no Samsung account. Seeing a SmartThings
// advertisement and a Home Assistant on one network is the moment to say so.
//
// The upstream spec (smartthings-hub-v2.yaml) carries the same advice in its
// notes and helpful_urls; this file is the app's half of it.
import '../models/network_device.dart';

/// The integration's Home Assistant domain, as its manifest.json declares it.
/// What `/api/components` lists once it is installed, and what a config-flow
/// link starts.
const String localThingsDomain = 'localthings';

/// The project itself: the README, the supported-appliance table, issues.
final Uri localThingsRepoUrl = Uri.parse(
  'https://github.com/mbillow/localthings',
);

/// One tap to LocalThings in the user's own HACS.
///
/// Through my.home-assistant.io rather than the instance's own
/// `/_my_redirect/`: HACS's redirect target has moved between Home Assistant
/// releases (it now routes via the `marketplace` component), and the hosted
/// redirect service is the one that tracks that. It asks once for the
/// instance address and remembers it.
final Uri localThingsHacsUrl = Uri.https(
  'my.home-assistant.io',
  '/redirect/hacs_repository/',
  {'owner': 'mbillow', 'repository': 'localthings', 'category': 'integration'},
);

/// Start LocalThings' "add an appliance" flow.
///
/// Straight at [haBaseUrl]'s own `/_my_redirect/config_flow_start` when the
/// app knows the instance — no detour through the hosted redirect service,
/// and it works on a network with no internet at all, which is the point of
/// going local. Through my.home-assistant.io when it does not.
Uri localThingsAddApplianceUrl({String? haBaseUrl}) {
  final base = haBaseUrl == null ? null : Uri.tryParse(haBaseUrl.trim());
  if (base != null &&
      (base.scheme == 'http' || base.scheme == 'https') &&
      base.host.isNotEmpty) {
    final path = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$path/_my_redirect/config_flow_start',
      queryParameters: {'domain': localThingsDomain},
    );
  }
  return Uri.https('my.home-assistant.io', '/redirect/config_flow_start/', {
    'domain': localThingsDomain,
  });
}

/// Whether Home Assistant's loaded [components] include LocalThings.
///
/// `/api/components` lists a platform as `localthings.sensor` alongside the
/// bare domain; either one is proof it is loaded.
bool hasLocalThings(Iterable<String> components) => components.any(
  (c) => c == localThingsDomain || c.startsWith('$localThingsDomain.'),
);

/// The two mDNS types a SmartThings hub advertises that name SmartThings.
/// The hub's `_matter._tcp` is shared with every Matter device on the network
/// and says nothing about Samsung.
const Set<String> _smartThingsServiceTypes = {
  '_smartthings._tcp',
  '_smartthings-hedge._tcp',
};

/// The type Home Assistant's zeroconf integration announces the server as.
const String homeAssistantServiceType = '_home-assistant._tcp.local.';

String _bareType(String raw) =>
    stripLocalSuffix(raw.trim().toLowerCase().replaceAll(RegExp(r'\.+$'), ''));

/// Whether [device] advertised itself as SmartThings.
bool isSmartThingsDevice(NetworkDevice device) =>
    device.serviceTypes.map(_bareType).any(_smartThingsServiceTypes.contains);

/// Whether [device] is a Home Assistant server announcing itself.
bool isHomeAssistantServer(NetworkDevice device) => device.serviceTypes
    .map(_bareType)
    .contains(_bareType(homeAssistantServiceType));

/// Where a Home Assistant found by mDNS says it lives.
///
/// Its TXT record carries `internal_url` (the LAN address the owner set) and
/// `base_url` (external if set, else internal) — both empty when the owner
/// configured neither, so the SRV address and port are the fallback. Only
/// http(s) survives: this ends up in a link the OS opens.
String? homeAssistantUrlOf(NetworkDevice device) {
  for (final key in const ['internal_url', 'base_url']) {
    final raw = device.txt[key]?.trim();
    if (raw == null || raw.isEmpty) continue;
    final uri = Uri.tryParse(raw);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    }
  }
  final host = device.host.contains(':') ? '[${device.host}]' : device.host;
  // The row's port is the first service's that resolved for the host, and a
  // Home Assistant box usually advertises others (its HomeKit bridge, SSH,
  // Samba). Only when this is all it advertises is the port known to be HA's.
  final onlyHomeAssistant = device.serviceTypes.length <= 1;
  final port = onlyHomeAssistant ? (device.port ?? 8123) : 8123;
  return 'http://$host:$port';
}
