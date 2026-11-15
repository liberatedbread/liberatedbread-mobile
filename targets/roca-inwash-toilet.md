# Roca In-Wash smart toilets (Roca Connect app) — target spec starter

## Target metadata
- target_id: roca-inwash-toilet
- app package_id(s): com.roca.connect ("Roca Connect")
- device class: shower-toilet / smart toilet seat (In-Wash family; one unit on
  firmware 3.29 confirmed; register maps may differ by model and firmware)
- transport(s): BLE GATT, phone-direct, no cloud or account
- local-only viability: **high** — local already; one MIT HA integration with
  discovery, wash/dry control and settings.

## Known facts (public; HA community 2026-08)
- Custom GATT service `fabaee02-4910-473c-be46-960948c2f59c` with three
  characteristics: a write characteristic for commands (`fabae002-…`), a
  notify characteristic for status flags (`fabae004-…`) and a notify
  characteristic for data payloads (`fabae006-…`) — the full 128-bit forms of
  the last two still need to be read from the source.
- Authentication is an AES-128-ECB challenge. The key is derived by XORing a
  fixed vendor constant with the toilet's MAC address. **The vendor constant
  is a vendor secret, not a protocol fact — never commit it**; a spec says
  "XOR of the vendor challenge key with the device address" and stops.
- Discovery keys on a manufacturer id in the advertisement (value not given
  in the write-up).
- The integration also exposes raw register read/write for advanced users;
  a spec should carry the named functions only.
- Sources: [HA thread](https://community.home-assistant.io/t/roca-inwash-bluetooth-integration-local-no-cloud/1019619)
  (2026-08-02) · [IsaacVI/roca-inwash-ha](https://github.com/IsaacVI/roca-inwash-ha) (MIT).
  Derived from the Roca Connect Android app — restate, do not copy.

## Device discovery signals
- BLE: manufacturer-specific data with Roca's id (value TBD); service UUID
  above; name pattern unknown.
- Wi-Fi: none.

## Threat model + guardrails
- Owned units only. Water-jet and dryer heater: attended use; no scheduling.
- Raw register writes are out of scope for a published spec.

## First experiments
1) Read the integration for the full UUIDs, manufacturer id, challenge
   framing and the register names it exposes.
2) HCI capture of connect + challenge + one wash command on an owned unit.
3) Note which In-Wash models and firmware the register map was seen on.

## Control surface inventory (replacement app MVP)
- wash start/stop · dryer · water temperature / pressure / position · seat
  heating · night light · settings read-back

## References (URLs only)
- https://community.home-assistant.io/t/roca-inwash-bluetooth-integration-local-no-cloud/1019619
- https://github.com/IsaacVI/roca-inwash-ha
