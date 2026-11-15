# Globalsat BT-338 / BT-359 GPS Receivers — Research Notes

Category: Bluetooth Classic (SPP) GPS receivers (live position only, no logging). Covers BT-338, BT-359, BT-359W, BT-821, BC-337 (CompactFlash sibling), SD-502.

## Company / Cloud Status — ALIVE, PRODUCTS LONG DISCONTINUED
- GlobalSat WorldCom Corp. (Taiwan) is still in business (site live 2026-08) but pivoted to LoRa/IoT/trackers/mmWave — consumer Bluetooth GPS receivers left the catalog a decade ago ([globalsat.com.tw](https://www.globalsat.com.tw/en/)).
- **No cloud dependency whatsoever** — these are dumb NMEA emitters; there was never an account, app, or service to shut down. This is the "just works with generic tools" archetype.

## Companion App
- **None ever existed** (any platform). Era software was generic PDA navigation (TomTom Navigator etc.) talking NMEA over a COM port. Nothing to reverse-engineer; nothing fetchable/needed.

## Transport — Bluetooth Classic SPP
- SPP, Bluetooth 1.2/2.0, UUID `00001101-0000-1000-8000-00805f9b34fb` ([BT-338 datasheet](https://easygo.fi/bt338b_ds_ug.pdf)).
- Pairing PIN: **0000** — explicit in the [BT-359 FCC user manual](https://fcc.report/FCC-ID/RID-BT359/664057.pdf) ("Bluetooth Default PIN 0000").
- Usage: `rfcomm bind /dev/rfcomm0 <MAC>` → `gpsd -N rfcomm0:` — done. No config needed for NMEA mode.

## Protocol
- SiRFstarIII chipset; boots into **NMEA 0183** mode (GGA/GSA/GSV/RMC at 1 Hz) streamed over SPP. gpsd autodetects.
- Optional **SiRF binary** mode: switchable in-band with the standard SiRF `$PSRF100` NMEA sentence / SiRF binary message 129 — the same well-documented public SiRF mechanism gpsd's `gpsctl`/sirf mode uses. No proprietary Globalsat layer at all.
- BT-338 review-era cross-platform support (Windows/Mac/Palm/PocketPC/Symbian) documented by [cdrinfo (2006)](https://www.cdrinfo.com/d7/content/globalsat-bt-338-sd-502-and-bc-337?page=1) and [Geekzone (2005)](https://www.geekzone.co.nz/content.asp?contentid=4551).

## Related Globalsat Products (out of scope here, noted for completeness)
- **BT-335 / DG-100 / DG-200 loggers**: supported by gpsbabel (`dg-100`/`dg-200` formats) — USB-serial; BT-335 also SPP.
- **GH-615/GH-625 sport watches**: proprietary protocol over USB/BT; community tools (gh600-era scripts) exist but bit-rotted — hypothesis, needs capture to document properly.

## Local Feasibility — CONFIRMED (trivially)
Pure NMEA-over-SPP; works with any generic tool. The only decay risk is physical (aged Li-ion cells) and modern OS SPP pairing UX, not protocol lock-in.

## Open Questions
- None material. If SiRF binary mode is wanted, verify `$PSRF100` switch behavior per firmware revision.

## Sources
- [BT-359 FCC user manual (PIN 0000)](https://fcc.report/FCC-ID/RID-BT359/664057.pdf)
- [BT-338 datasheet/user guide](https://easygo.fi/bt338b_ds_ug.pdf)
- [cdrinfo BT-338 review](https://www.cdrinfo.com/d7/content/globalsat-bt-338-sd-502-and-bc-337?page=1)
- [globalsat.com.tw](https://www.globalsat.com.tw/en/) (company alive, pivoted)
