# `registries/`

Reference tables a consumer reads alongside the device specs. Two kinds live
here, and they are maintained differently:

## Fetched from upstream — do not hand-edit

`ieee-oui.tsv`, `ieee-oui28.tsv`, `ieee-oui36.tsv`, `bluetooth-company-ids.tsv`
and `bluetooth-service-uuids.tsv` are third-party number registries (IEEE MAC
block assignments, Bluetooth SIG assigned numbers), reshaped into sorted,
fixed-width-keyed, tab-separated tables. Regenerate with
`python scripts/fetch_registries.py`; provenance, licensing and the format are
in [SOURCES.md](SOURCES.md), and the consumer-facing guide is
`docs/api/registries.md`.

## Maintained here — `shared-service-types.tsv`

The list of mDNS service types and SSDP search targets that **prove nothing on
their own**: a device announcing one of these is a member of a platform
(HomeKit, AirPlay, Cast, "has a web server", "is a DLNA renderer"), not a
product, so a spec claiming one must never be *promoted* to a match by it
alone. It is the Wi-Fi twin of the rule that a SIG-assigned 16-bit service
UUID (`bluetooth-service-uuids.tsv`) never identifies a BLE product.

```
type	kind	reason
_hap._tcp.local.	mdns	Every HomeKit accessory; the platform, not a product.
urn:schemas-upnp-org:device:MediaRenderer:1	ssdp	Every DLNA renderer -- ...
```

- `type` — the service type or search target, spelled exactly as a spec's
  `identification.mdns_service_type` / `ssdp_search_targets` spells it: mDNS
  types fully qualified and trailing-dotted (`_http._tcp.local.`, never
  `_http._tcp`), SSDP targets as the `ST` header carries them.
- `kind` — `mdns` or `ssdp`.
- `reason` — one sentence on who else announces it, so the next reader can
  tell a deliberate entry from a mistake.

Header row, tab-separated, LF line endings, sorted by `kind` then `type`. A
spec whose only identification axis is a type in this table matches nothing
until it adds one that is its own — an `mdns_txt_match`, an `ssdp_match` on
the description document, a `lan_protocols` token, a vendor MAC block. The
schema keys that narrow a shared type are described under
`identification` in `docs/api/spec-format.md`.

This file is hand-maintained (there is no upstream to fetch it from) and
covered by `scripts/test_registries.py`: it must parse, every row must be
fully qualified, and no type may appear twice. Adding a row is a spec-pack
refresh for consumers, not an app release — which is the point of it being a
file rather than a list in code.

## Maintained here — `dfu-signatures.tsv`

The signatures of each firmware-update stack: service and characteristic
UUIDs and default bootloader names. A scanner uses it to recognise a device
sitting in its bootloader, including a device no spec covers, and to keep
update services out of product identification.

```
signature	kind	mechanism	meaning	source
0000fe59-0000-1000-8000-00805f9b34fb	service_uuid	nordic_secure_dfu	Nordic Secure DFU ...	https://...
DfuTarg	local_name	nordic_secure_dfu	nRF5 SDK bootloader default name ...	https://...
```

- `signature`: a lowercase 128-bit UUID, or an exact advertised name.
- `kind`: `service_uuid`, `characteristic_uuid` or `local_name`.
- `mechanism`: one value of the schema's `features[].dfu.mechanisms` enum.
- `meaning`: what the signature is for, including any entry opcode.
- `source`: the documentation or reference code the row comes from.

Sorted by `kind`, then `signature`. The per-stack behaviour behind the rows
is in `docs/protocols/firmware-update.md`. `scripts/test_registries.py`
checks the format and that every `mechanism` is in the schema's enum.
