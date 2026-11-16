// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Numbers as people type them.
import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;

/// [typed], trimmed, with a single decimal comma read as the decimal point
/// when [locale] writes its decimals with one. The default is the device's
/// locale, not the app's resolved one: the keyboard follows the device, and
/// an app shown in English on a German phone still gets a comma key.
///
/// For numbers a person typed, not for data: an iOS decimal pad in the
/// de, fr, es, it, pt and nl locales has a comma key and no period, so there
/// "146,940" is the only way to type a frequency and "41,7658" a latitude,
/// and parsers that take only a period refused both. In a locale whose
/// decimal separator is a period the same comma is a thousands separator,
/// and "1,500" is fifteen hundred, not one and a half: it is left as typed,
/// for the parser to refuse rather than to read as a number a thousand times
/// smaller. Nothing else is guessed at either: a comma beside a period or
/// more than one comma is left as typed.
///
/// Directory data does not come through here. A feed's "146,940" is not a
/// keyboard's, and `parseMegahertzToHz` reads such feeds directly.
String normalizeDecimalInput(String typed, {Locale? locale}) {
  final text = typed.trim();
  final comma = text.indexOf(',');
  if (comma < 0 || text.contains('.') || text.lastIndexOf(',') != comma) {
    return text;
  }
  final effective = locale ?? WidgetsBinding.instance.platformDispatcher.locale;
  if (!localeUsesDecimalComma(effective)) {
    return text;
  }
  return text.replaceRange(comma, comma + 1, '.');
}

/// Whether [locale] writes a decimal comma, per the CLDR number symbols of
/// the languages and regions this app's users are likely to be in. A
/// language not listed is read as a decimal period, the safer guess: a
/// comma left as typed is refused, where a comma misread changes the number.
bool localeUsesDecimalComma(Locale locale) {
  final language = locale.languageCode.toLowerCase();
  final region = locale.countryCode?.toUpperCase();
  final exceptions = _decimalPeriodRegions[language];
  if (exceptions != null && region != null && exceptions.contains(region)) {
    return false;
  }
  if (language == 'en') return _decimalCommaEnglishRegions.contains(region);
  return _decimalCommaLanguages.contains(language);
}

const _decimalCommaLanguages = {
  'af', 'az', 'be', 'bg', 'bs', 'ca', 'cs', 'da', 'de', 'el', 'es', 'et', //
  'eu', 'fi', 'fo', 'fr', 'gl', 'hr', 'hu', 'hy', 'id', 'is', 'it', 'ka', //
  'kk', 'ky', 'lt', 'lv', 'mk', 'mn', 'nb', 'nl', 'nn', 'no', 'pl', 'pt', //
  'ro', 'ru', 'sk', 'sl', 'sq', 'sr', 'sv', 'tr', 'uk', 'uz', 'vi',
};

/// Regions where a decimal-comma language writes a period.
const _decimalPeriodRegions = {
  'de': {'CH', 'LI'},
  'it': {'CH'},
  'es': {'MX', 'US', 'PR', 'DO', 'GT', 'HN', 'NI', 'PA', 'SV', 'PE', '419'},
};

/// English is a decimal-period language except where these regions write
/// it with a comma.
const _decimalCommaEnglishRegions = {
  'ZA',
  'DE',
  'AT',
  'BE',
  'DK',
  'FI',
  'NL',
  'SE',
  'SI',
};
