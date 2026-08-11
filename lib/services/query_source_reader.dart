// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:xml/xml.dart';

import 'spec_codec.dart' show QuerySourceDto;

/// One entry read out of a device's XML query response: the raw value a
/// control sends, and the label a user reads.
///
/// [value] is null for an entry whose attribute is absent — the documented
/// Roku home-screen case, where `<app>Roku</app>` carries no id. It is a real
/// answer ("none of the options is current"), not a parse failure, so it
/// survives to the caller rather than being dropped here.
class QueryEntry {
  final String? value;
  final String label;

  const QueryEntry({required this.value, required this.label});

  @override
  bool operator ==(Object other) =>
      other is QueryEntry && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);

  @override
  String toString() => 'QueryEntry($value, $label)';
}

/// Read the entries a [QuerySourceDto] describes out of an XML document.
///
/// The whole contract, from the schema: every element whose LOCAL name equals
/// `item` — anywhere in the document, at any depth — is one entry; the
/// attribute named `valueAttribute` carries its raw value; the element's
/// trimmed text is its label. Local names throughout, because a device that
/// namespaces its response is answering the same question.
///
/// Unparseable XML yields no entries rather than throwing: this reads a list
/// to show, and a device that answers with something unexpected should cost
/// the user the list, not the screen.
List<QueryEntry> readQuerySource(String xml, QuerySourceDto source) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlException {
    return const [];
  }
  return [
    for (final element in document.descendantElements)
      if (element.localName == source.item)
        QueryEntry(
          value: element.getAttribute(source.valueAttribute),
          // Trimmed because the published documents indent their elements,
          // and a label of "\n  Netflix\n  " is not what the device meant.
          label: element.innerText.trim(),
        ),
  ];
}

/// The value of the first entry in [xml], or null when there is none — the
/// shape a `state_source` is read in.
///
/// Null covers both "the document named no entry" and "the entry carried no
/// value attribute", because a caller comparing against option values does
/// the same thing with either: shows nothing as current.
String? readCurrentValue(String xml, QuerySourceDto source) {
  final entries = readQuerySource(xml, source);
  return entries.isEmpty ? null : entries.first.value;
}
