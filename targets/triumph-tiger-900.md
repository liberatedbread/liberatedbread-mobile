# Triumph Tiger 900 target spec

## Target metadata
- target_id: triumph-tiger-900
- app package_id(s): com.tuneecu_lite (free "diagnosis and test" build), com.tuneecu
  (paid full app, Alain Fontaine). TigerTool and DealerTool are Windows-only.
- device class: motorcycle ECU / instrument cluster diagnostics
- transport(s): OBD-II connector, ISO 15765-4 (CAN); Bluetooth SPP between phone app and OBD adapter
- local-only viability: high -- the diagnostic bus is entirely local; the gate is a closed
  application-layer message plus tool licensing, not a cloud dependency

## Known facts (public + observed)
- Tiger 900 (2020-2023) uses a SAE J1962 16-pin diagnostic connector under the pillion
  seat; Gen 2 (MY2024+) moved to the 6-pin ISO 19689 Euro 5 connector (red).
- TigerTool documents its ECU families as ISO 9141-2 + ISO 15765-4 for Mk1 Tiger 800-era
  ECUs, and "primarily ISO15765-4 (aka CAN bus)" for later ECUs. Tiger 900 is the latter.
- Third-party tools reach the ECU through an ordinary ELM327-class adapter, but the
  service interval reset specifically requires an OBDLink LX/MX (STN chipset) on many
  Triumph models while DTC reads work on anything.
- The service reminder has two parts: a distance component reset over diagnostics, and a
  calendar date component reset from the bike's own instrument menu on newer models.
- Odometer and service values are stored in the instrument cluster in kilometres.
- Interval granularity is 100 units; Tiger 900 maximum is 6000 miles / 10000 km.
- The wrench reappears 500 miles / 800 km before the service-due distance.
- A failed reset can lock out further diagnostic functions until the tool reconnects.
- TuneECU requires the bike's clock/date to be set before running the reset.
- TigerTool does not connect to Gen 2 (MY2024+) bikes -- Triumph relocated ECU data.
- TuneECU ships two Android builds: `com.tuneecu` (paid) and `com.tuneecu_lite` (free,
  "diagnosis and test of the ECU", no remapping). The Lite build is the clean
  static-analysis lead: it is distributed free, and diagnosis/test is exactly the code
  path that carries the Triumph dialect.
- TuneECU Lite's own listing states clone ELM327 v2.1 adapters do not work and a genuine
  v1.4/1.5 is required -- independent corroboration that the vendor traffic depends on
  correct adapter behaviour rather than on anything exotic in the bike.
- The Windows TuneECU (freeware, ISO 9141-era Triumph ECUs) is discontinued and no longer
  distributed by the author; support is Android-only.
- TuneECU's published documentation is UI-level only. The official Android description PDF
  is a scanned image with no text layer, and the online guide covers adapters and model
  support without any message-level detail. The bytes are in the app, not the manual.

## Device discovery signals
- OBD / CAN:
  - connector: SAE J1962 (2020-2023) / ISO 19689 6-pin (MY2024+), under the pillion seat
  - instrument cluster: 11-bit CAN 500 kbit/s, request 0x701 -> response 0x704
  - immobiliser/TPMS: 11-bit CAN, request 0x604 -> response 0x602, broadcast 0x600
  - engine ECU: 29-bit CAN, 18 DA D5 F1 -> 18 DA F1 D5, functional 18 DB 33 F1
  - ABS + ECU ping: K-line, KWP2000 header 68 6A F1, ISO init address 0x43
  - NOT 0x7E0/0x7E8 -- the standard OBD-II physical addresses are not where the
    owner-facing functions live
- Bluetooth (tool side, not the bike):
  - OBDLink LX/MX adapter, RFCOMM/SPP, ASCII ELM327 command set

## Threat model + guardrails
- Scope: a bike the owner has consented to work on, stationary, engine off, ignition on.
  Repair-café use is the point -- the service reset is a write and is meant to be used.
- Record current values before writing; a read-back is one command.
- ABS bleed is a brake procedure that happens to be triggered over the connector. Follow
  the service manual and check lever feel before the bike leaves.
- Non-goals: ECU flashing, remapping, immobiliser defeat, odometer alteration.
- Goal: document the service interval reset so an owner or a volunteer who has done the
  service can clear the reminder without a dealer visit or a paid tool.

## First experiments (do these first)
0) DONE -- static analysis of TigerTool V3.51 (freeware Windows binary) recovered the
   reset message and most of the surrounding surface; see Protocol findings below.
0b) DONE -- TuneECU 23 decompiled from the author's own distribution URL
   (https://tuneecu.fr/update/23/TuneECU.apk); confirmed the reset command and widened the
   stack map. Original plan retained below for reference. Run
   `scripts/run_static_target.sh triumph-tiger-900` and grep the decompile for:
   - ELM327 setup strings: `ATSP`, `ATSH`, `ATCRA`, `ATFC`, `ATCAF`
   - service bytes and their positive responses: `31 01`/`71`, `2E`/`6E`, `22`/`62`,
     `10 03`/`50`, `27 01`/`67`, `3B`/`7B`
   - resource strings around the adjustments UI: "Reset", "Service", "Interval", "SIA",
     "Validate", plus the km/miles selector
   - byte-array literals near those strings, and any per-model table keyed on ECU id
   Analyse `com.tuneecu` (paid) only from a copy the researcher owns.
1) btsnoop HCI capture of a vendor Android tool performing one service reset against an
   owned bike; the ELM327 protocol is ASCII so the request appears in clear text in the
   RFCOMM stream. This confirms whatever the decompile suggests.
2) Passive CAN log at the diagnostic connector (`candump -L can0`) across the same
   operation; diff idle traffic against reset traffic.
3) Read-only UDS DID sweep with `scripts/obd_discover.py` to map which identifiers hold
   the odometer, the service-due distance and the service date.
4) Determine whether the service data is owned by the engine ECU or the instrument
   cluster, and whether the cluster has its own diagnostic address.

## Protocol findings (TigerTool V3.51 static analysis)
All four earlier hypotheses were wrong in an instructive way: the reset is not UDS, and it
does not target the engine ECU at all.

- Reset service interval: `33 <km/100>` or `34 <miles/100>` on CAN 0x701 (instrument
  cluster), success reply `704 B3` / `704 B4`. No diagnostic session, no security access.
  The value is divided by 100 -- which is exactly why every tool UI restricts intervals to
  multiples of 100. Confirmed independently in TuneECU 23:
  `rb = (i15 == 0 ? "33" : "34").concat(String.format("%02x", .../100))`.
- Every reply on the cluster stack is the request opcode with bit 7 set.
- Reset service date: `5C <x> <hi> <lo>` -> `704 DC`. Date word is incremented and split
  high/low; epoch and the third byte still undecoded.
- SIA/odometer reads: `0D 01` -> `704 8D 01 ...`, then `47 01`, `5E 01`, `6E 76`, `6E 74`.
  Reply field layouts NOT yet decoded -- highest-value remaining work.
- Instrument menu: `30 00`/`30 06` ODO units -> `B0`, `31 00`/`31 01` TPMS menu -> `B1`,
  `32 00`/`32 01` ABS menu -> `B2`, plus `40 xx` -> `C0` and `41 xx` -> `C1` (TuneECU only).
- Cluster stack setup: AT TP6, AT E0, AT H1, AT L0, AT CFC0, AT CAF0, AT SH701, AT CRA704,
  AT ST7F. Auto-formatting and flow control OFF -- raw frames, no ISO-TP on this stack.
- Engine ECU is UDS over 29-bit CAN: header 18 DA D5 F1, replies 18 DA F1 D5, functional
  18 DB 33 F1. DIDs F190 VIN, F18C serial, F1A0/F1A7 tune, F1AE tune count, F1A2 cal/build,
  F199 tune date. DTCs via 19 01 08 / 19 02 08, clear via 14 FF FF FF.
- ABS is KWP2000 over K-line: header 68 6A F1, ISO init address 0x43 (AT IIA43). A0
  identity, 13 40 FF read DTCs, 14 00 00 clear, A1 01 FF / A1 B0 FF / A1 01 00 bleed.
- Immobiliser/TPMS on CAN 0x604 -> 0x602, live broadcast on 0x600 (AT CRA600 + AT MA).
- SecurityAccess 27 03 / 27 04 exists but gates throttle balance, not the service reset.
- Additional nodes seen only in TuneECU: engine-side ECUs 0xC1 and 0xC8 (29-bit, probed
  with UDS `10 03`), a node at 0x780/0x781, standard OBD-II 0x7E0/0x7E8, ISO 9141 headers
  8010F1/8011F1/8101F1/8111F1/81D5F5, and ISO init address 0xD5 alongside the ABS 0x43.
- TuneECU uses the ELM327 user-defined protocol (`ATPB0101`/`ATPBE101` + `ATSPB`) for some
  stacks -- another thing clone firmware will not do.
- Model-year split: all of the above is 2020-2023 only. TigerTool does not connect to Gen 2
  (MY2024+), so that variant still needs its own capture.

## Still open
- Field layouts of the SIA query replies (odometer, distance-to-service, date).
- The `5C` date-reset epoch and its third byte.
- What the `40 xx` / `41 xx` instrument options control.
- Immobiliser/TPMS opcode space beyond the handful TigerTool uses.
- Whether these opcodes are shared across Triumph's wider range (cross-check TuneECU).
- Everything about MY2024+ Gen 2.

## Control surface inventory (what the replacement app must support)
- Adapter connect + protocol selection (ISO 15765-4, 11-bit, 500 kbit/s)
- Read odometer, current service interval, service-due distance and date
- Set service interval (100-unit granularity, clamped to the model maximum)
- Execute the reset and confirm by read-back
- Read and clear DTCs (already possible with generic tools)
- Clear error reporting when the ECU refuses (map UDS NRCs to plain language)

## Evidence checklist
- TigerTool V3.51 SHA-256 3c7270ef1bf0ab1f70920dc60baf48883907079fbeecc620e77eb08cd07b3d79: DONE
- Hardware confirmation of `33 <km/100>` with read-back: pending
- TuneECU 23 APK SHA-256 f724294669a3bc008d81dbb590a8c0bfa1b4ac4a223d524e040c85bc885408eb: DONE
- Cross-tool agreement on the reset command (TigerTool + TuneECU): DONE
- btsnoop HCI log of a vendor tool reset: pending
- CAN capture (candump / SavvyCAN) of the same operation: pending
- DID sweep output: pending
- Read-back proof that the dash value changed: pending

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/triumph-tiger-900.md
- device-specs/devices/triumph-tiger-900.yaml

## References (URLs only)
- https://www.bmdiag.co.uk/user/tiger%20tool/TigerTool%20V3.0%20Instructions.pdf
- https://tuneecu.fr/docs/_en/Basic_guide.html
- https://www.tiger800.co.uk/index.php?topic=32836.0
- https://www.tiger800.co.uk/index.php?topic=27014.0
- https://www.iso.org/standard/66030.html
- https://www.healtech-electronics.com/products/mm/
- https://www.triumph675.net/threads/ecu-to-dash-can-bus-message-ids.242889/
