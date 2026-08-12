# Number registries

Third-party reference data, vendored. **None of this is our work and none of it
is device knowledge** — the device specs next door are the product; these files
just let a consumer put a name to hardware that isn't in the catalogue at all.

Regenerate with `python scripts/fetch_registries.py`; check for drift in CI with
`--check`. Do not hand-edit.

## Why they are here

A scanner meets far more devices than we have specs for. The interesting case is
the anonymous one: no local name, no advertised service UUID, no manufacturer
data — just an address. The first three octets of that address were assigned to
somebody, and "Espressif Inc." is a great deal more use to a person staring at a
device list than a bare `A4:CF:12:…`.

Vendored rather than fetched at runtime for three reasons: the app is meant to
work with no network at all; a lookup that changes under a released build is a
lookup nobody can reproduce a bug against; and querying a registry per device
seen would tell a third party exactly what hardware is in someone's home.

## Format

All three are sorted, tab-separated, newline-terminated, one record per line,
with a fixed-width key. That is deliberate: a consumer can binary-search the raw
bytes and never build a 40,000-entry map in memory on a phone.

| File | Key | Value |
|---|---|---|
| `ieee-oui.tsv` | 6 uppercase hex digits (MA-L, 24-bit) | Organisation name |
| `ieee-oui28.tsv` | 7 uppercase hex digits (MA-M, 28-bit) | Organisation name |
| `ieee-oui36.tsv` | 9 uppercase hex digits (MA-S, 36-bit) | Organisation name |
| `bluetooth-company-ids.tsv` | 5-digit zero-padded decimal | Company name |
| `bluetooth-service-uuids.tsv` | 4 lowercase hex digits (16-bit UUID) | Service name |

## Provenance

### `ieee-oui.tsv`, `ieee-oui28.tsv`, `ieee-oui36.tsv`

The IEEE public listings of MAC address block assignments, in the three sizes a
vendor can buy: [MA-L](https://standards-oui.ieee.org/oui/oui.csv) (24-bit),
[MA-M](https://standards-oui.ieee.org/oui28/mam.csv) (28-bit) and
[MA-S](https://standards-oui.ieee.org/oui36/oui36.csv) (36-bit). Published by
the IEEE Registration Authority as a public record; free to use and redistribute.

**Consult them longest first.** IEEE subdivides some MA-L blocks into MA-M and
MA-S assignments and leaves the parent 24-bit row pointing at itself, so a
24-bit-only lookup returns nothing usable for precisely the vendors worth
naming — a small vendor buys a small block. `C4:7C:8D` is the worked example:
MA-L says only "IEEE Registration Authority", while MA-M records `C47C8D6` as
HHCC Plant Technology, the company that actually builds the Mi Flora this repo
documents (hence its HHCCJCY01 model number). Fifteen other MA-M blocks share
that same 24-bit prefix, belonging to entirely unrelated companies.

Two kinds of row are dropped, because neither names an organisation:

- **`Private`** — the registrant paid to withhold their name. The row carries no
  information, and keeping it would have a consumer announce a device as made by
  "Private".
- **`IEEE Registration Authority`** — a placeholder marking a subdivided block.
  The real answer is in one of the longer tables, or nowhere.

### `bluetooth-company-ids.tsv`, `bluetooth-service-uuids.tsv`

Nordic Semiconductor's [bluetooth-numbers-database](https://github.com/NordicSemiconductor/bluetooth-numbers-database)
(v1), a versioned machine-readable transcription of the Bluetooth SIG Assigned
Numbers document. Used in preference to scraping the SIG's own publication
because it is already this repository's citation for SIG numbers (see
`docs/protocols/standards-and-references.md`) and because a stable snapshot is
what a reproducible build needs.

Only the 16-bit SIG-allocated service UUIDs are kept. A full 128-bit vendor UUID
means something specific to one product, and that belongs in a device spec.

## What a company ID is worth

Rather less than it looks. A Bluetooth SIG company identifier says which company
*registered* an identifier, not which company built the thing in front of you —
vendors squat on IDs they were never assigned all the time (this repo's own
`shining-glasses` spec advertises 21076 because `0x5254` spells "TR").

The same caution applies harder to an OUI, and in a way worth stating plainly:
**an address block identifies whoever bought the block, which is frequently the
chip vendor rather than the product vendor.** The Lutron Caséta bridge captured
in `lutron-caseta-smart-bridge.yaml` advertises `b8:94:d9:aa:bb:cc`; that block
belongs to Texas Instruments, because the address comes off the radio module
inside the bridge. Lutron's own OUI, `00:0F:E7`, appears nowhere on the device.
Anyone reading a vendor name off an OUI is being told what silicon is in the
box, at best.

Treat both as a way to rank and label. Never as proof, and never as grounds for
telling someone which product they are looking at.
