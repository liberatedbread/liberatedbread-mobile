# Electric Unicycles (WheelLog)

> **Status**: Spec Available (unverified) — active brands; community-decoded frames
> **Protocol**: BLE
> **Manufacturer**: King Song, Gotway/Begode, Veteran/Leaperkim (community-decoded)
> **Manufacturer Status**: Active

## Overview

Electric unicycles from King Song, Gotway/Begode and Veteran/Leaperkim, decoded by the open-source WheelLog app. Each is a notify-stream of framed packets; brand is detected from the first packets. Fully local BLE. (The BLE serial characteristic UUID is module-specific and not asserted here.)

## Protocol Summary

King Song: 20-byte frame, header AA 55, type at byte 16 (0xA9 live data). Gotway/Begode: 24-byte frame, header 55 AA, footer 5A5A5A5A, type at byte 18. Veteran: header DC 5A 5C + length, CRC32 on longer frames.

See `device-specs/devices/euc-wheellog-ble.yaml` for the full machine-readable spec.

## References

- <https://github.com/Wheellog/Wheellog.Android>
