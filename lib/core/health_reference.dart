// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

const nihPulseOximetryUrl = 'https://www.ncbi.nlm.nih.gov/books/NBK470348/';
const nihBloodPressureUrl =
    'https://www.nhlbi.nih.gov/health/high-blood-pressure';
const beurerPo60ManualUrl =
    'https://pim.beurer.com/images/attribut/'
    '454.20-PO60_2020-04-24_04_IM1a_BEU_DE-EN.pdf';
const beurerBm92ManualUrl =
    'https://www.shop-beurer.com/cdn/shop/files/'
    '101.55_BM92_2023-04-04_01_IM_BEU-USA.pdf?v=17104474228358017001';

enum HealthReferenceTone { normal, caution, warning, critical, neutral }

class HealthReferenceRow {
  final String label;
  final String range;
  final HealthReferenceTone tone;

  const HealthReferenceRow(this.label, this.range, this.tone);
}

const oxygenNihRows = [
  HealthReferenceRow(
    'Common adult range',
    '95–100% SpO₂',
    HealthReferenceTone.normal,
  ),
  HealthReferenceRow(
    'Below common range',
    '90–94% SpO₂',
    HealthReferenceTone.caution,
  ),
  HealthReferenceRow(
    'Hypoxemia range',
    '<90% SpO₂',
    HealthReferenceTone.critical,
  ),
];

const oxygenBeurerRows = [
  HealthReferenceRow('Normal range', '94–99% SpO₂', HealthReferenceTone.normal),
  HealthReferenceRow(
    'Decreased range',
    '90–93% SpO₂',
    HealthReferenceTone.caution,
  ),
  HealthReferenceRow(
    'Critical range',
    '<90% SpO₂',
    HealthReferenceTone.critical,
  ),
];

const bloodPressureNihRows = [
  HealthReferenceRow('Normal', '<120 AND <80 mmHg', HealthReferenceTone.normal),
  HealthReferenceRow(
    'Elevated',
    '120–129 AND <80 mmHg',
    HealthReferenceTone.caution,
  ),
  HealthReferenceRow(
    'High blood pressure · stage 1',
    '130–139 OR 80–89 mmHg',
    HealthReferenceTone.warning,
  ),
  HealthReferenceRow(
    'High blood pressure · stage 2',
    '≥140 OR ≥90 mmHg',
    HealthReferenceTone.critical,
  ),
  HealthReferenceRow(
    'Hypertensive crisis',
    '>180 OR >120 mmHg',
    HealthReferenceTone.critical,
  ),
];

const bloodPressureBeurerRows = [
  HealthReferenceRow(
    'Optimal',
    '<120 AND <80 mmHg',
    HealthReferenceTone.normal,
  ),
  HealthReferenceRow(
    'Normal',
    '120–129 OR 80–84 mmHg',
    HealthReferenceTone.normal,
  ),
  HealthReferenceRow(
    'High normal',
    '130–139 OR 85–89 mmHg',
    HealthReferenceTone.caution,
  ),
  HealthReferenceRow(
    'Grade 1 · mild hypertension',
    '140–159 OR 90–99 mmHg',
    HealthReferenceTone.warning,
  ),
  HealthReferenceRow(
    'Grade 2 · moderate hypertension',
    '160–179 OR 100–109 mmHg',
    HealthReferenceTone.critical,
  ),
  HealthReferenceRow(
    'Grade 3 · severe hypertension',
    '≥180 OR ≥110 mmHg',
    HealthReferenceTone.critical,
  ),
];

const _outsideRange = HealthReferenceRow(
  'Outside cited range',
  'See the source tables',
  HealthReferenceTone.neutral,
);

HealthReferenceRow oxygenNihReference(double value) {
  if (!_validOxygen(value)) return _outsideRange;
  if (value > 100) return _outsideRange;
  if (value >= 95) return oxygenNihRows[0];
  if (value >= 90) return oxygenNihRows[1];
  return oxygenNihRows[2];
}

HealthReferenceRow oxygenBeurerReference(double value) {
  if (!_validOxygen(value)) return _outsideRange;
  if (value > 99) return _outsideRange;
  if (value >= 94) return oxygenBeurerRows[0];
  if (value >= 90) return oxygenBeurerRows[1];
  return oxygenBeurerRows[2];
}

HealthReferenceRow bloodPressureNihReference(
  double systolic,
  double diastolic,
) {
  if (!_validPressure(systolic) || !_validPressure(diastolic)) {
    return _outsideRange;
  }
  if (systolic > 180 || diastolic > 120) return bloodPressureNihRows[4];
  if (systolic >= 140 || diastolic >= 90) return bloodPressureNihRows[3];
  if (systolic >= 130 || diastolic >= 80) return bloodPressureNihRows[2];
  if (systolic >= 120 && diastolic < 80) return bloodPressureNihRows[1];
  return bloodPressureNihRows[0];
}

HealthReferenceRow bloodPressureBeurerReference(
  double systolic,
  double diastolic,
) {
  if (!_validPressure(systolic) || !_validPressure(diastolic)) {
    return _outsideRange;
  }
  if (systolic >= 180 || diastolic >= 110) return bloodPressureBeurerRows[5];
  if (systolic >= 160 || diastolic >= 100) return bloodPressureBeurerRows[4];
  if (systolic >= 140 || diastolic >= 90) return bloodPressureBeurerRows[3];
  if (systolic >= 130 || diastolic >= 85) return bloodPressureBeurerRows[2];
  if (systolic >= 120 || diastolic >= 80) return bloodPressureBeurerRows[1];
  return bloodPressureBeurerRows[0];
}

/// Zero is a sensor with nothing in it, not a saturation: it must not be
/// placed in the table's lowest band.
bool _validOxygen(double value) => value.isFinite && value > 0;

bool _validPressure(double value) => value.isFinite && value >= 0;
