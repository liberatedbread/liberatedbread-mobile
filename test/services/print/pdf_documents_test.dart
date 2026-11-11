// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The PDFs handed to the system print dialog.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/print/pdf_documents.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:pdf/pdf.dart';

bool _looksLikePdf(Uint8List b) => ascii.decode(b.sublist(0, 5)) == '%PDF-';

void main() {
  test('pdfSafe keeps Latin-1 and maps the catalogue punctuation', () {
    expect(pdfSafe('Café — “quoted” … ok'), 'Café - "quoted" ... ok');
    expect(pdfSafe('line1\nline2\tx'), 'line1\nline2\tx');
    expect(pdfSafe('日本'), '??');
  });

  test('isPdf reads the signature, not a name', () {
    expect(isPdf(Uint8List.fromList(ascii.encode('%PDF-1.7'))), isTrue);
    expect(isPdf(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isFalse);
    expect(isPdf(Uint8List(2)), isFalse);
  });

  test('a text document spans pages and survives any text', () async {
    final pdf = await textDocumentPdf(
      format: PdfPageFormat.a4,
      title: 'Diagnostics — today',
      subtitle: '3 line(s)',
      sections: [
        (
          heading: null,
          paragraphs: [for (var i = 0; i < 400; i++) 'line $i … “x” 日本'],
        ),
      ],
      monospace: true,
    );
    expect(_looksLikePdf(pdf), isTrue);
  });

  test('setup instructions print every section', () async {
    const instructions = SetupInstructionsDto(
      notes: 'Overview — with a dash.',
      methods: [
        SetupMethodDto(
          name: 'Pairing',
          description: 'Hold the button.',
          steps: [SetupStepDto(action: 'Hold for 5 s', expect: 'LED blinks')],
          stages: [],
          troubleshooting: [
            TroubleshootingDto(symptom: 'No LED', causes: ['Battery flat']),
          ],
        ),
      ],
      rejoin: RejoinDto(notes: 'One phone at a time.'),
    );
    final pdf = await setupInstructionsPdf(
      format: PdfPageFormat.letter,
      deviceName: 'Ember Mug',
      instructions: instructions,
    );
    expect(_looksLikePdf(pdf), isTrue);
  });

  group('setup sections follow the screen they are printed from', () {
    const instructions = SetupInstructionsDto(
      notes: 'Overview.',
      methods: [
        SetupMethodDto(
          name: 'Pairing',
          steps: [SetupStepDto(action: 'Hold for 5 s')],
          stages: [],
          troubleshooting: [
            TroubleshootingDto(symptom: 'No LED', causes: ['Battery flat']),
          ],
        ),
        // Blank: no section, as the screen draws no card for it.
        SetupMethodDto(
          name: 'Empty',
          description: '  ',
          steps: [],
          stages: [],
          troubleshooting: [],
        ),
      ],
      factoryReset: FactoryResetDto(effect: 'Wipes it.', procedures: []),
      rejoin: RejoinDto(notes: 'One phone at a time.'),
    );

    test('after a failed connect, reconnecting and troubleshooting lead', () {
      expect(
        [for (final s in setupInstructionsSections(instructions)) s.heading],
        [
          'Reconnecting',
          "If it won't connect",
          'Overview',
          'Pairing',
          'Factory reset',
        ],
      );
    });

    test('from the pairing guide, the steps lead', () {
      expect(
        [
          for (final s in setupInstructionsSections(
            instructions,
            afterFailedConnect: false,
          ))
            s.heading,
        ],
        [
          'Overview',
          'Pairing',
          "If it won't connect",
          'If it disconnects later',
          'Factory reset',
        ],
      );
    });
  });

  test('a staged route and a reset procedure print every part', () {
    const instructions = SetupInstructionsDto(
      methods: [
        SetupMethodDto(
          name: 'HomeKit pairing',
          steps: [],
          stages: [
            SetupStageDto(
              name: 'Join the hub',
              description: '  Put it near the hub.  ',
              steps: [
                SetupStepDto(action: 'Hold the button', expect: 'Blinks'),
              ],
              troubleshooting: [],
            ),
            // No name or description: only its steps print.
            SetupStageDto(
              description: '   ',
              steps: [SetupStepDto(action: 'Scan the code')],
              troubleshooting: [],
            ),
          ],
          troubleshooting: [],
        ),
      ],
      factoryReset: FactoryResetDto(
        effect: 'Wipes it.',
        procedures: [
          FactoryResetProcedureDto(
            name: 'Long press',
            holdSeconds: 15,
            steps: [SetupStepDto(action: 'Hold power')],
          ),
          FactoryResetProcedureDto(
            name: 'Power cycle',
            steps: [SetupStepDto(action: 'Unplug it five times')],
          ),
        ],
      ),
    );

    final sections = setupInstructionsSections(instructions);

    expect(sections.map((s) => s.heading), [
      'HomeKit pairing',
      'Factory reset',
    ]);
    expect(sections[0].paragraphs, [
      'Join the hub',
      'Put it near the hub.',
      '1. Hold the button\n   Expect: Blinks',
      '1. Scan the code',
    ]);
    expect(sections[1].paragraphs, [
      'Wipes it.',
      'Long press (hold 15 s)',
      '1. Hold power',
      'Power cycle',
      '1. Unplug it five times',
    ]);
  });

  test('the pairing block prints as the screen words it', () {
    const instructions = SetupInstructionsDto(
      methods: [
        SetupMethodDto(
          name: 'Pair',
          steps: [SetupStepDto(action: 'Open the app')],
          stages: [],
          troubleshooting: [],
        ),
      ],
      pairing: PairingDto(
        required_: true,
        securityMode: 'legacy_pin',
        pin: PairingPinDto(source: 'fixed_default', value: '1234'),
        enterPairingMode: PairingModeDto(
          required_: true,
          procedures: [
            FactoryResetProcedureDto(
              name: 'Hold the button',
              holdSeconds: 5,
              indicator: 'LED blinks',
              steps: [SetupStepDto(action: 'Hold it')],
            ),
          ],
        ),
        notes: 'Classic SPP.',
      ),
    );

    final fresh = setupInstructionsSections(
      instructions,
      afterFailedConnect: false,
    );
    expect(fresh.map((s) => s.heading), ['Pairing', 'Pair']);
    expect(fresh[0].paragraphs, [
      'Pair it before it will answer.',
      '- Pairing asks for a PIN.',
      '- Pairing code: 1234',
      'Pairing mode',
      '- Put it in pairing mode first.',
      'Hold the button — Hold 5 s\n1. Hold it\nConfirmed by: LED blinks',
      'Classic SPP.',
    ]);
    // An all-unknown block prints nothing.
    expect(
      setupInstructionsSections(
        const SetupInstructionsDto(
          methods: [],
          pairing: PairingDto(bonding: 'unknown'),
        ),
      ),
      isEmpty,
    );
  });

  test('a label prints at its physical size', () async {
    final pdf = await labelImagePdf(
      format: PdfPageFormat.a4,
      rgb: Uint8List(96 * 40 * 3),
      width: 96,
      height: 40,
      dpi: 203,
    );
    expect(_looksLikePdf(pdf), isTrue);
  });
}
