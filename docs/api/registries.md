# Number registries

The device specs answer "how do I talk to this?". The registries in
[`registries/`](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/tree/main/registries)
answer a smaller question the specs cannot: *who made this thing?*, for hardware
that is not in the catalogue at all.

None of it is our data. It is the IEEE MAC address block listings and the
Bluetooth SIG assigned numbers, reshaped into three sorted tab-separated tables
and vendored so a consumer works offline. `registries/SOURCES.md` carries the
full provenance; this page is about how to use them without misleading anybody.

## Why a consumer wants them

Scan for BLE devices in a populated building and most of what comes back is not
in any catalogue. The worst case for a device list is the genuinely anonymous
one: no local name, no advertised service UUID, no manufacturer data. All you
have is an address — and the front of that address was assigned to somebody.
"Espressif Inc." is a great deal more use to a person staring at a list than a
bare `A4:CF:12:…`.

| You observed | Table | You can say |
|---|---|---|
| A MAC address | `ieee-oui*.tsv` | Who bought the address block |
| Manufacturer data | `bluetooth-company-ids.tsv` | Which company ID it advertises under |
| A 16-bit service UUID | `bluetooth-service-uuids.tsv` | What standard service it offers |

## Look up an address longest-first

There are three IEEE tables because there are three sizes of address block, and
you must try them in descending order: 36-bit (`ieee-oui36.tsv`, 9 hex digits),
then 28-bit (`ieee-oui28.tsv`, 7), then 24-bit (`ieee-oui.tsv`, 6).

Skipping the long ones does not degrade gracefully — it fails on exactly the
devices you care about. IEEE subdivides some 24-bit blocks and leaves the parent
row pointing at itself, and it is small vendors, buying small blocks, who make
interesting hardware. `C4:7C:8D` resolves to nothing usable at 24 bits; at 28
bits, `C47C8D6` is HHCC Plant Technology — the company that builds the Mi Flora
documented in this very repository.

Every table is sorted, fixed-width-keyed and newline-terminated on purpose: you
can binary-search the raw bytes and never build a 40,000-entry map on a phone.

## What you may and may not say with the answer

An address block identifies **whoever bought the block**. That is often the chip
vendor, not the product vendor.

The Lutron Caséta bridge in [`lutron-caseta-smart-bridge`](../devices/lutron-caseta-smart-bridge.md)
reports `b8:94:d9:1e:e7:67`. `B8:94:D9` belongs to Texas Instruments, because the
address comes off the radio module inside the bridge. Lutron's own OUI,
`00:0F:E7`, appears nowhere on the device. That spec therefore carries no
`mac_prefixes` at all — the observed one would flag every TI-radio device on the
network.

So:

- **Do** use a vendor name to label an otherwise-anonymous device, and to rank
  it above one you know nothing about.
- **Do not** use it to claim you know what the device *is*. Even a correct
  vendor name covers that vendor's whole catalogue.
- **Do not** fill a spec's `mac_prefixes` in by looking a vendor's name up in
  these tables. The registry says which blocks a company holds, not which one
  this product shipped with. Record what you observed.

These tables are also how you settle a prefix's
[`confidence`](spec-format.md#mac_prefixes-entries-carry-their-own-confidence).
A block that appears in `ieee-oui28.tsv` or `ieee-oui36.tsv` has been subdivided
among unrelated companies, which is `low` on its face: a whole-octet prefix
matches every slice, not just the one the product came from. A block that
appears only in `ieee-oui.tsv`, under the product's actual manufacturer, is
`medium`. `high` needs more than these tables can tell you — the registry has
nothing to say about which of a company's products use which block.

The same caution applies to Bluetooth company IDs, for a different reason:
vendors squat on identifiers they were never assigned. This repo's
[`shining-glasses`](../devices/shining-glasses.md) spec advertises 21076 purely
because `0x5254` spells "TR".

## Regenerating

```bash
python scripts/fetch_registries.py            # rewrite from upstream
python scripts/fetch_registries.py --check    # fail if upstream has moved
```

`--check` is network-bound and upstream changes constantly, so it is a
maintenance task rather than a CI gate. What CI *does* enforce is
`scripts/test_registries.py`: sortedness, key widths, uniqueness, no placeholder
organisations, and that the documented worked examples still resolve. Those are
the invariants a binary search depends on, and a file that violates them returns
wrong answers silently rather than failing.
