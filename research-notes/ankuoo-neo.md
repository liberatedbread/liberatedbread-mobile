# Ankuoo NEO Wi-Fi Switch/Plug — Research Notes

## What it is
Ankuoo NEO Wi-Fi light switch (in-wall) and NEO plug (~2014-2016), controlled
by the NEO app. Hardware is a **Broadlink SP1-variant** OEM build (NEO Power =
Broadlink SP2 with metering; FCC filings trace to Lumi Legend Electrical).
The Ankuoo brand is dormant; the newer "REC" line (MS6126, CSW201) is a
different device with an openly documented API and its own HA integration
(`recswitch`) — do not confuse the two.

## Local protocol — confirmed (community RE)
Reverse-engineering notes: [Diagonactic/Ankuoo](https://github.com/Diagonactic/Ankuoo)
(packet captures + field breakdown). Key facts:

- **UDP** for both LAN and cloud traffic; device-facing ports 80 and 8080
  (UDP), plus heartbeat traffic to `us.broadlink.com.cn` /
  `eu.broadlink.com.cn` and hard-coded IPs (112.124.42.42:80,
  112.124.35.104:8080).
- **Packet layout**: every LAN command starts with a fixed 32-byte key block
  `5aa5aa55 5aa5aa55` (repeated pattern over 32 bytes), then a 32-bit
  little-endian timestamp/counter, a device-type field (`0x2717` = NEO
  switch/plug family), and the device MAC in little-endian order.
- App and device both double-send every packet (UDP loss workaround); devices
  respond fine to a single send.
- Power on/off and schedule/anti-theft features are all carried in these LAN
  packets — the cloud hosts are only used for remote access and time sync.

## Cloud dependency
None required for control on the LAN: the NEO app talks directly to the
device with the packets above, and blocking the Broadlink cloud hosts (or DNS
sinking them) does not break local control. Initial Wi-Fi provisioning is the
Broadlink-style app flow; cloud account optional for local use.

## Caveats / open questions
- No maintained multi-language library — the RE notes + wire format are the
  documentation. Building a spec from Diagonactic's notes is straightforward.
- NEO Power (SP2-variant) adds metering fields not covered in those notes.
- The REC line (MS6126 etc.) has a documented open LAN API and HA support —
  a better buy today, but a different protocol.

## APK
Not fetched — the NEO app is long abandoned; protocol captured from live
traffic in the RE notes above. APK triage could recover the schedule/anti-theft
packet formats if ever needed.

## Safety
LOW. Mains switching; protocol is unauthenticated cleartext UDP — anyone on
the LAN can toggle loads. LAN-segment.
