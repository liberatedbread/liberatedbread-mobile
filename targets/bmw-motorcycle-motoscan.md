# BMW motorcycle diagnostics (MotoScan) target spec

## Target metadata
- target_id: bmw-motorcycle-motoscan
- app package_id(s): de.wgsoft.motoscan (MotoScan for BMW Motorcycles, WGSoft.de)
- device class: motorcycle ECU / cluster diagnostics
- transport(s): OBD-II connector; BMW KWP2000, KWP2000*, D-CAN and UDS
- local-only viability: high -- the diagnostic bus is local and the adapter command set is
  ELM327-compatible. The gate is a paid app plus closed BMW application-layer messages.

## Why this target
The Triumph work (see `targets/triumph-tiger-900.md`) showed that a motorcycle service
interval reset is a short proprietary frame to the instrument cluster, recoverable from the
tools that already speak it. BMW is the same shape of problem with a different vendor, and
MotoScan is the tool that covers it.

There is a useful structural detail here: **MotoScan and the UniCarScan UCSI-2100 adapter
come from the same vendor, WGSoft.de.** The adapter's headline feature is accepting
messages up to 255 bytes where a stock ELM327 stops at 8 — that is not a general-purpose
selling point, it is what BMW's protocols need. The adapter tells you something about the
protocol before the app is even opened.

## Known facts (public)
- Package `de.wgsoft.motoscan`, Android 6.0+, vendor WGSoft.de (motoscan.de).
- Covers BMW C-, F-, G-, K- and R-series motorcycles.
- Functions: live data, fault-code read and clear, ECU coding, **service interval reset**,
  adaptations and actuator tests.
- Supported adapters: OBDLink LX/MX, UniCarScan UCSI-2000/2100, and ELM327 "with
  restrictions" -- the same tiering seen across every vendor tool in this repo.
- Protocols, from the UCSI-2100's own specification: BMW KWP2000, KWP2000*, D-CAN, UDS,
  alongside the legislated ISO9141-2, KWP2000 slow/fast init and CAN 11/29-bit at 250 and
  500 kbit/s.
- Distribution is Google Play only -- unlike TuneECU, the vendor publishes no direct APK.
  A Lite build exists for testing before purchase.

## Acquisition status
DONE. `apkeep -a de.wgsoft.motoscan -d apk-pure` succeeded where the mirror websites are
Cloudflare-blocked -- apkeep uses APKPure's API rather than the site. SHA-256
21b590cb76641731bc448cd992114c5f2b83cc38eb87f8811b91aaf51d2c9055, 36.5 MB.

Signature verified before analysis: `C = DE, ST = NRW, L = Buende, O = WGSoft.de,
CN = Wladimir Gurskij` -- the genuine vendor build, not a repack. MotoScan is a free
download with the full feature set behind an in-app purchase, so no cracked build is
needed; MOD/crack mirrors were deliberately not used, since a patched binary cannot be
told apart from vendor behaviour for protocol work.

## Findings so far (from the shipped app)
- Addressing is BMW's 6F1 scheme: tester transmits on CAN 0x6F1 with the target ECU
  address as the first payload byte via CAN extended addressing (ATCEA); each ECU replies
  on 0x600 + address. Uniform across modules, unlike Triumph's four bespoke stacks.
- Init, with <aa> = target address: ATSPB, ATPBC101, ATSH6F1, ATFCSH6F1,
  ATFCSD<aa>300008, ATFCSM1, ATCEA<aa>, ATCM7FF, ATCF6<aa>, ATST90, ATBI, then
  STCSEGT1 / STCFCPC on STN adapters.
- Service reset scopes: SI_ALL, SI_DATE, SI_MILEAGE, SI_DATE_CAR -- the same distance/date
  split found on the Tiger 900, so that looks like an industry pattern not a Triumph quirk.
- Service data identifiers: STAT_SERVICE_KMSTAND_DATA, STAT_SERVICE_DATUM_DATA,
  STAT_SERVICE_JAHR/MONAT/TAG_WERT, plus a SEPARATE valve-clearance service with
  STAT_VENTILSPIELSERVICE_RESTWEG_WERT and an ANZAHL_RESET counter.
- Modules seen: KOMBI (cluster -- owns service data), ZFE, BMS, ABS, RDC, DWA, ILAF.
- MotoScan ships its own adapter enum including ELM327_CLONE vs ELM327_ORIGINAL, plus
  OBDLINK_LX/MX/MX_PLUS/MX_WIFI and UCSI_2000 ("UCSI-2000/2100"). A tool shipping clone
  detection is strong third-party support for this repo's adapter capability tiers.

## Next experiments
0) DONE -- the frames were NOT in libmotoscan-helper.so. That library is the ECU
   description database (3.7 MB .rodata vs 1.8 MB .text, string-in/string-out JNI); the
   wire protocol is built in Kotlin. Service reset is UDS WriteDataByIdentifier on BMW's
   0xE1xx DIDs: 2E E1 2B (clock), 2E E1 2C (service date), 2E E1 2D (service distance,
   plain uint16 km), with matching reads 22 E1 19/2B/2C/2D, payload at offset 3.
1) Enumerate the module addresses (<aa>). Not published, so scan: the 6F1 scheme reaches
   every module identically, so `scripts/obd_discover.py --bmw-scan 0x00-0x7F` asks each
   address for the VIN DID and reports anything that answers, positively or with an NRC.
   NOTE: the VIN-DID probe is an assumption -- some module families may need a different
   liveness request. First run on a bike settles it, and the scan is read-only.
2) Read KOMBI.prg instead. The result names are SGBD names, so a licensed
   EDIABAS/INPA/ISTA installation already defines the module address, scaling and DTC
   text authoritatively -- faster than another capture. See `obd.description_files` in
   the spec for where to record which file answered what.
3) Confirm on hardware with read-back of 22 E1 2D.
4) Decode the 31 FA <routine> <sub> family -- frames recorded, semantics unknown. 31
   executes things, so these are not to be guessed at against a vehicle.
5) Compare against the Triumph map -- both vendors put service data in the cluster and
   split it distance/date; whether the resemblance goes deeper is worth knowing.

## Protocol hypotheses (to validate)
- BMW's D-CAN is ISO 15765-4 with BMW addressing; KWP2000* is a BMW variant of KWP2000
  over K-line. Both are named by the adapter vendor, so both are in play depending on
  model year.
- Long-message support (255 bytes) implies coding/adaptation writes that exceed a single
  ISO-TP frame, i.e. real multi-frame transmit rather than the two-byte frames Triumph's
  cluster uses.
- ECU coding implies SecurityAccess (`27`) somewhere in the stack. Not yet located -- the
  service DIDs need no session and no security access.
- SETTLED: the service reset is a value write (2E) on manufacturer DIDs in the cluster,
  not a routine. Note this is the opposite of the Triumph result, where the same
  hypothesis was wrong -- convention predicts nothing; the capture decides.

## Threat model + guardrails
- Scope: a bike the owner has consented to work on, stationary, engine off. Repair-café
  use is the point -- the service reset is a write and is meant to be used.
- Record current values before writing (22 E1 19 / 2B / 2C / 2D are one command each).
- ECU coding, flashing and immobiliser/key work are IN scope and flagged `advanced`:
  a salvaged module has to be coded to the bike before it works. Dump the existing coding
  first and know what rewrites it.
- Non-goals: falsifying a recorded odometer, and anything on a moving vehicle.

## Control surface inventory (what a replacement would need)
- Adapter connect and protocol selection across KWP2000 / D-CAN / UDS
- Read fault codes and live data
- Read service interval and odometer state
- Reset the service interval, with read-back confirmation

## Evidence checklist
- MotoScan APK SHA-256 21b590cb76641731bc448cd992114c5f2b83cc38eb87f8811b91aaf51d2c9055: DONE
- Vendor signature verified (WGSoft.de / Wladimir Gurskij): DONE
- Decompiled init sequences and addressing scheme (BMW 0x6F1 + ATCEA): DONE
- Service interval data model (SI_ALL/SI_DATE/SI_MILEAGE/SI_DATE_CAR): DONE
- ARM64 native library structure analysed (stripped, 3.7 MB .rodata vs 1.8 MB .text,
  string-in/string-out JNI surface -- it holds the ECU description database, not the
  wire protocol): DONE
- Service reset command bytes (2E E1 2B/2C/2D) and matching reads (22 E1 19/2B/2C/2D): DONE
- Module address (<aa>) enumeration and 31 FA routine semantics: pending
- Hardware confirmation with read-back: pending

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/bmw-motorcycle-diagnostics.md
- device-specs/devices/bmw-motorcycle-diagnostics.yaml

## References (URLs only)
- https://www.motoscan.de/
- https://play.google.com/store/apps/details?id=de.wgsoft.motoscan
- https://www.wgsoft.de/unicarscan-ucsi-2100
