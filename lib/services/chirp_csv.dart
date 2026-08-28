// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Writing a plan as a file CHIRP can open.
//
// The column names, value spellings and number formats below were read off
// CHIRP's own generic-CSV driver rather than remembered: `Memory.CSV_FORMAT`
// and `Memory.to_csv()` in chirp_common.py, and `CSVRadio.ATTR_MAP` in
// drivers/generic_csv.py. Only facts are used -- no CHIRP code is copied.
// CHIRP is GPL-3.0 and this crate is Apache-2.0, so that distinction is the
// whole reason this file is written from the format rather than from the
// implementation.

import '../models/radio_channel.dart';

/// The columns CHIRP writes, minus `Power`.
///
/// `Power` is deliberately absent. CHIRP parses that cell with `parse_power`,
/// which rejects an empty string outright and fails the whole row -- and this
/// app models power as high/low, not as watts, so any number it wrote would
/// be one the user never chose. An absent column is the documented way to say
/// "not specified": CHIRP skips headers it was not given and then applies its
/// own default power. The four trailing D-STAR columns are kept because a
/// real CHIRP export has them, which keeps a diff against one readable.
const List<String> chirpCsvHeader = [
  'Location',
  'Name',
  'Frequency',
  'Duplex',
  'Offset',
  'Tone',
  'rToneFreq',
  'cToneFreq',
  'DtcsCode',
  'DtcsPolarity',
  'RxDtcsCode',
  'CrossMode',
  'Mode',
  'TStep',
  'Skip',
  'Comment',
  'URCALL',
  'RPT1CALL',
  'RPT2CALL',
  'DVCODE',
];

/// CHIRP's own defaults for cells this app has nothing to say about, so an
/// exported row reads like one CHIRP wrote.
const String _defaultTone = '88.5';
const String _defaultDtcs = '023';
const String _defaultCrossMode = 'Tone->Tone';
const String _defaultTuningStep = '5.00';

/// CHIRP writes CRLF: Python's csv writer defaults to it and the file is
/// opened with `newline=''`, so the terminator reaches the file untouched.
const String _lineEnding = '\r\n';

/// Format Hz the way CHIRP's `format_freq` does: whole megahertz, a dot, and
/// exactly six digits of hertz.
String chirpFrequency(int hz) {
  final magnitude = hz.abs();
  final whole = magnitude ~/ 1000000;
  final fraction = (magnitude % 1000000).toString().padLeft(6, '0');
  return '$whole.$fraction';
}

/// Encode [channels] as a CHIRP generic CSV document.
///
/// Slots are numbered from 1, matching what the plan screen shows and what
/// every radio in the catalogue calls its first channel.
String encodeChirpCsv(List<RadioChannel> channels) {
  final buffer = StringBuffer()
    ..write(_csvRow(chirpCsvHeader))
    ..write(_lineEnding);
  for (var i = 0; i < channels.length; i++) {
    buffer
      ..write(_csvRow(chirpRow(channels[i], location: i + 1)))
      ..write(_lineEnding);
  }
  return buffer.toString();
}

/// One channel as the cells of a CHIRP row.
List<String> chirpRow(RadioChannel channel, {required int location}) {
  final tone = _toneCells(channel);
  return [
    '$location',
    channel.name,
    chirpFrequency(channel.rxFreqHz),
    _duplex(channel),
    chirpFrequency(channel.offsetHz.abs()),
    tone.mode,
    tone.rTone,
    tone.cTone,
    tone.dtcs,
    tone.polarity,
    tone.rxDtcs,
    tone.crossMode,
    channel.mode.chirpName,
    _defaultTuningStep,
    // Skip: this app has no concept of a scan-skipped channel, and an empty
    // cell is CHIRP's "do not skip".
    '',
    channel.comment,
    '', '', '', '',
  ];
}

/// `off` for a receive-only memory, `+`/`-` for a repeater, empty for
/// simplex. `off` is what stops a radio keying on a channel it should only
/// listen to, so it takes priority over any offset the channel happens to
/// carry.
String _duplex(RadioChannel channel) {
  if (channel.rxOnly) return 'off';
  final offset = channel.offsetHz;
  if (offset == 0) return '';
  return offset > 0 ? '+' : '-';
}

/// Map this app's per-direction tones onto CHIRP's single `Tone` column.
///
/// The mapping, and why:
///
/// | transmit | receive | Tone     | CrossMode  |
/// |----------|---------|----------|------------|
/// | none     | none    | ``       | default    |
/// | CTCSS    | none    | `Tone`   | default    |
/// | CTCSS    | CTCSS   | `TSQL`   | default    |
/// | DCS      | none    | `Cross`  | `DTCS->`   |
/// | DCS      | DCS     | `DTCS`   | default    |
/// | none     | CTCSS   | `Cross`  | `->Tone`   |
/// | none     | DCS     | `Cross`  | `->DTCS`   |
/// | CTCSS    | DCS     | `Cross`  | `Tone->DTCS` |
/// | DCS      | CTCSS   | `Cross`  | `DTCS->Tone` |
///
/// The row that looks surprising is DCS-out with nothing on receive. CHIRP's
/// plain `DTCS` mode squelches the receiver on the same code, and this app
/// does not turn receive squelch on by itself -- doing so silences every
/// station on the frequency that is not sending the code, which is a surprise
/// nobody asked for. The repeater clients follow the same rule when they read
/// a directory's receive-tone column, so the two agree.
({
  String mode,
  String rTone,
  String cTone,
  String dtcs,
  String polarity,
  String rxDtcs,
  String crossMode,
}) _toneCells(RadioChannel channel) {
  final tx = channel.txTone;
  final rx = channel.rxTone;

  String ctcss(ToneSetting tone) => tone.mode == ToneMode.ctcss
      ? _formatTone(tone.ctcssTenthHz)
      : _defaultTone;
  String dcs(ToneSetting tone) => tone.mode == ToneMode.dcs
      ? tone.dcsCode.toString().padLeft(3, '0')
      : _defaultDtcs;

  // Polarity is two characters: transmit, then receive. 'N' is normal, 'R'
  // inverted.
  final polarity = '${tx.mode == ToneMode.dcs && tx.dcsInverted ? 'R' : 'N'}'
      '${rx.mode == ToneMode.dcs && rx.dcsInverted ? 'R' : 'N'}';

  final cells = (
    rTone: ctcss(tx),
    cTone: ctcss(rx),
    dtcs: dcs(tx),
    polarity: polarity,
    rxDtcs: dcs(rx),
  );

  final (String mode, String crossMode) = switch ((tx.mode, rx.mode)) {
    (ToneMode.none, ToneMode.none) => ('', _defaultCrossMode),
    (ToneMode.ctcss, ToneMode.none) => ('Tone', _defaultCrossMode),
    (ToneMode.ctcss, ToneMode.ctcss) => ('TSQL', _defaultCrossMode),
    (ToneMode.dcs, ToneMode.dcs) => ('DTCS', _defaultCrossMode),
    (ToneMode.dcs, ToneMode.none) => ('Cross', 'DTCS->'),
    (ToneMode.none, ToneMode.ctcss) => ('Cross', '->Tone'),
    (ToneMode.none, ToneMode.dcs) => ('Cross', '->DTCS'),
    (ToneMode.ctcss, ToneMode.dcs) => ('Cross', 'Tone->DTCS'),
    (ToneMode.dcs, ToneMode.ctcss) => ('Cross', 'DTCS->Tone'),
  };

  return (
    mode: mode,
    rTone: cells.rTone,
    cTone: cells.cTone,
    dtcs: cells.dtcs,
    polarity: cells.polarity,
    rxDtcs: cells.rxDtcs,
    crossMode: crossMode,
  );
}

/// Tenths of a Hz as CHIRP's one-decimal tone: 1072 becomes "107.2".
String _formatTone(int tenthHz) =>
    '${tenthHz ~/ 10}.${(tenthHz % 10).toString()}';

/// RFC 4180 quoting, which is also what Python's csv writer emits: quote only
/// when the cell contains a separator, a quote or a line break, and double an
/// embedded quote.
String _csvRow(List<String> cells) =>
    [for (final cell in cells) _csvCell(cell)].join(',');

String _csvCell(String value) {
  if (!value.contains(',') &&
      !value.contains('"') &&
      !value.contains('\n') &&
      !value.contains('\r')) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}
