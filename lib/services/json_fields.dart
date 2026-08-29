// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:xml/xml.dart';

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
  // Depth-capped: the document is device-supplied, and recursion the sender
  // sizes is a stack overflow that takes the whole poll down. Thirty-two
  // levels is several times the deepest state document any spec names;
  // anything deeper is dropped, not fabricated.
  void walk(String prefix, Map<dynamic, dynamic> map, int depth) {
    if (depth > 32) return;
    map.forEach((key, value) {
      final path = prefix.isEmpty ? '$key' : '$prefix.$key';
      if (value is Map) {
        walk(path, value, depth + 1);
      } else if (value is String || value is num || value is bool) {
        out[path] = value.toString();
      }
    });
  }

  walk('', decoded, 0);
  return out;
}

/// Flatten an XML reply into the same dotted name→value pairs
/// [jsonStateFields] produces, so one `state_mapping` convention covers both
/// encodings.
///
/// Paths are element local names joined with dots, counted from the ROOT's
/// children rather than including the root itself — the same place the SOAP
/// parser starts, one envelope in. A Denon receiver serves
/// `<item><Power><value>ON</value></Power>…</item>` and its spec names the
/// reading `Power.value`, which is that convention exactly.
///
/// Local names throughout, for the reason the description parser gives: some
/// firmware serves these documents without their namespace, and matching on
/// the prefixed name would lose those devices. Repeated siblings collapse to
/// the first — a dotted path cannot name the second `<item>` any more than it
/// can name an array entry, which is the same limit the JSON side documents.
/// An unparseable reply yields an empty map: no state here, never a
/// fabricated value.
Map<String, String> xmlStateFields(String replyXml) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(replyXml);
  } on XmlException {
    return const {};
  }

  // rootElement throws StateError — not XmlException — on a document that
  // parsed but has no root (only comments or processing instructions), which
  // escaped the catch above and erred the poll instead of reading as "no
  // state here".
  final XmlElement root;
  try {
    root = document.rootElement;
  } on StateError {
    return const {};
  }

  final out = <String, String>{};
  // Same device-sized-recursion cap as the JSON walk.
  void walk(String prefix, XmlElement element, int depth) {
    if (depth > 32) return;
    for (final child in element.childElements) {
      final path =
          prefix.isEmpty ? child.localName : '$prefix.${child.localName}';
      if (child.childElements.isEmpty) {
        // A leaf: its text is the value. First sibling wins.
        out.putIfAbsent(path, () => child.innerText.trim());
      } else {
        walk(path, child, depth + 1);
      }
    }
  }

  walk('', root, 0);
  return out;
}

/// Flatten an HTTP state reply whatever encoding it arrived in.
///
/// A `state_topic` names a resource, not a command, and the schema says
/// nothing about what that resource serves — the Snapmaker answers JSON at
/// `/printer/objects/query?heater_bed` and the Denon answers XML at
/// `/goform/formMainZone_MainZoneXmlStatusLite.xml`. Both spell their
/// `state_mapping` paths the same way, so the reader dispatches on the reply
/// it actually got, exactly as the Kasa reader dispatches per reply shape one
/// transport over. Neither shape yields an empty map on a body the other
/// would have parsed.
Map<String, String> httpStateFields(String body) {
  final trimmed = body.trimLeft();
  if (trimmed.startsWith('<')) return xmlStateFields(body);
  return jsonStateFields(body);
}
