// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// Display forms of the company names the IEEE and Bluetooth SIG registries
/// hold, and which of those companies make radios rather than products.
///
/// The registries record whoever filed the paperwork, in whatever form they
/// filed it: "Hon Hai Precision Ind. Co.,Ltd.", "SHENZHEN BILIAN ELECTRONIC
/// CO.，LTD", "Espressif Systems (Shanghai) Co., Ltd.". Printed raw, a scan
/// row's one line of identity was half legal boilerplate, and the name the
/// user would recognise was the part that got ellipsized. And the company is
/// often not the one whose logo is on the box: an address block is bought by
/// whoever made the radio module, and a company ID is frequently the chip
/// vendor's default left in the firmware. So a chip vendor is said as the
/// radio's maker, never as the device's.
library;

/// Trailing legal-form tokens, peeled off one at a time from the end so
/// "Co., Ltd." and "Industrial., Ltd" both go. Matched case-insensitively.
final _legalSuffix = RegExp(
  r'[\s,.]+(co\.?,?\s*ltd|co|corp|corporation|company|inc|incorporated|llc|'
  r'l\.l\.c|ltd|limited|gmbh|ag|ab|asa|a/s|as|bv|b\.v|nv|n\.v|sa|s\.a|sas|'
  r's\.a\.s|srl|s\.r\.l|spa|s\.p\.a|oy|kk|kg|plc|pty|pte|pvt|sdn\s*bhd|ug|'
  r'&\s*co(\.?\s*kg)?)\.?$',
  caseSensitive: false,
);

/// A parenthesised aside — a subsidiary's city, an abbreviation.
final _parenthetical = RegExp(r'\s*\([^)]*\)');

/// [raw] as a person would write the company's name: legal form and
/// parenthesised asides dropped, an all-capitals filing put in title case.
///
/// A radio maker comes back under the one short name it is known by (see
/// [_radioVendors]), whichever subsidiary filed the entry.
String displayVendorName(String raw) {
  final radio = _radioVendorOf(raw);
  if (radio != null) return radio;
  var name = raw
      .replaceAll('，', ',')
      .replaceAll(_parenthetical, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Stripping one suffix can expose another ("Co., Ltd." is two).
  for (var previous = ''; previous != name;) {
    previous = name;
    name = name.replaceFirst(_legalSuffix, '');
  }
  name = name.replaceFirst(RegExp(r'[\s,&.]+$'), '');
  // "F5 Inc.", "MG Co., Ltd.": a name this short is an abbreviation that
  // reads as a fragment once its legal form is gone, so it keeps it.
  if (name.length <= 2) name = raw.replaceAll('，', ',').trim();
  return _isShouting(name) ? _titleCase(name) : name;
}

/// A name filed in capitals: letters, and none of them lower case.
bool _isShouting(String name) =>
    RegExp('[A-Z]').hasMatch(name) && !RegExp('[a-z]').hasMatch(name);

/// Title-case each word, leaving short ones as the acronyms they usually are
/// ("NXP", "LG", the "TP" of "TP-LINK").
String _titleCase(String name) => name.replaceAllMapped(RegExp('[A-Z][A-Z]+'), (
  m,
) {
  final word = m[0]!;
  return word.length <= 3 ? word : word[0] + word.substring(1).toLowerCase();
});

/// Companies whose name in a registry says who made the radio, not the
/// device, keyed by a lower-case stem of their filings and mapped to the name
/// they are known by.
///
/// Matched as substrings, so every subsidiary's filing ("Espressif Systems
/// (Shanghai)", "Telink Micro LLC") lands on one name. The ones that turn up
/// under consumer devices: SoC vendors, and the module houses that put those
/// SoCs on a board.
const _radioVendors = {
  'espressif': 'Espressif',
  'texas instruments': 'Texas Instruments',
  'nordic semiconductor': 'Nordic',
  'telink': 'Telink',
  'silicon laboratories': 'Silicon Labs',
  'silicon labs': 'Silicon Labs',
  'realtek': 'Realtek',
  'beken': 'Beken',
  'bouffalo': 'Bouffalo Lab',
  'tuya': 'Tuya',
  'azurewave': 'AzureWave',
  'hon hai': 'Foxconn',
  'murata manufacturing': 'Murata',
  'quectel': 'Quectel',
  'infineon': 'Infineon',
  'cypress semiconductor': 'Cypress',
  'dialog semiconductor': 'Dialog',
  'microchip technolog': 'Microchip',
  'stmicroelectronics': 'STMicroelectronics',
  'stmicrolectronics': 'STMicroelectronics', // sic: one of ST's IEEE filings
  'nxp semiconductor': 'NXP',
  'qualcomm': 'Qualcomm',
  'broadcom': 'Broadcom',
  'gaoshengda': 'Gaoshengda',
  'shenzhen bilian': 'Bilian',
  'universal global scientific': 'USI',
  'amlogic': 'Amlogic',
  'mediatek': 'MediaTek',
  'ai-thinker': 'Ai-Thinker',
  'winner microelectronics': 'WinnerMicro',
  'high-flying': 'Hi-Flying',
  'lite-on': 'Lite-On',
  'liteon': 'Lite-On',
  'u-blox': 'u-blox',
  'fn-link': 'Fn-Link',
  'ampak': 'AMPAK',
};

String? _radioVendorOf(String name) {
  final lower = name.toLowerCase();
  for (final MapEntry(:key, :value) in _radioVendors.entries) {
    if (lower.contains(key)) return value;
  }
  return null;
}

/// Whether [name] (raw or display form) is a chip or radio-module maker.
bool isRadioVendor(String name) =>
    _radioVendorOf(name) != null || _radioVendors.containsValue(name);

/// How to say [name] next to a device: as its maker, or as its radio's.
///
/// [name] should already be in display form (see [displayVendorName]).
String vendorPhrase(String name) => isRadioVendor(name) ? '$name radio' : name;
