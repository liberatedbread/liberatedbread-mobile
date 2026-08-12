# OBD-II Bluetooth adapter target spec

## Target metadata
- target_id: obd2-bluetooth-adapter
- app package_id(s): N/A (no single vendor app; used by TuneECU, Torque Pro, Car Scanner,
  OBD Auto Doctor and every other OBD client)
- device class: vehicle diagnostic adapter (ELM327 / STN chipset)
- transport(s): Bluetooth Classic SPP (RFCOMM) or BLE GATT serial pipe; ISO 15765-4 CAN
  on the vehicle side
- local-only viability: high -- the adapter is entirely local and its command set is
  public. The gate is firmware quality (clones fail multi-frame transmit), not licensing.

## Known facts (public + observed)
- The Bluetooth payload is ASCII: `AT`/`ST` commands configure the adapter, bare hex
  digits are forwarded to the vehicle. Commands are CR-terminated; a reply is complete
  only when the `>` prompt arrives.
- Three BLE GATT families cover most of the market:
  - A: service `fff0`, notify `fff1`, write `fff2` (OBDLink CX, many generics)
  - B: service `18f0`, notify `2af0`, write `2af1` (Vgate iCar Pro 2S, LELink2)
  - C: service `ffe0`, single bidirectional `ffe1` (HM-10 module clones; reported)
- Bluetooth Classic variants use RFCOMM channel 1 with PIN 1234 / 0000 / 6789 and names
  like OBDII, OBDII-BT, V-LINK, Vgate, OBDLink LX/MX+.
- iOS cannot use generic Classic adapters (BLE or MFi only); Torque Pro on Android needs
  Classic SPP and cannot see BLE-only adapters.
- Most BLE adapters have no pairing, authentication or encryption.
- Clone firmware misreports its version and fails multi-frame ISO-TP transmit, custom
  headers and flow-control settings -- which is why vendor tools accept anything for DTC
  reads and name STN adapters for maintenance functions.
- OBD pin 16 is usually unswitched; a dongle left plugged in drains the battery.

## Device discovery signals
- BLE:
  - advertised name patterns: contains "OBD" (also "IOS-Vlink", "V-LINK", vendor names)
  - service UUIDs: `0000fff0-…`, `000018f0-…`, `0000ffe0-…`
  - address behavior: public on most modules
- Bluetooth Classic:
  - names: OBDII, OBDII-BT, V-LINK, Vgate, OBDLink LX, OBDLink MX+
  - RFCOMM channel 1; `sudo rfcomm bind 0 <mac> 1` -> /dev/rfcomm0

## Threat model + guardrails
- Scope: adapters and vehicles the researcher owns. Stationary vehicle, engine off.
- Vehicles are safety-critical: read-only work only, no writes to ABS, immobiliser,
  throttle or engine-map memory.
- Note for defenders: an unattended plugged-in BLE dongle is an unauthenticated bridge
  onto a vehicle bus for anyone in radio range. Documenting that is part of the point.

## First experiments (do these first)
1) Enumerate the adapter's GATT table with nRF Connect; record which family it belongs to
   and add a row to the family table in `docs/devices/obd2-bluetooth-adapter.md`.
2) Capability probe: `ATZ`, `ATSP6`, `ATCAF0`, `ATFCSM1` -- a refusal on either of the
   last two predicts multi-frame failures later.
3) btsnoop HCI capture of a vendor app performing a paid function; follow the RFCOMM/ATT
   stream in Wireshark and read the requests directly.
4) `scripts/obd_discover.py --port /dev/rfcomm0` for a read-only ECU/DID map.

## Protocol hypotheses (to validate)
- Family C adapters reuse the HM-10 single-characteristic pattern already documented for
  the MoTool Slacker, so one BLE serial abstraction should serve both.
- 20-byte MTU means reply reassembly is required in all families; the `>` prompt is the
  only reliable frame terminator.
- STN-specific `ST` commands are the practical marker of genuine hardware; a clone that
  answers `ATI` with an STN banner should fail `STDI`.

## Control surface inventory (what the replacement app must support)
- Scan and connect across all three GATT families plus Classic SPP
- Buffer-until-prompt reply reassembly
- Adapter init sequence (echo/linefeed/space off, protocol select)
- Protocol auto-detect and header/flow-control configuration
- Raw request passthrough with ISO-TP segmentation when `ATCAF0` is in use
- Capability probe surfaced to the user, so a clone's limits are visible before a function
  fails halfway through

## Evidence checklist
- nRF Connect GATT dumps per adapter model: pending
- btsnoop HCI log of a vendor app session: pending
- Capability probe results per adapter: pending

## Spec output (clean-room)
Write a derived spec in:
- docs/devices/obd2-bluetooth-adapter.md
- device-specs/devices/obd2-bluetooth-adapter.yaml

## References (URLs only)
- https://www.carscanner.info/choosing-obdii-adapter/
- https://github.com/vdvornichenko/obd-ble-serial
- https://github.com/pbutterworth/nissan-leaf-obd-ble
- https://www.obdlink.com/products/obdlink-ex/
- https://forums.raspberrypi.com/viewtopic.php?t=191517
