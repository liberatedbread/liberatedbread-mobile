# Executive summary

This repository coordinates clean-room reverse engineering of IoT companion apps to produce
derived protocol specifications and build alternative, local-first control apps.

Key updates:
- Expanded shortlist includes: PAX (allowed), LEDs2RAVE4/Lunchbox Dream LED family,
  Chef iQ Sense devices, AUTOBABA LED backpack (LOY SPACE ecosystem), and NYAN GEAR ("Nyan BT") controller.
- Added an automated device detection workflow (BLE/Wi-Fi/mDNS/UPnP/OUI/HCI snoop).
- Added scripts for APK fetching/pulling, static analysis at scale, and tmux-based parallel agents.
- Added clean-room rules: no APKs or vendor assets committed; only derived facts/specs.
