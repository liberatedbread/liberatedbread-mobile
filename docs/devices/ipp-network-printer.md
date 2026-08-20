# Generic IPP Network Printer (identify-only)

> **Status**: Identify-only (discovery signature from public standards; untested — no hardware)
> **Protocol**: mDNS / DNS-SD (Bonjour printing)
> **Manufacturer**: Various (IPP Everywhere / AirPrint printers)
> **Manufacturer Status**: Active — recognised and linked to the printer's own web UI, not driven here

## Overview

Office and home network printers advertise themselves over mDNS/DNS-SD using
standard, vendor-neutral service types. This app **identifies** them — shows a
printer pictogram and deep-links to the printer's embedded web interface — and
does **not** print. Printing is the job of the OS print system (AirPrint, IPP
Everywhere / driverless printing) or the vendor's companion app (HP Smart,
Epson Smart Panel, Brother iPrint&Scan, Canon PRINT).

## Discovery Summary

- **DNS-SD service types** (Bonjour Printing Specification):
    - `_ipp._tcp` — IPP, modern print protocol (TCP 631)
    - `_ipps._tcp` — IPP over TLS
    - `_printer._tcp` — legacy LPD (515)
    - `_pdl-datastream._tcp` — raw socket / JetDirect (9100)
- **TXT keys**: `rp`, `ty` (make/model, for display), `pdl`, `UUID` (stable
  per-printer id, advertised by IPP Everywhere printers), `adminurl`, `note`,
  `product`.
- **Stable key**: TXT `UUID`, falling back to hostname. **Display**: mDNS
  instance name (or `ty`).

**Admin**: `http://<ip>/` (most printers serve an embedded web server at the
root; prefer TXT `adminurl` when present). Scheme/port may be reconfigured.

## References

- <https://developer.apple.com/bonjour/printing-specification/>
- <https://www.pwg.org/ipp/everywhere.html>
- <https://datatracker.ietf.org/doc/html/rfc8010>
