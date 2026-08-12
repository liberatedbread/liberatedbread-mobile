# Parrot CK/MKi/Asteroid car kits — Research Notes

## What it is
The classic installed aftermarket hands-free line: CK3000/CK3100 (LCD),
MK6000/MK6100, MKi9000/9100/9200 (music, 2.4" TFT on 9200), 3200LS/3400GPS,
and the Android-based Asteroid head units (Classic/Smart/Mini/Tablet).
All **Bluetooth Classic**, all controlled by standard profiles — HFP, A2DP,
AVRCP, PBAP, MAP — with a wired dash remote, not a companion app.

## Status: abandoned product line, not a cloud
Parrot SA still exists (drones) but exited consumer car kits around 2015-17;
firmware updates stopped (last: CK3000 v5.29c, CK3100 v5.00c, per
justcarkits.co.uk pairing-code reference, updated 2024-03-02). The Asteroid
Market (app store for Asteroid units) is long dead. Crucially, **nothing was
ever cloud-dependent**: pairing and daily use are 100% local standard BT.

## Pairing / config specifics (the part worth documenting)
- PIN `1234` for CK3000/Evo, CK3100/3300/3500 (MKi and Asteroid pair from the
  on-screen menu; SSP-capable).
- Pairing-table limits — kits forget *oldest* phone when full:
  CK3000 x3; CK3100/3300/3500, 3200LS, 3400GPS x5; MK6000/6100,
  MKi9000/9100/9200, Asteroid x10.
- Stuck pairing = full table: delete a phone via voice menu
  ("Settings → Bluetooth → Delete") or factory-reset the kit.
- Firmware update: USB stick (MKi) or Parrot update tool over BT; files were
  on Parrot's (now mostly gone) support CDN — mirrors on archive.org.
- MKi9200 extras: iPod/USB/line-in audio, album art on TFT; music via A2DP
  works with any modern phone.

## Companion app: none
No phone app exists or is needed — this is the "plain classic-BT gear works
with generic tools" case. Any phone/OS with HFP+A2DP drives the kit fully.
APK provenance: N/A.

## Local feasibility: CONFIRMED (trivial)
These units are immune to corporate death by design; the repo value is the
pairing/reset/firmware cheat-sheet above plus profile inventory.

## Open questions
- Asteroid Smart/Tablet (Android 2.3): sideloading/root scene — worth a
  separate note only if someone wants the head unit itself, not just BT.
- Parrot's SPP-based service/diagnostic channel (used by their update tools)
  is undocumented; could expose config without the Windows tool.

## Safety
Hands-free audio only. LOW.
