# LOY / LOYPRO LED Displays

> **Status**: Identify only (advertising evidence; commands untested)
> **Protocol**: BLE, AA55 binary-TLV family
> **Manufacturer**: LOY / YSKJ OEM family

## Why this is a separate candidate

The LOYPRO app (`com.yskj.loypro`) explicitly accepts advertised names
beginning **LOY**. The related LOY PLAY and AUTOBABA/LOY SPACE versions accept
only `YS` and `TL`. A LOY name therefore selects this candidate instead of
AUTOBABA, while remaining silent about the exact model and geometry.

The detailed spec is `device-specs/devices/loypro-led-display.yaml`.

## Evidence and limitations

A 2026-11-07 advertisement from `LOY5265115155` carried that name and
`0000fff0-0000-1000-8000-00805f9b34fb`, with no manufacturer or service-data
record. Later scans did not rediscover it, so GATT enumeration did not
complete. No characteristic read, subscription, write, pairing, reset or
firmware operation was performed.

**FFF0 is not a device type.** LED panels, thermometers, battery monitors,
OBD adapters and treadmills all advertise it. The spec keeps FFF0 in its
GATT service declaration but removes it from scan identity throughout the
catalogue. This prevents a service-only match from activating a dozen
unrelated specs.

The digits in `LOY5265115155` have no documented model or resolution meaning.

## Read-only confirmation path

1. Rediscover the LOY name and connect without relying on a stale address.
2. Enumerate GATT. The expected family layout is FFF2
   write-without-response and FFF1 notify, but the observed unit has not
   confirmed those properties.
3. If that layout exists, subscribe to FFF1 and use the source-derived AA55
   information query in the spec. Do not send it merely to see whether an
   unrelated device responds.
4. A valid reply identifies model/firmware and reports panel width/height
   through TLV `0x0a` and `0x1b`. Stop if no valid AA55 reply arrives; do not
   try another protocol's initialization.

The worked query is 20 bytes with example sequence 1:

```text
aa 55 ff ff 0e 00 01 00 c1 03 0a 00 1b 00 04 00 06 00 ff 03
```

It was not sent during this research. A real client increments its sequence
counter and reassembles replies by the AA55 length field.

## Setup, reset and control boundaries

No account or Wi-Fi provisioning is established. The wider codec has an
optional password capability; if enabled, use the owner's normal app flow
instead of guessing or bypassing it.

No factory reset is established. Do not use a display-format or delete-all
command as an identification probe. Raw-GIF compatibility on another
YS-family backpack is not evidence for this LOY unit. Query panel geometry
before any renderer is enabled.

The spec remains `identify_only` until a read-only information response
establishes the model, firmware and exact dialect. A secondary `5833ff…`
maintenance service seen on other LOY-family hardware must not be assumed
present or used without firmware evidence and a recovery path.

## References

- [LOY / LOYPRO on Google Play](https://play.google.com/store/apps/details?id=com.yskj.loypro)
- [ztrawhcs/yskj-led-sign](https://github.com/ztrawhcs/yskj-led-sign), an
  independent LOY PLAY / YSKJ client tested on another device
- [AUTOBABA protocol relative](autobaba-led-backpack.md), which has a
  different advertised-name filter and must not be selected for LOY
