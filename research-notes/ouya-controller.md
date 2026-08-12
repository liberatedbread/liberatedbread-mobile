# OUYA Controller — Research Notes

Date: 2026-08-04. Category: Bluetooth Classic game controllers (HID).

## Product
OUYA wireless controller (2013) for the OUYA Android microconsole: 15 buttons,
2 analog sticks, 2 analog triggers, and a small touchpad. Bluetooth Classic HID.
Also sold standalone; common in used markets.

## Company / cloud status
- OUYA Inc. sold its software/storefront to Razer in July 2015 (Ars Technica).
- Razer shut down all OUYA/Forge TV/Cortex services on **2019-06-25** (CNET
  2019-05-22, KitGuru 2019-05-23). Console accounts, store and game entitlements died.
- The **controller itself never touched the cloud** — it is a peripheral. The dead
  part is the console storefront; community kept the console alive via custom
  firmware / replacement servers (s-config.com, cweiske.de).

## Local feasibility verdict: CONFIRMED — plain HID gamepad
- Pairs as a standard BT Classic HID gamepad with Android, Windows, Linux, macOS.
- Pairing: hold the OUYA "U" system button until only two player LEDs flash
  (PCGamingWiki Controller:OUYA page).
- Touchpad enumerates as a mouse.
- Works in RetroArch, Steam, browsers (Gamepad API), etc. with no vendor software.
- No companion phone app ever existed — nothing to archive.

## Caveats / quirks
- Some modern Android versions (12+) have BT HID auto-pairing quirks with the
  OUYA controller; pairing from system settings (not in-app) works around it.
- On the OUYA console itself, pre-shutdown firmware wanted account sign-in; that is
  a console problem, not a controller problem. Community LineageOS images remove it.
- Controller requires AA batteries; no rechargeable pack (later "black" revision
  improved latency/RF).

## Open questions
- HID descriptor quirks (report IDs for touchpad vs gamepad) — undocumented here;
  trivial to dump with `usbhid-dump`-equivalent (`bt hidp` capture) if a spec is built.
- Firmware differences between silver (launch) and black (2014 refresh) controllers.

## Sources
- cnet.com/tech/gaming/razer-will-pull-the-plug-on-ouya-gaming-console-on-june-25/ (2019-05-22)
- kitguru.net — "Razer is shutting down Ouya" (2019-05-23)
- pcgamingwiki.com/wiki/Controller:OUYA — pairing instructions, layout
- s-config.com/linux-adb-raspberry-pi-ouya-lineage-really/ (2024) — post-shutdown console life
- arstechnica.com (2015-07) — Razer acquires OUYA software/team
