# Sony PS3 BD Remote (CECH-ZRC1) — Research Notes

## What This Is
Sony's Bluetooth media remote for the PlayStation 3 (CECH-ZRC1 and regional
variants CECHZR1U/E/J; earlier CECHZR1 for launch-era PS3). ~2007–2013.
Product line abandoned with the PS3 (no PS4/PS5 successor — later PlayStation
media remotes are IR/USB-dongle based). Sony as a company is alive; the
product is legacy/abandoned, widely available used for a few dollars.

## Transport
- Bluetooth Classic (BR/EDR), HID profile (HIDP over L2CAP PSM 0x11/0x13).
- NOT BLE. NOT IR. The remote only talks Bluetooth.
- Standard-ish HID, so Linux pairs it as an input device; all 51 buttons
  (incl. PS3-specific color buttons, PS button, eject) arrive as key events.

## Pairing specifics (community-documented)
- No PIN. Pairing dance: hold **Start + Enter on the remote for ~7+ seconds**
  to enter pairing mode, then connect from host.
- On Linux/BlueZ: community script `ps3_pair.py` (Kodi forum, 2013) automates
  pairing; `ps3bluemon`/`ps3remote` daemons map buttons and add a
  configurable idle disconnect to save batteries (the remote never sleeps on
  its own — the classic complaint).
- Known quirk: the remote re-pairs aggressively and can hijack a connection;
  some BlueZ versions need `ClassicBondedOnly=false` or input profile toggles.
- Works fully local on Kodi/OSMC/LibreELEC, Windows (with third-party HID
  mappers), and is documented on ev3dev-era robotics wikis.

## Cloud / App Status
- No cloud, no account, no companion app on any platform. Config lived on the
  PS3 itself (register via Settings → Accessory Settings). Off-console use is
  100% local HID.

## Feasibility
- **Confirmed/trivial.** Mature community support since ~2009; still working
  recipes in 2020 (RESEARCHUT blog) and OSMC forums (2016+). Use as a cheap
  51-button HID macro remote for HTPCs, presentation rigs, robots.

## Sources
- Kodi forum, "Final guide to use the PS3 BD remote on linux" (2013-06-07,
  ps3_pair.py, Start+Enter pairing):
  https://forum.kodi.tv/showthread.php?tid=166676
- RESEARCHUT, "Kodi PS3 BD Remote" (2020-06-16, modern BlueZ notes):
  https://researchut.com/blog/Kodi_PS3_BD_Remote/
- OSMC forums, PS3 BD Remote pairing thread (2016):
  https://discourse.osmc.tv/t/ps3-bd-remote-and-osmc/13178
- ev3dev tutorial (Bluetooth PS3 gamepad/remote pairing pattern):
  https://www.ev3dev.org/docs/tutorials/using-ps3-sixaxis/

## Open Questions
- HID report descriptor / full keycode table is scattered across the old
  ps3remote/ps3bluemon daemons — worth harvesting into a canonical table.
- Battery-drain workaround (auto-disconnect daemon) should be part of any
  spec.

## APK
- None exists. N/A.
