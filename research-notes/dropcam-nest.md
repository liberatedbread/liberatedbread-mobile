# Dropcam / Nest Cam (pre-Google-Home era) — DUD: verified cloud-locked, rejected

## Verdict
**Rejected.** No local protocol exists. Dropcam HD, Dropcam Pro, and the
first-gen Nest Cam Indoor/Outdoor stream exclusively through the Google/Nest
cloud — no RTSP, no ONVIF, no local HTTP API, no documented LAN surface.
SmartThings community (2016-07): "There is no local access to the Nest at
all, the only integration even with 3rd party apps is via the Google cloud."

## Kill date
Google ended all support on **2024-04-08** (announced 2023-04-07): Dropcam
and Nest Secure stopped working as networked devices; Nest-app access was
withdrawn. Units are now e-waste unless hardware-hacked — there is no
firmware path to local streaming. (Slashdot/PaidContent report 2023-04-07;
PCWorld "left for dead" list 2025-02; LightNOW recap 2026-02.)

## Newer Nest Cams — same answer
Google Home-era Nest Cams (2021+) use WebRTC via the cloud-mediated SDM
API; there is still no documented local third-party protocol. Local
streaming exists only to first-party surfaces (Nest Hub) and via the
proprietary Starling Home Bridge (HomeKit bridge appliance — their own
reverse engineering, not a documented local API on the camera).

## Why no APK triage
The Nest/Google Home apps contain no local protocol to extract — pairing and
streaming are cloud-relayed by design. MITM-of-cloud is out of scope for
this repo, so the lead ends here.

## Sources
- Slashdot (2023-04-07): Google ending Dropcam/Nest Secure support 2024-04-08
- PCWorld (2025-02-10): "10 killer smart home gadgets that were left for dead"
- LightNOW (2026-02-07): Dropcam cloud support ended 2024-04-08
- SmartThings community (2016-07-14): no local access to Nest cam at all
- Starling Home support doc (2024-07): local streaming only via their bridge
