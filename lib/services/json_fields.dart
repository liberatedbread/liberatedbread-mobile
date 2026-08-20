// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

/// Flatten a JSON reply into the dotted name→value pairs the generic entity
/// decoder (`readNetworkEntity`) reads — the JSON counterpart of the SOAP
/// client's XML parse, for transports whose reply is a JSON document.
///
/// The decoder looks a spec's `state_mapping.value` up VERBATIM in the
/// returned map, so the keys here are paths from the reply root joined with
/// dots: `{"emeter":{"get_realtime":{"voltage":120.4}}}` flattens to
/// `emeter.get_realtime.voltage` → `'120.4'`, and the Envoy's flat reply key
/// `wattsNow` stays `wattsNow`. Maps recurse; strings, numbers and booleans
/// stringify. Arrays and nulls are dropped — a dotted path cannot name an
/// array entry, which is the same reason a spec whose values live in an
/// array (the Envoy's `/production.json`) declares no entities for them.
///
/// An unparseable or non-object reply yields an empty map, which reads as
/// "no state here" — the same answer the SOAP path gives a reply that did
/// not carry the entity's field, never a fabricated zero.
Map<String, String> jsonStateFields(String replyJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(replyJson);
  } on FormatException {
    return const {};
  }
  if (decoded is! Map) return const {};

  final out = <String, String>{};
  void walk(String prefix, Map<dynamic, dynamic> map) {
    map.forEach((key, value) {
      final path = prefix.isEmpty ? '$key' : '$prefix.$key';
      if (value is Map) {
        walk(path, value);
      } else if (value is String || value is num || value is bool) {
        out[path] = value.toString();
      }
    });
  }

  walk('', decoded);
  return out;
}
