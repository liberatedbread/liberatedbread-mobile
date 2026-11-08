// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/vendor_names.dart';

void main() {
  group('displayVendorName', () {
    test('drops the legal form, however it was filed', () {
      expect(displayVendorName('Apple, Inc.'), 'Apple');
      expect(displayVendorName('Intel Corp.'), 'Intel');
      expect(displayVendorName('Philips Lighting BV'), 'Philips Lighting');
      expect(
        displayVendorName('Hangzhou Hikvision Digital Technology Co.,Ltd.'),
        'Hangzhou Hikvision Digital Technology',
      );
      expect(
        displayVendorName('Endress & Hauser GmbH & Co'),
        'Endress & Hauser',
      );
    });

    test('puts an all-capitals filing in title case, sparing acronyms', () {
      expect(
        displayVendorName('TP-LINK TECHNOLOGIES CO.,LTD.'),
        'TP-Link Technologies',
      );
      expect(displayVendorName('MURATA MACHINERY, LTD.'), 'Murata Machinery');
    });

    test('keeps the legal form when the name alone would be a fragment', () {
      expect(displayVendorName('F5 Inc.'), 'F5 Inc.');
      expect(displayVendorName('3M'), '3M');
    });

    test('names a radio maker the one way, whichever subsidiary filed', () {
      expect(displayVendorName('Espressif Inc.'), 'Espressif');
      expect(
        displayVendorName('Espressif Systems (Shanghai) Co., Ltd.'),
        'Espressif',
      );
      expect(displayVendorName('Hon Hai Precision Ind. Co.,Ltd.'), 'Foxconn');
      expect(displayVendorName('SHENZHEN BILIAN ELECTRONIC CO.，LTD'), 'Bilian');
      expect(displayVendorName('Nordic Semiconductor ASA'), 'Nordic');
    });
  });

  group('vendorPhrase', () {
    test('says a radio maker as the radio', () {
      expect(vendorPhrase('Espressif'), 'Espressif radio');
      expect(vendorPhrase('Texas Instruments'), 'Texas Instruments radio');
    });

    test('says a product maker as itself', () {
      expect(vendorPhrase('Philips Lighting'), 'Philips Lighting');
      expect(isRadioVendor('Philips Lighting'), isFalse);
    });
  });
}
