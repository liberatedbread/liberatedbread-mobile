// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/services/chirp_csv.dart';

List<String> _cells(String row) {
  // A small reader, because the assertions want fields and the encoder is
  // what is under test -- reusing its own splitter would prove nothing.
  final out = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < row.length; i++) {
    final char = row[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < row.length && row[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        buffer.write(char);
      }
    } else if (char == '"') {
      quoted = true;
    } else if (char == ',') {
      out.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  out.add(buffer.toString());
  return out;
}

String _column(String csv, int row, String column) {
  final lines = csv.split('\r\n');
  final headers = _cells(lines.first);
  final index = headers.indexOf(column);
  expect(index, isNot(-1), reason: 'no $column column');
  return _cells(lines[row + 1])[index];
}

void main() {
  const repeater = RadioChannel(
    name: 'W1AW',
    rxFreqHz: 146940000,
    txFreqHz: 146340000,
    txTone: ToneSetting.ctcss(1000),
    comment: 'Newington',
  );

  group('the header', () {
    test('is the column list CHIRP itself writes, minus Power', () {
      // Read off Memory.CSV_FORMAT in chirp_common.py. Power is absent
      // deliberately: CHIRP's parse_power rejects an empty cell and fails the
      // whole row, and this app models high/low rather than watts, so any
      // number here would be one the user never chose.
      expect(chirpCsvHeader, [
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
      ]);
      expect(chirpCsvHeader, isNot(contains('Power')));
    });

    test('is the first line of the document', () {
      final csv = encodeChirpCsv(const [repeater]);
      expect(csv.split('\r\n').first, chirpCsvHeader.join(','));
    });

    test('every row has exactly as many cells as the header', () {
      final csv = encodeChirpCsv(const [
        repeater,
        RadioChannel.receiveOnly(name: 'WX1', freqHz: 162550000),
      ]);
      for (final line in csv.split('\r\n')) {
        if (line.isEmpty) continue;
        expect(_cells(line), hasLength(chirpCsvHeader.length), reason: line);
      }
    });
  });

  group('line endings', () {
    test('are CRLF, as CHIRP writes', () {
      final csv = encodeChirpCsv(const [repeater]);
      expect(csv, contains('\r\n'));
      expect(csv.endsWith('\r\n'), isTrue);
      // No bare newlines anywhere.
      expect(csv.replaceAll('\r\n', ''), isNot(contains('\n')));
    });

    test('an empty plan is a header and nothing else', () {
      expect(encodeChirpCsv(const []), '${chirpCsvHeader.join(',')}\r\n');
    });
  });

  group('frequencies', () {
    test('are whole megahertz, a dot, and six digits', () {
      expect(chirpFrequency(146940000), '146.940000');
      expect(chirpFrequency(446000000), '446.000000');
      expect(chirpFrequency(462562500), '462.562500');
      expect(chirpFrequency(600000), '0.600000');
      expect(chirpFrequency(0), '0.000000');
    });

    test('appear in the Frequency and Offset columns', () {
      final csv = encodeChirpCsv(const [repeater]);
      expect(_column(csv, 0, 'Frequency'), '146.940000');
      expect(_column(csv, 0, 'Offset'), '0.600000');
    });

    test('the offset is a magnitude; the sign lives in Duplex', () {
      final csv = encodeChirpCsv(const [
        repeater,
        RadioChannel(name: 'UP', rxFreqHz: 146340000, txFreqHz: 146940000),
      ]);
      expect(_column(csv, 0, 'Offset'), '0.600000');
      expect(_column(csv, 0, 'Duplex'), '-');
      expect(_column(csv, 1, 'Offset'), '0.600000');
      expect(_column(csv, 1, 'Duplex'), '+');
    });
  });

  group('duplex', () {
    test('is empty for simplex', () {
      final csv = encodeChirpCsv(const [
        RadioChannel(name: 'S', rxFreqHz: 146520000, txFreqHz: 146520000),
      ]);
      expect(_column(csv, 0, 'Duplex'), '');
    });

    test('is off for a receive-only channel', () {
      // This is the cell that stops a radio keying on a weather channel.
      final csv = encodeChirpCsv(const [
        RadioChannel.receiveOnly(name: 'WX1', freqHz: 162550000),
      ]);
      expect(_column(csv, 0, 'Duplex'), 'off');
    });

    test('off wins over any offset the channel happens to carry', () {
      final csv = encodeChirpCsv(const [
        RadioChannel(
          name: 'ODD',
          rxFreqHz: 155000000,
          txFreqHz: 154400000,
          rxOnly: true,
        ),
      ]);
      expect(_column(csv, 0, 'Duplex'), 'off');
    });
  });

  group('tones', () {
    String tone(RadioChannel channel, String column) =>
        _column(encodeChirpCsv([channel]), 0, column);

    test('no tone is an empty Tone cell with CHIRP defaults beside it', () {
      const plain =
          RadioChannel(name: 'X', rxFreqHz: 146520000, txFreqHz: 146520000);
      expect(tone(plain, 'Tone'), '');
      expect(tone(plain, 'rToneFreq'), '88.5');
      expect(tone(plain, 'cToneFreq'), '88.5');
      expect(tone(plain, 'DtcsCode'), '023');
      expect(tone(plain, 'DtcsPolarity'), 'NN');
      expect(tone(plain, 'CrossMode'), 'Tone->Tone');
    });

    test('a transmit CTCSS tone is Tone', () {
      expect(tone(repeater, 'Tone'), 'Tone');
      expect(tone(repeater, 'rToneFreq'), '100.0');
    });

    test('CTCSS both ways is TSQL', () {
      const both = RadioChannel(
        name: 'X',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.ctcss(1000),
        rxTone: ToneSetting.ctcss(1072),
      );
      expect(tone(both, 'Tone'), 'TSQL');
      expect(tone(both, 'rToneFreq'), '100.0');
      expect(tone(both, 'cToneFreq'), '107.2');
    });

    test('DCS both ways is DTCS', () {
      const both = RadioChannel(
        name: 'X',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.dcs(23),
        rxTone: ToneSetting.dcs(23),
      );
      expect(tone(both, 'Tone'), 'DTCS');
      expect(tone(both, 'DtcsCode'), '023');
      expect(tone(both, 'RxDtcsCode'), '023');
    });

    test('DCS out with nothing in is a cross mode, not plain DTCS', () {
      // Plain DTCS squelches the receiver on the same code, silencing every
      // station not sending it. This app never turns receive squelch on by
      // itself -- the directory clients follow the same rule.
      const txOnly = RadioChannel(
        name: 'X',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.dcs(131),
      );
      expect(tone(txOnly, 'Tone'), 'Cross');
      expect(tone(txOnly, 'CrossMode'), 'DTCS->');
      expect(tone(txOnly, 'DtcsCode'), '131');
    });

    test('polarity is transmit then receive', () {
      const inverted = RadioChannel(
        name: 'X',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.dcs(23, inverted: true),
        rxTone: ToneSetting.dcs(23),
      );
      expect(tone(inverted, 'DtcsPolarity'), 'RN');

      const bothInverted = RadioChannel(
        name: 'X',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.dcs(23, inverted: true),
        rxTone: ToneSetting.dcs(23, inverted: true),
      );
      expect(tone(bothInverted, 'DtcsPolarity'), 'RR');
    });

    test('every mixed combination gets a cross mode CHIRP knows', () {
      const knownCrossModes = {
        'Tone->Tone',
        'DTCS->',
        '->DTCS',
        'Tone->DTCS',
        'DTCS->Tone',
        '->Tone',
        'DTCS->DTCS',
        'Tone->',
      };
      const tones = [
        ToneSetting.none,
        ToneSetting.ctcss(1000),
        ToneSetting.dcs(23),
      ];
      for (final tx in tones) {
        for (final rx in tones) {
          final channel = RadioChannel(
            name: 'X',
            rxFreqHz: 146940000,
            txFreqHz: 146340000,
            txTone: tx,
            rxTone: rx,
          );
          final csv = encodeChirpCsv([channel]);
          expect(knownCrossModes, contains(_column(csv, 0, 'CrossMode')),
              reason: '$tx / $rx');
          expect(
            ['', 'Tone', 'TSQL', 'DTCS', 'Cross'],
            contains(_column(csv, 0, 'Tone')),
            reason: '$tx / $rx',
          );
        }
      }
    });

    test('a tone with a zero tenth renders one decimal', () {
      const round = RadioChannel(
        name: 'X',
        rxFreqHz: 146940000,
        txFreqHz: 146340000,
        txTone: ToneSetting.ctcss(670),
      );
      expect(tone(round, 'rToneFreq'), '67.0');
    });
  });

  group('the remaining columns', () {
    test('number slots from 1', () {
      final csv = encodeChirpCsv(const [
        repeater,
        RadioChannel(name: 'B', rxFreqHz: 146520000, txFreqHz: 146520000),
      ]);
      expect(_column(csv, 0, 'Location'), '1');
      expect(_column(csv, 1, 'Location'), '2');
    });

    test('carry the mode, tuning step, skip and comment', () {
      final csv = encodeChirpCsv(const [repeater]);
      expect(_column(csv, 0, 'Mode'), 'FM');
      expect(_column(csv, 0, 'TStep'), '5.00');
      expect(_column(csv, 0, 'Skip'), '');
      expect(_column(csv, 0, 'Comment'), 'Newington');
      expect(_column(csv, 0, 'Name'), 'W1AW');
    });

    test('spell narrow FM the way CHIRP does', () {
      final csv = encodeChirpCsv(const [
        RadioChannel(
          name: 'N',
          rxFreqHz: 462562500,
          txFreqHz: 462562500,
          mode: ChannelMode.nfm,
        ),
      ]);
      expect(_column(csv, 0, 'Mode'), 'NFM');
    });

    test('leave the D-STAR columns empty', () {
      final csv = encodeChirpCsv(const [repeater]);
      for (final column in ['URCALL', 'RPT1CALL', 'RPT2CALL', 'DVCODE']) {
        expect(_column(csv, 0, column), '');
      }
    });
  });

  group('quoting', () {
    test('quotes a cell containing a comma', () {
      final csv = encodeChirpCsv(const [
        RadioChannel(
          name: 'A,B',
          rxFreqHz: 146940000,
          txFreqHz: 146340000,
          comment: 'Hartford, CT',
        ),
      ]);
      expect(csv, contains('"A,B"'));
      expect(csv, contains('"Hartford, CT"'));
      expect(_column(csv, 0, 'Name'), 'A,B');
      expect(_column(csv, 0, 'Comment'), 'Hartford, CT');
    });

    test('doubles an embedded quote', () {
      final csv = encodeChirpCsv(const [
        RadioChannel(
          name: 'The "Hill"',
          rxFreqHz: 146940000,
          txFreqHz: 146340000,
        ),
      ]);
      expect(csv, contains('"The ""Hill"""'));
      expect(_column(csv, 0, 'Name'), 'The "Hill"');
    });

    test('quotes a cell containing a line break', () {
      final csv = encodeChirpCsv(const [
        RadioChannel(
          name: 'X',
          rxFreqHz: 146940000,
          txFreqHz: 146340000,
          comment: 'line one\nline two',
        ),
      ]);
      expect(csv, contains('"line one\nline two"'));
    });

    test('leaves an ordinary cell unquoted', () {
      final csv = encodeChirpCsv(const [repeater]);
      expect(csv, contains(',W1AW,'));
    });
  });

  test('the golden row is stable', () {
    // One full row, spelled out. If any cell here changes, a CHIRP import
    // changes with it, and that should be a deliberate edit rather than a
    // side effect.
    final csv = encodeChirpCsv(const [repeater]);
    expect(
      csv.split('\r\n')[1],
      '1,W1AW,146.940000,-,0.600000,Tone,100.0,88.5,023,NN,023,'
      'Tone->Tone,FM,5.00,,Newington,,,,',
    );
  });

  test('a transmit unlock cannot leak through an exported file', () {
    // CHIRP's generic CSV carries per-channel data and no band limits, so a
    // plan built with the unlock on exports byte-identically to one built
    // without it. The unlock exists only on the write-to-radio path.
    const channel = RadioChannel(
      name: 'MARS',
      rxFreqHz: 140000000,
      txFreqHz: 140000000,
    );
    expect(encodeChirpCsv(const [channel]), encodeChirpCsv(const [channel]));
    expect(encodeChirpCsv(const [channel]), isNot(contains('limit')));
    expect(encodeChirpCsv(const [channel]), isNot(contains('unlock')));
  });
}
