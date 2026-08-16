# Synology DiskStation NAS (identify-only)

> **Status**: Identify-only (discovery signature from public reverse-engineering; untested — no hardware)
> **Protocol**: findhostd (UDP 9999) — Synology Assistant discovery
> **Manufacturer**: Synology Inc.
> **Manufacturer Status**: Active — recognised and linked to DSM, not driven here

## Overview

Synology DiskStation/RackStation NAS units run DSM and are found on the local
segment by Synology Assistant and the web-based `find.synology.com` finder,
which talk to the on-device **findhostd** service over UDP 9999. This app
**identifies** the NAS — shows a NAS pictogram and deep-links to DSM — rather
than driving DSM (its web UI and APIs are fully capable and out of scope as home
infrastructure).

## Discovery Summary

- **findhostd**, UDP 9999 (also 9997/9998). Synology Assistant sends a
  broadcast query; findhostd answers with a broadcast + a unicast reply.
- Packet framing begins with an 8-byte magic ending in ASCII **`SYNO`**
  (`53 59 4E 4F`): plaintext `12 34 56 78 53 59 4E 4F`, encrypted
  `12 34 55 66 53 59 4E 4F`. This magic is Synology-specific, so a reply
  carrying it is an unambiguous identification.
- Payload after the magic is TLV records carrying **MAC**, **serial**,
  **model** and **hostname**. Stable key: MAC/serial. Display: hostname.
- findhostd answers a solicitation (it does not beacon). The spec ships **no
  probe_hex** — the exact valid query TLV is not in our captures, so we do not
  publish unverified probe bytes; a consumer listens for broadcast replies or
  sends a valid Assistant query.

**Admin**: DSM at `https://<ip>:5001/` (HTTPS default) or `http://<ip>:5000/`
(HTTP default). Both are DSM defaults and commonly reconfigured.

## References

- <https://kb.synology.com/en-us/DSM/tutorial/What_network_ports_are_used_by_Synology_services>
- <https://medium.com/@cq674350529/a-journey-into-synology-nas-part-2-analyzing-findhostd-service-2264e4fd21e9>
