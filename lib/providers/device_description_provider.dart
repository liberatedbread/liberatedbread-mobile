// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/iot_device.dart';
import '../services/number_registry.dart';

/// The vendored number registries, indexed once for the life of the app.
final numberRegistryProvider = FutureProvider<NumberRegistry>(
  (ref) => NumberRegistry.load(rootBundle.loadString),
);

/// What can be said about a device that no spec matched.
///
/// Deliberately separate from a spec match: this never claims support, only
/// describes what the device put on air. A spec match says "this is an Ember
/// Mug and here is how to talk to it"; a description says "somebody at
/// Espressif made this, and it offers a battery service".
@immutable
class DeviceDescription {
  /// Who registered the device's address block, when the address is available
  /// and falls in a known one. Frequently the chip vendor rather than the
  /// product vendor — see [NumberRegistry.vendorForMac].
  final String? addressVendor;

  /// Companies behind the advertised manufacturer-data records, in advertised
  /// order. Empty when the device advertises none, or none are known.
  final List<String> companies;

  /// Human names for advertised standard services, e.g. "Battery Service".
  /// Vendor 128-bit UUIDs are not here — those mean something product-specific
  /// and are the spec matcher's business.
  final List<String> standardServices;

  /// Advertised service UUIDs that are NOT SIG-standard, i.e. a vendor's own.
  /// Counted rather than listed: the count is the useful part ("it offers two
  /// proprietary services"), and a raw 128-bit UUID is noise in a list.
  final int vendorServiceCount;

  const DeviceDescription({
    this.addressVendor,
    this.companies = const [],
    this.standardServices = const [],
    this.vendorServiceCount = 0,
  });

  static const DeviceDescription none = DeviceDescription();

  bool get isEmpty =>
      addressVendor == null &&
      companies.isEmpty &&
      standardServices.isEmpty &&
      vendorServiceCount == 0;

  /// The most specific maker we can name, preferring the advertised company ID
  /// over the address block.
  ///
  /// A company ID is chosen by whoever wrote the firmware; an address block is
  /// bought by whoever assembled the radio. When they disagree the firmware is
  /// the better answer to "whose device is this?" — a Texas Instruments block
  /// under an Ember company ID is an Ember mug, not a TI product.
  String? get maker => companies.isNotEmpty ? companies.first : addressVendor;

  /// The services half of [summary] on its own: named standard services, else
  /// a count of proprietary ones, else null. Exists so a caller that already
  /// shows [maker] elsewhere (the title) can use this directly instead of
  /// un-joining the summary string.
  String? get servicesLine {
    if (standardServices.isNotEmpty) return standardServices.take(2).join(', ');
    if (vendorServiceCount > 0) {
      return vendorServiceCount == 1
          ? '1 custom service'
          : '$vendorServiceCount custom services';
    }
    return null;
  }

  /// One line for a device row, or null when there is genuinely nothing to say.
  ///
  /// Reads as observation rather than identification throughout — every phrase
  /// here is something the device broadcast, not a conclusion about what it is.
  String? get summary {
    final parts = [
      if (maker != null) maker!,
      if (servicesLine != null) servicesLine!
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// Describe a scanned device from the registries alone.
///
/// Pure so the wording can be tested without an asset bundle.
DeviceDescription describeDevice(IoTDevice device, NumberRegistry registry) {
  final companies = <String>[];
  for (final id in device.companyIds) {
    final name = registry.companyName(id);
    if (name != null && !companies.contains(name)) companies.add(name);
  }

  final standardServices = <String>[];
  var vendorServiceCount = 0;
  for (final uuid in device.serviceUuids) {
    final name = registry.serviceName(uuid);
    if (name == null) {
      vendorServiceCount++;
    } else if (!standardServices.contains(name)) {
      standardServices.add(name);
    }
  }

  return DeviceDescription(
    addressVendor: registry.vendorForMac(device.macAddress),
    companies: companies,
    standardServices: standardServices,
    vendorServiceCount: vendorServiceCount,
  );
}

/// What to call a device in a list.
///
/// An advertised name always wins — it is what the owner will recognise. Only
/// when there is none does the registry get a say, and then it names the maker
/// rather than inventing a product: "Espressif Inc." tells someone far more
/// than "Unknown (A4:CF:12:…)", without pretending to know what the thing is.
String deviceTitle(IoTDevice device, DeviceDescription description) {
  if (device.name.isNotEmpty) return device.name;
  return description.maker ?? 'Unknown device';
}

/// The supporting line under a device with no matched spec.
///
/// Carries the address whenever the title came from the registry, because two
/// devices from the same maker would otherwise be indistinguishable in the
/// list. Returns null when there is genuinely nothing to add.
String? deviceSubtitle(IoTDevice device, DeviceDescription description) {
  if (device.name.isEmpty) {
    // The maker (if any) is already the title; don't repeat it.
    final services = description.servicesLine;
    return [device.id, if (services != null) services].join(' · ');
  }
  return description.summary;
}

/// What the registries make of one scanned device.
///
/// Keyed on [ScanIdentity]-equivalent data via the device itself; the registry
/// lookup is cheap enough (a few binary searches) that it runs inline on build
/// rather than through a family provider.
DeviceDescription describeWith(
  AsyncValue<NumberRegistry> registry,
  IoTDevice device,
) {
  final loaded = registry.valueOrNull;
  return loaded == null
      ? DeviceDescription.none
      : describeDevice(device, loaded);
}
