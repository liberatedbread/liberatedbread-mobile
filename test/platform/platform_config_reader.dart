// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Shared readers for the platform-configuration audit tests in this directory.
//
// Those tests treat `android/`, `ios/` and `macos/` config files as DATA and
// assert that the capabilities the Dart code depends on are actually granted by
// the platform. That class of defect is invisible to every other test in this
// repo — the suite only exercises Dart logic, so an app whose iOS Bluetooth
// permission strategy is compiled out, or whose sandboxed macOS build cannot
// touch the keychain, still shows 100% green.
//
// Everything here is hand-rolled on purpose: adding an XML/plist package
// dependency to ship four config assertions is a bad trade, and the files
// involved are small, stable, machine-generated XML. The parsers below raise on
// anything they do not understand rather than skipping it, so a parse gap
// surfaces as a red test instead of a silent pass.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Repo file access
// ---------------------------------------------------------------------------

/// The package root: the nearest ancestor directory containing `pubspec.yaml`.
///
/// `flutter test` runs with the package root as its working directory — the
/// same assumption `test/core/constants_test.dart` makes when it reads
/// `pubspec.yaml` relatively — but walking up as well keeps these tests
/// resolving their inputs under runners that start elsewhere.
final Directory repoRoot = _findRepoRoot();

Directory _findRepoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        'Could not locate the package root (no pubspec.yaml in any ancestor '
        'of ${Directory.current.absolute.path}). The platform-configuration '
        'tests read repo files directly and cannot run without it.',
      );
    }
    dir = parent;
  }
}

/// A repo file addressed by its path relative to the package root.
File repoFile(String relativePath) =>
    File('${repoRoot.path}/$relativePath').absolute;

/// Read a repo file, failing the test with [consequence] when it is absent.
///
/// [consequence] must describe what breaks in the shipped app, not merely that
/// a file is missing — a missing platform config file is itself one of the bugs
/// this suite exists to catch.
String readRepoFile(String relativePath, {required String consequence}) {
  final file = repoFile(relativePath);
  if (!file.existsSync()) {
    fail('$relativePath is missing from the repo. $consequence');
  }
  return file.readAsStringSync();
}

// ---------------------------------------------------------------------------
// Minimal XML helpers
// ---------------------------------------------------------------------------

/// Remove `<!-- ... -->` comments from [xml].
///
/// The config files here never carry `<!--` inside an attribute or text value,
/// so a straight scan is sound and keeps commented-out config (a real way to
/// "remove" a permission) from reading as if it were still declared.
String stripXmlComments(String xml) {
  final out = StringBuffer();
  var i = 0;
  while (i < xml.length) {
    final start = xml.indexOf('<!--', i);
    if (start < 0) {
      out.write(xml.substring(i));
      break;
    }
    out.write(xml.substring(i, start));
    final end = xml.indexOf('-->', start + 4);
    if (end < 0) break; // Unterminated comment: drop the remainder.
    i = end + 3;
  }
  return out.toString();
}

final RegExp _attributePattern = RegExp(r'([\w:.\-]+)\s*=\s*"([^"]*)"');

/// Every element in [xml] named [tagName], as its attribute name/value map.
///
/// Attribute order and line wrapping are irrelevant to the result, which is
/// what makes this safe to assert against a hand-edited AndroidManifest. Only
/// the opening tag is read; these tests never need element children.
List<Map<String, String>> xmlElementAttributes(String xml, String tagName) {
  final stripped = stripXmlComments(xml);
  final pattern = RegExp('<$tagName(\\s[^>]*?)?/?>', dotAll: true);
  return [
    for (final match in pattern.allMatches(stripped))
      {
        for (final attr in _attributePattern.allMatches(match.group(1) ?? ''))
          attr.group(1)!: _unescapeXml(attr.group(2)!),
      },
  ];
}

String _unescapeXml(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

// ---------------------------------------------------------------------------
// Minimal property-list reader
// ---------------------------------------------------------------------------

/// Parse the property-list subset used by Flutter's `Info.plist` and
/// `.entitlements` files into plain Dart values.
///
/// `<dict>` becomes `Map<String, Object?>`, `<array>` becomes `List<Object?>`,
/// `<string>` a [String], `<true/>`/`<false/>` a [bool], `<integer>`/`<real>` a
/// number. Anything else raises, so an unrecognised element cannot be mistaken
/// for an absent key.
Map<String, Object?> parsePlist(String xml, {required String label}) {
  final stripped = stripXmlComments(xml);
  final root = RegExp(r'<plist\b[^>]*>').firstMatch(stripped);
  if (root == null) {
    throw FormatException('$label: no <plist> root element');
  }
  final value = _PlistScanner(stripped, root.end, label).parseValue();
  if (value is! Map<String, Object?>) {
    throw FormatException('$label: the <plist> root is not a <dict>');
  }
  return value;
}

/// Read a nested value out of a parsed plist by walking [keyPath].
///
/// Returns null when any step is missing or is not a dict, so callers can
/// distinguish "absent" from a legitimately false/empty value.
Object? plistValue(Map<String, Object?> plist, List<String> keyPath) {
  Object? current = plist;
  for (final key in keyPath) {
    if (current is! Map<String, Object?> || !current.containsKey(key)) {
      return null;
    }
    current = current[key];
  }
  return current;
}

/// Whether [keyPath] exists in [plist] at all, regardless of its value.
bool plistHasKey(Map<String, Object?> plist, List<String> keyPath) {
  Object? current = plist;
  for (final key in keyPath) {
    if (current is! Map<String, Object?> || !current.containsKey(key)) {
      return false;
    }
    current = current[key];
  }
  return true;
}

class _PlistScanner {
  _PlistScanner(this._xml, this._pos, this._label);

  final String _xml;
  final String _label;
  int _pos;

  Object? parseValue() {
    final raw = _readTag();
    final name = _tagName(raw);
    final selfClosing = raw.endsWith('/');
    switch (name) {
      case 'dict':
        return selfClosing ? <String, Object?>{} : _parseDictBody();
      case 'array':
        return selfClosing ? <Object?>[] : _parseArrayBody();
      case 'string':
        return selfClosing ? '' : _readTextUntilClose('string');
      case 'true':
        return true;
      case 'false':
        return false;
      case 'integer':
        return int.parse(_readTextUntilClose('integer').trim());
      case 'real':
        return double.parse(_readTextUntilClose('real').trim());
      case 'data':
      case 'date':
        return _readTextUntilClose(name).trim();
      default:
        throw FormatException(
          '$_label: unsupported property-list element <$name>',
          _xml,
          _pos,
        );
    }
  }

  Map<String, Object?> _parseDictBody() {
    final result = <String, Object?>{};
    while (true) {
      final at = _pos;
      final raw = _readTag();
      if (raw.startsWith('/')) {
        if (_tagName(raw) != 'dict') {
          throw FormatException('$_label: expected </dict>', _xml, at);
        }
        return result;
      }
      if (_tagName(raw) != 'key') {
        throw FormatException('$_label: expected <key> in <dict>', _xml, at);
      }
      final key = raw.endsWith('/') ? '' : _readTextUntilClose('key');
      result[key] = parseValue();
    }
  }

  List<Object?> _parseArrayBody() {
    final result = <Object?>[];
    while (true) {
      _skipWhitespace();
      if (_xml.startsWith('</array>', _pos)) {
        _pos += '</array>'.length;
        return result;
      }
      result.add(parseValue());
    }
  }

  void _skipWhitespace() {
    while (_pos < _xml.length && _xml[_pos].trim().isEmpty) {
      _pos++;
    }
  }

  /// Read the next `<...>` tag and return its raw interior, e.g. `/dict`,
  /// `true/`, or `plist version="1.0"`.
  String _readTag() {
    _skipWhitespace();
    if (_pos >= _xml.length || _xml[_pos] != '<') {
      throw FormatException('$_label: expected an element', _xml, _pos);
    }
    final end = _xml.indexOf('>', _pos);
    if (end < 0) {
      throw FormatException('$_label: unterminated element', _xml, _pos);
    }
    final raw = _xml.substring(_pos + 1, end);
    _pos = end + 1;
    return raw;
  }

  String _tagName(String raw) {
    var name = raw;
    if (name.startsWith('/')) name = name.substring(1);
    if (name.endsWith('/')) name = name.substring(0, name.length - 1);
    final space = name.indexOf(RegExp(r'\s'));
    return (space < 0 ? name : name.substring(0, space)).trim();
  }

  String _readTextUntilClose(String name) {
    final close = '</$name>';
    final end = _xml.indexOf(close, _pos);
    if (end < 0) {
      throw FormatException('$_label: unterminated <$name>', _xml, _pos);
    }
    final text = _xml.substring(_pos, end);
    _pos = end + close.length;
    return _unescapeXml(text);
  }
}

// ---------------------------------------------------------------------------
// Comment stripping
// ---------------------------------------------------------------------------

/// Blank out `#` comments in YAML [source], keeping quoted values intact and
/// preserving offsets.
///
/// The workflow this reads is unusually comment-dense about the very settings
/// asserted against it — the `api-level` matrix has ~90 lines of prose around
/// it explaining why it is duplicated — so an unstripped scan finds a second
/// "declaration" the moment someone writes one in a sentence. That is the
/// failure mode the workflow's own header documents biting this repo twice.
///
/// A `#` inside quotes is preserved, matching `scripts/ci-versions.sh`'s
/// reader, so a value that legitimately contains one is not truncated.
String stripHashComments(String source) {
  final out = StringBuffer();
  var inQuote = '';
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (c == '\n') {
      inQuote = '';
      out.write(c);
      continue;
    }
    if (inQuote.isEmpty && (c == "'" || c == '"')) {
      inQuote = c;
      out.write(c);
      continue;
    }
    if (inQuote.isNotEmpty) {
      if (c == inQuote) inQuote = '';
      out.write(c);
      continue;
    }
    if (c == '#') {
      // Blank to end of line, preserving offsets.
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      if (i < source.length) out.write('\n');
      continue;
    }
    out.write(c);
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// Comment stripping that KEEPS string contents
// ---------------------------------------------------------------------------

/// Blank out `//` and `/* */` comments in [source], keeping string-literal
/// CONTENTS intact and preserving offsets (removed characters become spaces,
/// newlines are kept).
///
/// The counterpart to [stripDartCommentsAndStringContents], which also blanks
/// what is inside quotes. Which one you want depends on where the value lives:
///
///   * Blank strings too when asking "does the code DO this?" — a log message
///     or a doc string mentioning an API must not answer yes.
///   * Keep strings, as here, when the value being audited only exists inside
///     a literal. Both current callers need that: `classpath
///     'com.android.tools.build:gradle'` in a Gradle file, and
///     `import 'error_flow_test.dart' as ...;` in a Dart one — blanking the
///     quotes would erase the very thing the assertion reads.
///
/// Comments must still go, and not as a nicety: the files audited here carry
/// long explanatory comments naming the settings being asserted ("Matches
/// android/app/build.gradle's literal minSdkVersion 24"), so a raw scan finds
/// two declarations where the file has one and a single-value assertion fails
/// on prose. That is the same class of bug the workflow header describes.
///
/// String state is tracked so a `//` inside a quoted URL (there is one in
/// android/app/build.gradle's keystore warning) does not read as a comment and
/// swallow the rest of the line.
///
/// Groovy and Dart are close enough to share this: same `//`, `/* */`, quote
/// and triple-quote forms. Two Dart-only shapes are NOT modelled, because
/// neither appears in the files this reads — raw strings (`r'...'`, where a
/// backslash is literal) and nested block comments, which Dart allows and
/// Groovy does not.
String stripCommentsKeepingStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;

  void blank(int count) {
    for (var k = 0; k < count; k++) {
      out.write(source[i + k] == '\n' ? '\n' : ' ');
    }
    i += count;
  }

  while (i < n) {
    final c = source[i];

    if (c == '/' && i + 1 < n && source[i + 1] == '/') {
      final lineEnd = source.indexOf('\n', i);
      blank((lineEnd < 0 ? n : lineEnd) - i);
      continue;
    }

    if (c == '/' && i + 1 < n && source[i + 1] == '*') {
      final end = source.indexOf('*/', i + 2);
      blank((end < 0 ? n : end + 2) - i);
      continue;
    }

    if (c == "'" || c == '"') {
      final triple = source.startsWith(c * 3, i);
      final delim = triple ? c * 3 : c;
      out.write(delim);
      i += delim.length;
      while (i < n) {
        if (source.startsWith(delim, i)) {
          out.write(delim);
          i += delim.length;
          break;
        }
        if (source[i] == r'\' && i + 1 < n) {
          out.write(source.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (!triple && source[i] == '\n') break; // Unterminated: bail out.
        out.write(source[i]);
        i++;
      }
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// Dart-source scanning
// ---------------------------------------------------------------------------

bool _isIdentifierChar(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);

/// Blank out comments and string-literal contents in Dart [source], replacing
/// every removed character with a space (newlines are kept) so that offsets and
/// line numbers still line up with the original file.
///
/// This is what lets a test ask "does the code call X?" without the ANSWER
/// being yes merely because a comment or a log message mentions X. That is not
/// hypothetical here: `lib/services/real_ble_service.dart` carries a long
/// comment explaining why `Permission.bluetooth.request()` must NOT be called
/// on iOS, and a plain text search happily matches it.
///
/// Handles `//`, nesting `/* */`, single/double quotes, triple quotes, raw
/// (`r'...'`) strings, and `${...}` interpolations (blanked whole, so a quote
/// or brace inside one cannot desynchronise the scan).
String stripDartCommentsAndStringContents(String source) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;

  void blank(int count) {
    for (var k = 0; k < count; k++) {
      out.write(source[i + k] == '\n' ? '\n' : ' ');
    }
    i += count;
  }

  while (i < n) {
    final c = source[i];

    if (c == '/' && i + 1 < n && source[i + 1] == '/') {
      final lineEnd = source.indexOf('\n', i);
      blank((lineEnd < 0 ? n : lineEnd) - i);
      continue;
    }

    if (c == '/' && i + 1 < n && source[i + 1] == '*') {
      var depth = 0;
      while (i < n) {
        if (source.startsWith('/*', i)) {
          depth++;
          blank(2);
          continue;
        }
        if (source.startsWith('*/', i)) {
          depth--;
          blank(2);
          if (depth == 0) break;
          continue;
        }
        blank(1);
      }
      continue;
    }

    if (c == "'" || c == '"') {
      final isRaw = i > 0 &&
          source[i - 1] == 'r' &&
          (i < 2 || !_isIdentifierChar(source[i - 2]));
      final triple = source.startsWith(c * 3, i);
      final delim = triple ? c * 3 : c;
      out.write(delim);
      i += delim.length;
      while (i < n) {
        if (source.startsWith(delim, i)) {
          out.write(delim);
          i += delim.length;
          break;
        }
        if (!isRaw && source[i] == r'\' && i + 1 < n) {
          blank(2);
          continue;
        }
        if (!isRaw && source.startsWith(r'${', i)) {
          // Blank the whole interpolation, braces included, so a quote or an
          // unbalanced brace inside it cannot desynchronise the scan.
          var depth = 0;
          var end = i;
          while (end < n) {
            if (source[end] == '{') depth++;
            if (source[end] == '}') {
              depth--;
              if (depth == 0) {
                end++;
                break;
              }
            }
            end++;
          }
          blank(end - i);
          continue;
        }
        if (!triple && source[i] == '\n') break; // Unterminated: bail out.
        blank(1);
      }
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

/// The 1-based line number of [offset] within [source].
int lineNumberAt(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;
