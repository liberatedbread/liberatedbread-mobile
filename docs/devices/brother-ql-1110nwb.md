# Brother QL-1110NWB Label Printer

> **Status**: Protocol documented from Brother's own command references + the hardware-tested open implementation (brother_ql); not replayed against hardware here
> **Protocol**: WiFi/LAN (raw raster byte stream on TCP 9100, also LPR 515 / FTP 21) and Bluetooth Classic SPP — no BLE
> **Manufacturer**: Brother Industries
> **Manufacturer Status**: Active (product sold and supported; no cloud dependency anywhere in the print path)

## Overview

The **QL-1110NWB** is Brother's wide-format direct-thermal label printer:
300 dpi, media up to 103.6 mm wide, ~110 mm/s, auto cutter, banners to ~3 m.
It is one of the friendliest printers in this registry to liberate because
there is nothing to liberate: Brother publishes the raster command language
it speaks, every print transport is local and unauthenticated, and the open
[brother_ql](https://github.com/pklaus/brother_ql) package has implemented
it against real hardware for years. A unit cut off from the internet loses
nothing.

The same raster byte stream is accepted over **TCP RAW port 9100**
(Bonjour-advertised as `_pdl-datastream._tcp`), **LPR/LPD 515**, **FTP 21**
(drop a raster file), **Bluetooth Classic SPP**, or **USB**.

!!! note "Bluetooth is Classic, not BLE"
    The radio is BT 2.1+EDR with SPP/BIP/OPP/HCRP/iAP profiles — there is no
    BLE GATT surface at all. The printer advertises a Classic name like
    `QL-1110NWB0000` (last 4 of the serial); pair and open an SPP channel
    (standard UUID `00001101`). Retailer pages claiming "Bluetooth 5.2" are
    aggregator noise. Because no GATT protocol exists, the iPrint&Label APK
    was deliberately not decompiled — it speaks this same documented raster
    stream and would add no protocol facts.

## Hardware

| Property | Value |
|----------|-------|
| Model | QL-1110NWB (siblings: QL-1100 USB-only, QL-1115NWB successor) |
| Print method | Direct thermal, 300 dpi, 1296-dot head (162 bytes/row) |
| Max print width | 101.6 mm (last ~44 head dots on the right do not print) |
| Radio | Wi-Fi 802.11b/g/n + Wireless Direct + WPS; BT Classic 2.1+EDR |
| Other ports | Ethernet 10/100, USB-B device, USB-A host (scanners) |
| Media | DK die-cut and continuous rolls, 12–103.6 mm |

## Command languages

`ESC i a` selects the mode: `00h` ESC/P (text printing), `01h` **raster**
(everything below), `03h` P-touch Template (print templates stored in the
printer, merging host data — see Brother's P-touch Template Command
Reference; useful for a dumb host: push a CSV row, get a label).

## Raster print job

A job is a fixed skeleton of setup commands, one opcode per raster row, and
a print trigger:

```
1B 69 61 01        switch to raster mode
00 × 200           invalidate (clears half-eaten commands; 200 on this model)
1B 40              ESC @ initialize
1B 69 53           (optional) status request
1B 69 7A …         media & quality (10 bytes — see below)
1B 69 4D 40        auto-cut on (bit 6); 1B 69 41 01 → cut every 1 page
1B 69 4B 08        expanded mode, bit 3 = cut at end
1B 69 64 23 00     feed margin, u16 LE dots (35 typical)
4D 02              (optional) PackBits compression on
67 00 A2 <162 bytes>   …one per raster row (5A = all-white row)
1A                 print final page (0C = intermediate page)
```

**`ESC i z` media/quality payload** (10 bytes): valid-flags byte (bit 7
always set; bit 1 media type, bit 2 width, bit 3 length, bit 6 high-quality),
media type (`0x0A` continuous / `0x0B` die-cut), width mm, length mm
(0 = continuous), raster line count u32 LE, page number, `0x00`.

**Raster rows**: 1 bit/pixel, MSB first, 1 = black. The image is mirrored
left-to-right before packing and padded white to 162 bytes. With `4D 02`
compression on, row payloads are PackBits-encoded (the `67 00` framing
stays). Row-count limits on continuous media: 301–35434 dots (~25.5 mm–3 m).

## Status

`ESC i S` (`1B 69 53`) returns a 32-byte reply starting `80 20 42`; `ESC i !`
(`1B 69 21`) toggles unsolicited status pushes. Key offsets:

| Offset | Content |
|--------|---------|
| 8 | Error info 1: bit0 no media, bit1 end of media, bit2 cutter jam, bit4 in use, bit5 off, bit7 fan |
| 9 | Error info 2: bit0 replace media, bit1 expansion buffer full, bit2 comm error, bit4 cover open, bit6 can't feed, bit7 system error |
| 10 | Media width (mm) |
| 11 | Media type: `00` none / `0A` continuous / `0B` die-cut |
| 17 | Media length (mm) |
| 18 | Status type: `00` reply, `01` printing completed, `02` error, `05` notification, `06` phase change |
| 19 | Phase type: `00` waiting to receive, `01` printing |
| 20–21 | Phase number (BE) |
| 22 | Notification number |

Job completion shows up as status type `01` followed by a phase change to
"waiting to receive". On the network, Brother additionally exposes status
via SNMP (`1.3.6.1.4.1.2435.3.3.9.1.6.1.0`, per their developer FAQ) and a
web admin page on port 80.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes — LAN join or BT pairing only; printing itself is account-free |
| Methods | WPS button, Wireless Direct (printer hosts `DIRECT-xxxxx_QL-1110NWB`), USB + Brother Printer Setting Tool, Ethernet/DHCP |
| Bluetooth pairing | Press the printer's BT button, pair `QL-1110NWB<serial4>`, open SPP |
| Confidence | medium (public manual; not replayed) |

**Factory reset** (user-manual ladder): power off → hold **Power + Cutter**
~1 s (Status LED orange, Wi-Fi LED flashing green) → while holding Power,
press **Cutter** **×2** to reset network settings, **×4** for transferred
data + device settings, or **×6** for full factory reset → release Power.

**Rebinding**: re-running WPS or the USB tool moves the printer to a new
network in place; the ×2 network reset is the clean fallback. No reset is
required.

!!! warning "No authentication on any print path"
    Anything that can reach TCP 9100 (or SPP/LPR) can print. Keep the
    printer on a trusted segment.

## References

- [brother_ql (pklaus)](https://github.com/pklaus/brother_ql) — open
  implementation; source of the per-model geometry here
- [Brother Raster Command Reference (QL series)](https://www.jarcomputers.com/images/custom/docs/b471757576aff4ef4eb7f8bd96a113c575133c95_1722315_ql820nwbcyj1_icecat_multimedia_other_digital_assets_2_en_gb-1725017762.pdf) — vendor-authoritative command text
- [Brother developer FAQ — command printing](https://support.brother.com/g/s/es/dev/en/command/faq/index.html?navi=offall) — 9100/LPR/FTP transports, SNMP OID
- [QL-1110NWB user manual — reset procedures](https://www.manualslib.com/manual/1361694/Brother-Ql-1110nwb.html?page=141)
- [Home Assistant Brother integration](https://www.home-assistant.io/integrations/brother/) — HA core; SNMP monitoring covers the QL label-printer family

Machine-readable spec: `device-specs/devices/brother-ql-1110nwb.yaml`
