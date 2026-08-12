# Zephyr BioHarness 3 / HxM — Research Notes

## Product & Company Status
- **Products**: Zephyr BioHarness 3 chest-strap physiological monitor; HxM / HxM Smart heart-rate + activity strap. Same Bluetooth Classic serial protocol family.
- **Transport**: Bluetooth Classic (BR/EDR) **SPP**, 115200 baud 8N1 — vendor-documented in the HxM Bluetooth API Guide ([zephyranywhere.com PDF, 2010](https://www.zephyranywhere.com/media/download/hxm1-api-p-bluetooth-hxm-api-guide-20100722-v01.pdf)).
- **Company**: Zephyr Technology acquired by Covidien ([MassDevice, 2014-05-05](https://www.massdevice.com/report-covidien-acquires-zephyrs-wearable-monitors/)); Covidien then acquired by Medtronic ([Medtronic, 2014-06-15](https://news.medtronic.com/2014-06-15-Medtronic-to-Acquire-Covidien-for-42-9-billion-in-Cash-and-Stock)). Zephyr Performance Systems survives under Medtronic selling to military/research ([zephyranywhere.com history](https://www.zephyranywhere.com/about-us/history-future)), but the consumer/prosumer line (HxM, consumer BioHarness software) is orphaned.
- **Cloud dependency**: **None, ever.** Data path was always direct Bluetooth SPP to a host PC/device running OmniSense or third-party software. No account, no pairing server.

## Protocol Facts (vendor-documented, not RE'd)
- Zephyr published the full "Bluetooth Data Link" protocol spec as part of its developer program; the HxM API guide is still hosted publicly (link above).
- Message framing: STX (0x02), message ID, length, payload, CRC; documented in the vendor docs and implemented by third parties.
- General Data Packet (msg 0x20) carries HR, breathing rate, activity (VMU), peak acceleration, posture, battery, ROG status — rate configurable.
- ECG waveform 250 Hz, respiration waveform ~25 Hz, accelerometer XYZ up to 100 Hz over Bluetooth (waveforms are BT-only, not USB) per [yellowcog module docs](https://www.yellowcog.com/help/zephyr-bioharness) and [MedicalExpo data sheet](https://pdf.medicalexpo.com/pdf/zephyr/zephyr-bioharness/83995-97427.html).

## Existing Community Implementations
- [roger-/pyzephyr](https://github.com/roger-/pyzephyr) — Python library for the serial Bluetooth protocol of BioHarness and HxM (message framing, signal parsing, R-R events). Fork: [darkopetrovic/zephyr-bt](https://github.com/darkopetrovic/zephyr-bt).
- [labstreaminglayer/App-Zephyr](https://github.com/labstreaminglayer/App-Zephyr) — LSL integration for Medtronic/Zephyr BioModule and BioHarness (wraps vendor SDK; its README says BLE, which applies to newer BioModule units — BioHarness 3 / HxM are Classic SPP).

## APK Provenance
- **No companion app fetched.** Zephyr's Android apps (OmniSense Mobile / Zephyr HxM era) were never indexed by package id here and appear delisted; apkeep not attempted with a confirmed package id. Unfetchable APK does not block this device — the protocol is vendor-documented and SPP is generic.

## Local Feasibility Verdict
**Confirmed.** Pair with standard BT pairing (PIN `1234` reported in community usage), open RFCOMM channel 1 / SPP UUID `00001101-0000-1000-8000-00805f9b34fb`, speak the published framed protocol. Works from Linux (`rfcomm`/pyserial via pyzephyr), Android (BluetoothSocket SPP), Windows.

## Safety
- Consumer fitness/research device; readings are not for clinical diagnosis. BioPatch (same company) is FDA-cleared but is a different, prescription product.

## Open Questions
- BioHarness 3 vs newer Medtronic "BioModule" — latter may be BLE; confirm before buying.
- Whether the full BioHarness 3 protocol PDF (beyond HxM guide) is still mirrored anywhere public; archive a copy into research notes if found (facts only).
