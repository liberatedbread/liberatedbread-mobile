# Generic IPP Network Printer (status)

> **Status**: Status only (discovery signature and IPP status from public standards; untested — no hardware)
> **Protocol**: mDNS / DNS-SD (Bonjour printing) + IPP (RFC 8010/8011)
> **Manufacturer**: Various (IPP Everywhere / AirPrint printers)
> **Manufacturer Status**: Active — status read over IPP; printing left to the OS print system

## Overview

Office and home network printers advertise themselves over mDNS/DNS-SD using
standard, vendor-neutral service types. This app **identifies** them and
**reads their status over IPP** — state, what is wrong, ink or toner levels,
the paper loaded — with one standard Get-Printer-Attributes request, and
deep-links to the printer's embedded web interface. It does **not** send
print jobs itself: printing is the job of the OS print system (AirPrint, IPP
Everywhere / driverless printing), which already reaches these printers with
no vendor software.

## Status over IPP

`POST http://<ip>:631/<rp>` with `Content-Type: application/ipp` (TLS on the
same port for `_ipps._tcp`, self-signed — pin on first use). The body is an
RFC 8010 Get-Printer-Attributes request (operation `0x000B`) asking for
`printer-state`, `printer-state-reasons`, `printer-state-message`,
`printer-make-and-model`, the `marker-*` supply attributes, `media-ready` and
`document-format-supported`. The full byte layout is in the spec's
`protocol_details.ipp_status`.

Only `_ipp._tcp` / `_ipps._tcp` carry this surface; a printer seen only as
`_pdl-datastream` or `_printer` is linked to its admin page, nothing more.

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
