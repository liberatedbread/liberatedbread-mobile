# Android Wireless-ADB Device (identify-only)

> **Status**: Identify-only (discovery signature from AOSP source/docs; untested — no hardware)
> **Protocol**: mDNS / DNS-SD (adb wireless debugging)
> **Manufacturer**: Various (Android 11+)
> **Manufacturer Status**: Active — recognised as an Android device; the debug channel is not opened here

## Overview

Android 11 and later advertise their **Wireless Debugging** (wireless ADB)
endpoint over mDNS/DNS-SD when the user enables it in Developer options. This
app **identifies** the device — draws a phone pictogram — and does nothing else
with it: there is no web UI and no control surface, and the debug channel is
never opened.

## Discovery Summary

- **DNS-SD service types** (published by `adbd`, per AOSP `adb_wifi.md`):
    - `_adb-tls-connect._tcp` — TLS connect server (active while wireless
      debugging is on; connect port is **dynamic**, not a fixed 5555)
    - `_adb-tls-pairing._tcp` — pairing server (only during pairing)
    - `_adb._tcp` — legacy cleartext service (`adb tcpip <port>`)
- **Instance name**: `adb-<ro.serialno>-<random>` (QR pairing uses a
  `studio-` prefix; code pairing a guid prefix). No meaningful TXT data.
- **Stable key**: mDNS hostname. **Display**: advertised instance name.

**No admin_url**: wireless ADB is a debug transport, not a web console.

## References

- <https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/adb_wifi.md>
- <https://developer.android.com/tools/adb>
