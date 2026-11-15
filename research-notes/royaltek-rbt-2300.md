# Royaltek RBT-2300 GPS Datalog Receiver — Research Notes

Category: Bluetooth Classic (SPP) GPS receiver + data logger. Covers RBT-2300, RBT-2010, RBT-3000, RBT-3800 (SiRF III family).

## Company / Cloud Status — ALIVE, CONSUMER GPS ABANDONED
- RoyalTek Co. (Taiwan, Quanta group since 2006) is still in business (site live 2026-08) but pivoted to automotive radar/ADAS, AI vision and ODM — consumer Bluetooth GPS products are long gone from the catalog ([royaltek.com](http://www.royaltek.com/), timeline ends consumer-GPS era pre-2015).
- **No cloud dependency** in the device; only the Windows "Data download Utility" (abandonware) for pulling the internal log.

## Companion App
- **No Android or iOS app ever existed.** Windows-only log-download utility ([Microsoft Research-hosted RBT-2300 manual excerpt](https://www.microsoft.com/en-us/research/wp-content/uploads/2017/05/2014080813151459.pdf) documents the "Data download Utility" over the BT COM port).
- Community RE: a freeware **Pocket PC downloader** for RBT-2300/RBT-3800 exists with protocol notes — author reverse-engineered the log-dump after RoyalTek/Cricel declined to document it ([aeropic.free.fr RBT-2300 page](http://aeropic.free.fr/RBT_2300/index_english.html), 2009). It adds multi-dump, GPX-style export, geoid altitude correction. Source availability unclear — treat as partial RE.
- **gpsbabel has NO Royaltek log format** — the logger-download protocol is the one genuinely under-documented piece in this brand survey.

## Transport — Bluetooth Classic SPP
- SPP, Bluetooth 1.2/2.0, UUID `00001101-0000-1000-8000-00805f9b34fb` (SiRF III reference design).
- Pairing PIN: **0000** (standard for the line, per era docs).
- Live position: NMEA 0183 over SPP → gpsd, zero vendor code.

## Protocol
- **Live NMEA**: confirmed standard; works with any generic tool.
- **Log download**: proprietary Royaltek request/response protocol over the same SPP link (the Windows utility and the aeropic PocketPC downloader both drive it). Partially reverse-engineered; no open-source desktop implementation known. Internal flash holds up to ~650,000 points (64 Mbit, per aeropic).
- SiRFstarIII chipset — SiRF binary mode switchable in-band via public `$PSRF100` (as with Globalsat).

## Local Feasibility — PARTIAL / HYPOTHESIS for log retrieval
- Live position: CONFIRMED trivial (NMEA SPP).
- Log download: feasible (protocol is simple serial, partially documented by aeropic; no encryption/auth) but needs a fresh capture or port of the PocketPC tool — flag as greenfield RE, low difficulty.

## Open Questions
- Exact log-dump command/response framing (aeropic page has notes; needs consolidation + HCI/logic capture against a live unit).
- Whether RBT-2010/RBT-3000 share the identical dump protocol (likely — same SiRF III platform generation).

## Sources
- [aeropic.free.fr RBT-2300/RBT-3800 downloader + RE notes](http://aeropic.free.fr/RBT_2300/index_english.html)
- [RBT-2300 manual excerpt (Microsoft Research mirror)](https://www.microsoft.com/en-us/research/wp-content/uploads/2017/05/2014080813151459.pdf)
- [royaltek.com](http://www.royaltek.com/) (company alive, pivoted to radar/ADAS/ODM)
