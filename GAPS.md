# GAPS.md

Last updated: 2026-08-23

This file is a record of the ORIGINAL 27-target research wave and what
became of it. It is not a live list of everything the catalogue is missing
-- the catalogue has roughly five times as many specs as that wave produced,
and per-spec gaps live in each spec's own `evidence` and
`remaining_unknowns` blocks, where the person who found them was standing.

## Remaining Gaps: 1

| Target | Status |
|--------|--------|
| **ifreqtech-speaker-mic** | No companion APK exists — BT Classic hardware bridge (HFP + likely SPP). Requires HCI snoop on physical device. RE blocked until hardware in hand. |

## Resolved: 27 of 27 original targets

| Target | Resolution |
|--------|-----------|
| switchbot-ble | YAML written |
| govee-h5075, h5080, h6001 | 3 YAMLs written |
| gerbing-thermogauge | 10 UUIDs from IL disassembly, YAML written |
| elk-bledom | YAML written |
| ibbq-meat-thermo | YAML written |
| itag-ble-tracker | YAML written |
| xiaomi-miflora | YAML written |
| xiaomi-lywsd03mmc | YAML written |
| xiaomi-mi-scale | YAML written |
| niimbot-d110 | YAML written |
| cat-printer | YAML written |
| fichero-d11 | YAML written |
| shining-glasses, shining-mask | 2 YAMLs written |
| spider-farmer-ggs | YAML written |
| hotwired-heated-gear | Full frame format (AA/CC), YAML written |
| etekcity-smart-scale | YAML written |
| iledcolor-led-panel | YAML written |
| ble-pulse-oximeter | YAML written |
| divoom-pixoo | 666-line spec, 17 pixel encodings, YAML written |
| bmw-motorcycle-motoscan | → obd2-bluetooth-adapter.yaml (OBD-II/CAN) |
| motorcycle-ground-effect-lighting | → split: proglow ✅, seeblue ✅, opt7=elk-bledom ✅, xkglow ✅ |
| roku-local-remote | → roku-ecp.yaml (protocol fully documented) |
| led-space | → led-space.yaml (third app on the LOY SPACE / popled.cn platform; Wi-Fi AP/UDP 9090 path documented from com.yj.led static analysis) |

## Resolved: m6-fitness-band (was "Uncertain")

RESOLVED 2026-07-31: the Veryfit 2.0 (`com.veryfit.multi`) app-to-device match was
positively REFUTED by the M6's own stock firmware dump (rbaron/m6-reveng) — no 0AF0
UUID exists anywhere in the 512 kB flash. The M6 is an LT716-platform device speaking
the FitPro protocol (NUS + 0xCD-framed commands + Telink OTA, advertised name "M6",
companion app `xfkj.fitpro`). `m6-fitness-band.yaml` was re-targeted accordingly and
keeps the Veryfit analysis only as a clearly-labeled mis-attribution note. See
`research/m6-fitness-band/CONFIRMATION.md` §C.

## Mobile handlers' schema asks (image-upload wave)

Recorded from the `SPEC-GAP` comments the mobile app's handlers carry in
`rust/src/protocol/`. Each marks a place where a handler had to hard-code a
value, tell two cases apart by command name, or parse a payload out of prose,
because the spec or schema gave it no field to read. These are spec/schema
asks, not protocol unknowns: the bytes are established downstream and work;
what is missing is a machine-readable home for them so a generic consumer
gets what this app had to special-case. Twelve asks across five handlers:

All twelve were closed on 2026-09-17 by declaring the facts (the specs and
schema now carry them; the handlers can resolve by key):

| Handler | Schema ask | Now declared as |
|---------|-----------|-----------------|
| cdbwsoft_ecb | `link_flag` vocabulary is undeclared — the handler carries the values inline. | `data_transfer_start.parameters.link_flag` `allowed: [0, 1]` with labels (magic-display). |
| cdbwsoft_ecb | WRITE2 and WRITE3 are distinguishable only by command name; wants a declared `channel_tag` to switch on. | `role: bulk` on WRITE2, `role: stream` on WRITE3, `role: command` on WRITE1 — a new optional characteristic key. |
| cat_printer | Command set is in prose only — there is no `commands:` block to bind. | `commands:` on 0xAE01 (cat-printer) and on 0xAE01/0xAE03 (cat-printer-mxw01), CRC via `auto: crc8`. |
| cat_printer | Energy byte order is unstated. | `set_energy.parameters.energy.endianness: little` (NaitLee; rbaron's big-endian noted in remaining_unknowns). |
| cat_printer | Payload values are unstated. | A3 → 0x00, BE → 0x01, A9 → 0x00, A4 → 50, precomputed in each command's `value`. |
| fichero_d11 | Command set is in prose, not a `commands:` block. | `commands:` on 0xFF02, aliased onto 0x2AF1. |
| fichero_d11 | Density vocabulary is not a field. | `features[image_upload].print_density` and `set_density.parameters.density` (`allowed`/`labels`). |
| fichero_d11 | Paper-type vocabulary is not a field. | `features[image_upload].paper_type` and `set_paper_type.parameters.paper_type`. |
| idotmatrix | The 4096-byte chunk payload is described in prose only. | `framing.max_chunk_size: 4096` on 0xFA02, and `upload_image_chunk`/`upload_gif_chunk` templates. |
| idotmatrix | Static-image header values (time/delay + speed) are unstated. | `display_seconds` and `material_type` parameters with defaults (0/12 image, 5/13 GIF). |
| ledbadge_bitmap | Slot-mode enumeration is not in the YAML. | `write_badge_data.parameters.mode` `allowed: [0..8]` with labels. |
| ledbadge_bitmap | The 8192-byte flash ceiling is not declared. | `features[image_upload].max_payload_bytes: 8192`. |

Still open from the same wave: a payload-length `auto` role (the cat
printer's variable-length 0xBF RLE row), nibble-packed parameters (the
badge's speed nibble shares a byte with `mode`), and a raw-byte-stream
transport arm for top-level `commands` (Brother's raster opcodes stay
`payload_hex` prose).

## Validation: 204/204 passing (203 device specs + 1 example)

Pinned by `test_gaps_md_states_the_real_spec_count` in
`scripts/test_device_specs.py`: this line said 92/92 for a fortnight after
the catalogue passed 130, which is the failure mode of every hand-written
count. It fails the suite now rather than quietly misleading a reader.
