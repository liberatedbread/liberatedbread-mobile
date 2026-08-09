# Earin M-1 / M-2 — Research Notes

## What it is
Earin (Swedish startup, ex-Sony Ericsson engineers) — among the first true-wireless
earbuds: M-1 (2015, Kickstarter), M-2 (2017, NXP MiGLO NFMI link). Companion app
offers bass boost, L/R balance, per-bud battery levels, custom device name, gain
control (M-1); firmware/config for M-2.

## Why abandoned
- Earin was acquired by will.i.am's i.am+ in January 2018
  ([Digital Trends, 2018-01-09](https://www.digitaltrends.com/home-theater/earin-acquired-by-i-am-plus/));
  i.am+ itself subsequently collapsed.
- The Earin brand resurfaced briefly (A-3, 2021) but the company has since been
  dissolved; last social-media activity 2022-05-22
  ([Head-Fi thread, captured 2025-05-09](https://www.head-fi.org/threads/whatever-happened-to-earin.976822/)).
- No app or firmware updates since; buds work as plain BT audio, but bass boost /
  balance / gain / renaming need the app.

## APK provenance
- **Package**: `com.earin.earin` ("Earin"; Aptoide lists it as "Earin M-1", fetched
  version matches the M-2-era app numbering)
- **Version**: 1.0.19 (versionCode 100019) — fetched via apkeep (apk-pure source), 2026-08-03
  (Aptoide also carries 1.0.9 dated 2020-04-26)
- **APK SHA-256**: `21817dd9b3222e599f58f753b2f665015312f291a7cfa40c49e1ae8dc699e1c1`
- **Framework**: Java, small APK (3.6 MB), unobfuscated
  (`com.earin.earin.communication.cap` fully readable).
- jadx output at `workspace/static/earin/`.

## BLE GATT layout (from `communication/cap/CapUuids.java`)
Earin's proprietary "CAP" protocol:
- **CAP service** `be7386e3-8627-cf85-d743-dab853c7da70`
  - Requests (write): `19df2d7b-c4d0-47ff-a8f4-61173f363a42`
  - Events (notify): `619a19cb-64d4-4728-81f4-3684aa7bcc66`
  - Upgrade/DFU: `c40a47f8-b5fb-462f-b259-84b65b02aa57`
- Standard: CCCD `2902`; SPP `1101` also referenced.
- `CapProtocol.java` shows a text-ish request/response scheme
  (`lastSendRequestCommand` string prefix matching) — the command vocabulary should
  be directly extractable from the `communication/cap` package.

## Local BLE feasibility
Very high. Tiny single-purpose app, no account, no cloud; CAP is a simple
request/event GATT protocol with readable command strings in the decompile.
Full command recovery by decompile alone looks realistic.

## Prior art
None found (no Gadgetbridge/GitHub driver). Greenfield.

## Open questions
- Does the one APK serve both M-1 and M-2, or did M-2 get a separate package
  ("Earin M-2" 1.0.19 per soft112 — likely same package)? A-3 uses a different app.
- Full CAP command list (extract from `CapProtocol.java` constants).
- Whether M-2's NFMI/MiGLO topology exposes one or two BLE peripherals.

## Safety class
LOW — consumer audio earbuds; in-ear volume caution only.
