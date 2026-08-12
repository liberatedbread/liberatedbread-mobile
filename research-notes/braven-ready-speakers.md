# Braven BRV "Ready" speakers (Ready Elite / Active / Prime) — Research Notes

Date researched: 2026-08-03. Researcher: BT-Classic audio swarm.

## Verdict
**CONFIRMED viable, GAIA-based.** Braven's "Ready" outdoor speakers (2020–21)
are CSR/Qualcomm GAIA devices controlled over Bluetooth Classic RFCOMM. The
companion app is fetched and decompiled; it speaks GAIA (both the dedicated
GAIA SDP UUID and standard SPP fallback), does speaker rename and GAIA
VM-upgrade DFU locally. Brand is dead; no cloud dependency in the app beyond
social-marketing tabs.

## Cloud / company status
- Braven (founded 2012) → Incipio Group → **sold to ZAGG in 2019**; ZAGG then
  **discontinued the Braven brand** (products gone from zagg.com; legacy
  support via ZAGG Care). Sources: [SGB Media on the sale](https://sgbonline.com/incipio-sells-braven-to-zagg/),
  ["What Happened to Braven Speakers" (2024)](https://bestsounds.net/what-happened-to-braven-speakers/),
  [ZAGG Care Braven pairing article](https://support.zagg.com/hc/en-us/articles/360024868571-How-do-I-pair-my-BRAVEN-speaker).
- ZAGG itself was taken private (2021) and has been shedding brands; the app
  (`com.braven.bravenoutdoor`, v1.0.4, last Play-era build) is abandonware.

## Companion app / APK provenance
- **Package**: `com.braven.bravenoutdoor` ("BRAVEN Ready Outdoor Speaker")
- **Version**: 1.0.4 (versionCode 5)
- **Source**: apkeep, apk-pure
- **APK SHA-256**: `ff3fa88fda567e69775efcd41a08f14065562004c150607bb504f490efa441d6`
- **Decompiled**: jadx → `$REPO/workspace/static/braven/` (clean Java, unobfuscated)

## Transport (from static analysis)
- Bluetooth Classic RFCOMM. `com.braven.gaia.library.GaiaLink` connects via:
  - GAIA SDP UUID `00001107-d102-11e1-9b23-00025b00a5a5` (primary)
  - standard SPP UUID `00001101-0000-1000-8000-00805f9b34fb` (fallback)
- SoC: CSR86xx-class (ships `vmupgradelibrary` = GAIA VM-upgrade DFU).

## App feature surface (local)
- Speaker settings (`SpeakerFragment`), **rename speaker** (`ChangeNameDialog`),
  EQ / audio control per Play listing, remote power-off / Smart Lock per ZAGG
  manual, **firmware update** (`UpdateVMFragment` + vmupgradelibrary, DFU over
  GAIA — firmware images may have been fetched from now-dead servers).
- Social-media tabs (Twitter/Facebook/Instagram) are dead weight, ignorable.

## Protocol
- Standard GAIA framing applies — see `qualcomm-gaia-audio-ecosystem` note
  (SOF 0xFF, version, flags, len, vendor 0x000A, command id, payload, optional
  checksum). Braven-specific command IDs live in
  `com.braven.gaia.library` — worth one focused pass to extract the EQ/rename/
  power command table.

## Next steps
1. Extract Braven GAIA command IDs from `com.braven.gaia.library` (triage found
   the transport; command table not yet mapped).
2. Confirm a GAIA UUID appears in SDP records of a real BRV Ready unit.
3. Archive note: if DFU images were server-hosted, firmware updates are gone —
   settings control is unaffected.
- safety_class: LOW.

## Open questions
- Exact Ready-series models the app supports (Ready Elite confirmed by ZAGG manual).
- Whether older Braven (BRV-X/XXL etc., pre-Ready) expose any app control —
  believed none (no app predates the Ready app).
