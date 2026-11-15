# A&D Medical Continua BT Classic Family (UA-767PBT-C, UC-321PBT-C) — Research Notes

## Product & Company Status
- **Products**: UA-767PBT-C / UA-767PBT-Ci upper-arm blood pressure monitor and UC-321PBT-C precision weight scale — the **first Continua-certified** Bluetooth BP monitor and scale ([A&D press release, 2009-08-03](https://www.aandd.jp/whatnew/2009/continua_certification200908.html); [MobiHealthNews](https://www.mobihealthnews.com/news/ad-medical-releases-first-continua-certified-blood-pressure-monitor-and-weight-scale)).
- **Transport**: Bluetooth Classic (Class 1 on UA-767PBT-C, per [A&D product page](https://www.aandd.jp/products/medical/bluetooth/ua_767pbt_c.html)), **Health Device Profile (HDP)** + **ISO/IEEE 11073** data protocol.
- **Status**: UA-767PBT-Ci listed as **Discontinued** ([MedM device page](https://www.medm.com/sensors/and_medical/ua-767pbt-ci-bpm-app.html)); A&D Medical is alive — current connected line is BLE (UA-651BLE etc.) with the A&D Connect / WellnessConnected apps.
- **Cloud dependency**: **None.** These devices push measurements over HDP to any local manager; no A&D account was ever involved in the data path.

## Protocol Facts
- Standards-based, not proprietary: Bluetooth HDP (L2CAP channels negotiated via SDP) carrying IEEE 11073-20601 APDUs.
  - BP monitor: IEEE 11073-10407 specialization (systolic/diastolic/MAP, pulse, timestamp, 25-reading memory).
  - Scale: IEEE 11073-10415 specialization (body weight, BMI, timestamp).
- Agent-initiated: device connects out to the manager after a measurement; manager must be discoverable (matches the [MedM connection walkthrough](https://www.medm.com/sensors/and_medical/ua-767pbt-bpm-mobile-app.html)).
- Open-source manager stack: [signove/antidote](https://github.com/signove/antidote) (IEEE 11073-20601, BlueZ HDP transport).
- Android: `android.bluetooth.BluetoothHealth` HDP-sink API (API 14+) was the standard host path; deprecated and removed from modern Android, so Linux/BlueZ or older Android is the practical host today. Community write-ups of talking to the UA-767PBT-C from Android HDP exist ([example tutorial](https://michael0905.github.io/2017/06/23/Android%E8%93%9D%E7%89%99%E5%81%A5%E5%BA%B7%E8%AE%BE%E5%A4%87%E5%BC%80%E5%8F%91%EF%BC%9AHealth%20Device%20Profile(HDP)/)).

## APK Provenance
- **Not fetched.** The era-appropriate app ("A&D Connect", WellnessConnected) package id was not verified; third-party MedM Health app supports the device but is a large multi-device platform. Unfetchable/unneeded — the protocol is standards-documented.

## Local Feasibility Verdict
**Confirmed.** Fully local, standards-based. Best host today: Linux + BlueZ HDP plugin + Antidote (or any IEEE 11073-20601 manager). Pairing is plain legacy BT bonding; the device then pushes readings.

## Safety
- Clinically validated BP monitor; readings inform medication decisions — treat as MEDIUM safety class for any downstream automation.

## Open Questions
- Whether UC-321PBT-C pairing differs (Class 2 radio, scale specialization).
- Modern-phone path: HDP is gone from recent Android; document a BlueZ-only host recipe in the full spec.
