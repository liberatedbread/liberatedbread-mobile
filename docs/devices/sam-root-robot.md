# Root coding robot (RT0 / RT1)

> **Status**: Source-derived spec available; untested on hardware
> **Protocol**: BLE, Root protocol 1.0–1.3 over Nordic UART
> **Manufacturer**: Root Robotics, later iRobot; current successor stewardship is SAM Labs
> **Manufacturer Status**: Active successor app/protocol stewardship; current hardware production is not asserted

## Overview

Root is an educational coding robot controlled directly by a phone or computer
over Bluetooth LE. The official protocol is publicly maintained in SAM's
successor-hosted repository. No vendor account, cloud service, bridge or Wi-Fi
provisioning is needed for the operations documented here.

This page and `device-specs/devices/sam-root-robot.yaml` deliberately cover only
**Root RT0 and RT1** and the Root protocol versions documented as **1.0 through
1.3**. The pinned source calls 1.3 current and 1.4 planned. It does not establish
what later production firmware supports.

!!! warning "Scope and safety limits"
    Create 3 / Ci3 and its separate protocol-version table are excluded. Do not
    infer support from the Root Identifier Service alone; also require an RT0 or
    RT1 manufacturer robot type. No motor/drive, other actuator, rename,
    bootloader, firmware-upload or firmware-activation path is declared. The only
    write operations here are version/name/battery queries and stop-and-reset.

Nothing here has been replayed on a robot by this project. All packet facts are
`reported` from public source, and all example frames are constructed, not
captured. An owner advertisement/GATT dump and a read-only exchange on current
firmware are still needed.

## Hardware and identification

| Property | Value |
|----------|-------|
| Models | Root RT0, Root RT1 |
| Radio | Bluetooth LE peripheral |
| Category | `robot` |
| Companion app | SAM Root (not required for a replacement client) |
| Protocol scope | Root 1.0, 1.1, 1.2 and 1.3 |
| Out of scope | Create 3 / Ci3, Root-newer-than-1.3 behavior |

Advertisements contain the empty **Root Identifier Service**
`48c5d828-ac2a-442d-97a3-0c9822b04979`, a renamable local name, Robot State,
and manufacturer-specific data. Manufacturer data uses company ID **0x0600**
(decimal 1536; company bytes `00 06` on the wire), followed by a robot-type
string. This spec accepts only payloads beginning:

| Type | Payload prefix | Meaning |
|------|----------------|---------|
| `52 54 30` | ASCII `RT0` | Root RT0 |
| `52 54 31` | ASCII `RT1` | Root RT1 |

Use the identifier service as the scan filter and the RT0/RT1 type as a second
required condition. The name is not a stable matcher because the protocol can
rename it. Nordic UART is shared by unrelated products and is not a discovery
signal. The source does not say whether bytes can follow the three-character
robot type, so matching is by prefix rather than whole-payload equality.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | No |
| Method | `ble_direct` |
| Discovery | Root Identifier Service plus RT0/RT1 manufacturer type |
| Passphrase protection | `not_applicable` |
| Confidence | Medium (official public source; not replayed here) |

1. Power on the robot and keep it stationary for initial read-only checks.
2. Scan for the Root Identifier Service and require an RT0/RT1 manufacturer type.
3. Connect and discover GATT without starting OS pairing.
4. **Subscribe to robot TX first** and wait for the subscription to complete.
5. Send `get_main_board_versions` and accept only protocol 1.0–1.3 for this spec.
6. Optionally read the name, Device Information or battery state.

**Factory reset**: unknown. No physical reset sequence or list of cleared state
is established. Stop-and-reset cancels pending actions and resets estimated
position; it is **not** proven to restore factory settings or clear the stored
name. Disconnecting or power-cycling is not a factory reset either.

**Rebinding / rejoin**: there is no Wi-Fi network or bond to replace. Disconnect
the previous central, scan and connect again, then subscribe to TX. No reset is
needed. Whether more than one central can connect at once is unknown.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | Not applicable |
| One central at a time | Unknown |
| One bond at a time | Not applicable; no bond is created |
| Confidence | Medium (official protocol and bare-GATT reference client) |

There is no pairing-mode sequence, PIN or application authentication exchange.
Consequently there is no device-side unpair operation to perform: disconnect the
host. If another client is holding the connection, close that client first. No
owner credential is issued to or stored by a replacement client.

## BLE profile

| UUID | Name | Role |
|------|------|------|
| `48c5d828-ac2a-442d-97a3-0c9822b04979` | Root Identifier Service | Empty discovery service; no characteristics |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | Static version/manufacturer strings and Robot State |
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e` | Nordic UART Service | Carries 20-byte Root packets |

Device Information contains:

| UUID | Characteristic | Reported representation |
|------|----------------|-------------------------|
| `00002a25-0000-1000-8000-00805f9b34fb` | Serial Number | 12-byte serial string; do not publish a real unit's value |
| `00002a26-0000-1000-8000-00805f9b34fb` | Firmware Revision | Version string, up to 12 bytes |
| `00002a27-0000-1000-8000-00805f9b34fb` | Hardware Revision | Version string, up to 12 bytes |
| `00002a29-0000-1000-8000-00805f9b34fb` | Manufacturer Name | Manufacturer string, reported as a 13-byte field |
| `00008bb6-0000-1000-8000-00805f9b34fb` | Robot State | Two bytes; also present in advertising |

Robot State's second byte carries battery percentage in its low seven bits. The
first byte contains bump/touch/cliff flags, but the pinned source's diagram has
two leading zeroes plus seven flag labels, which cannot fit in one byte. This
spec therefore does **not** invent individual flag masks.

Nordic UART names are from the **robot's** perspective:

| UUID | Direction | Properties and use |
|------|-----------|--------------------|
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | Host to robot RX | Write / write without response; exactly one 20-byte request per write |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e` | Robot TX to host | Notify / indicate; exactly one 20-byte response or event per delivery |

Subscribe to TX before writing RX. Prefer write with response. Write without
response is documented, but the source gives no numeric pacing interval; the
host must pace those writes itself.

## Packet format

Every request, response and event is exactly **20 bytes**:

| Offset | Length | Field | Rule |
|--------|--------|-------|------|
| 0 | 1 | Logical device | Selects general (0), battery (14), or another subsystem |
| 1 | 1 | Command | Meaning is scoped by the logical device |
| 2 | 1 | Packet ID | Request correlation or independent event counter |
| 3–18 | 16 | Payload | Left-justified on byte boundaries; unused bytes zero |
| 19 | 1 | CRC | CRC-8 over offsets 0–18 |

Multi-byte payload integers are **big-endian**. A shorter value starts at its
field's first byte; it is not right-aligned within the 16-byte payload. The CRC
is **CRC-8/SMBUS**: polynomial `0x07`, initial value `0x00`, no input or output
reflection, final XOR `0x00`, calculated over the **first 19 bytes**. Reject a
packet with the wrong length or CRC before decoding its payload.

Packet IDs have three distinct roles:

- **Requests:** the host increments an unsigned 8-bit counter, wrapping after
  255. ID zero is always accepted and resets sequence tracking, which makes the
  examples below safe starting points.
- **Responses:** the robot copies the request ID. Device, command and ID (the
  first three bytes) match the request.
- **Events:** the robot increments its **own independent** unsigned 8-bit event
  counter. Never treat request and event IDs as one sequence, and never match a
  response by ID alone without also checking device and command.

Timestamps, where present, are unsigned 32-bit milliseconds since power-on, also
big-endian.

## Root protocol versions

The source's main-board firmware mapping is:

| Root BLE protocol | Main-board firmware |
|-------------------|---------------------|
| 1.0 | 1.0, 1.1, 1.2, 1.3, 1.4 |
| 1.1 | 1.5, 1.8, 1.10 |
| 1.2 | 1.11, 2.0, 2.1 |
| 1.3 | 2.3, 2.7 |

Query the main board before broader use. A `2.7` firmware response should report
protocol `1.3`. Do not map Create 3 firmware or protocol versions onto Root.

## Safe initial operations

All requests below use the common template and response layouts in the YAML.
Only the stop operation changes device activity; the queries are read-only.

| Operation | Device / command | Request payload | Reply |
|-----------|------------------|-----------------|-------|
| Main-board versions | 0 / 0 | `a5` then 15 zero bytes | Firmware, hardware, bootloader and protocol versions |
| Get advertising name | 0 / 2 | 16 zero bytes | UTF-8, NUL-terminated name in the 16-byte payload |
| Get battery level | 14 / 1 | 16 zero bytes | `timestamp:u32be`, `voltage_mv:u16be`, `percent:u8` |
| Stop and reset activity | 0 / 3 | 16 zero bytes | No response documented; cancels pending actions, not a factory reset |

The version reply starts at packet offset 3: board, firmware major/minor,
hardware major/minor, bootloader major/minor, protocol major/minor, and firmware
patch. Board `0xa5` means main board. Name replies decode through the first NUL;
a full 16-byte name need not contain one. Battery events use device 14 / command
0 and the same fields as the command-1 response, but an independent event ID.
The source says an event is emitted when battery level drops by more than 10%.

### Constructed examples

These are documentation vectors, not captures. `Root demo` is an invented name.

Get main-board versions with request ID 42:

```text
00 00 2a a5 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 e6
```

A matching example response (firmware 2.7, hardware 1.0, bootloader 1.0,
protocol 1.3, patch 0):

```text
00 00 2a a5 02 07 01 00 01 00 01 03 00 00 00 00 00 00 00 f9
```

Get the advertising name with ID zero, followed by the invented `Root demo`
response. Notice that the response repeats the first three request bytes:

```text
request:  00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 54
response: 00 02 00 52 6f 6f 74 20 64 65 6d 6f 00 00 00 00 00 00 00 d3
```

Query battery with ID 7. The response below decodes to timestamp 16,909,060 ms,
4000 mV and 75%:

```text
request:  0e 01 07 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 58
response: 0e 01 07 01 02 03 04 0f a0 4b 00 00 00 00 00 00 00 00 00 c0
```

A separate battery event with event ID 231 (`0xe7`), 3996 mV and 74% illustrates
why an event is not the response to request 7:

```text
0e 00 e7 01 02 03 04 0f 9c 4a 00 00 00 00 00 00 00 00 00 43
```

Stop and cancel pending activity with ID zero (the CRC happens to be `0x7e`):

```text
00 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 7e
```

`scripts/test_sam_root_robot.py` independently rebuilds all of these frames with
a bitwise standard-library CRC implementation, renders every declared request
template, checks the big-endian decodes, and verifies response-versus-event ID
handling. It also checks the standard CRC-8/SMBUS check value and rejects a
corrupted frame.

## Local access and cloud

Local BLE is native to the robot. This spec's identification, version/name,
battery and stop surface needs no vendor service. The current app and protocol
repository are useful preservation references, not runtime dependencies.
Firmware hosting or authenticity is not assessed because no update path is
included.

## Tools used

- Public-source reading only: official protocol README, CRC implementation and
  example connection flow at the pinned successor commit.
- Static successor-app research for continuity only; no app-internal symbols or
  owner identifiers are carried into this document.
- No hardware, new packet capture, firmware download or update attempt.

## References

- [Official Root Robot BLE protocol, pinned commit](https://github.com/PoweredBySAM/sam-root-ble-protocol/blob/8bac987096e984cb472843f8180fef142171df70/README.md)
- [Official CRC-8 implementation, pinned commit](https://github.com/PoweredBySAM/sam-root-ble-protocol/blob/8bac987096e984cb472843f8180fef142171df70/crc/crc.c)
- Machine-readable spec: `device-specs/devices/sam-root-robot.yaml`
- Independent packet tests: `scripts/test_sam_root_robot.py`

## Remaining gaps

- No current RT0/RT1 advertisement, GATT dump or live read-only exchange has
  verified this source-derived spec.
- Production protocol changes after the pinned source's Root 1.3 snapshot are
  unknown; version query first, never assume newer support.
- Factory-reset behavior, persistent-state clearing and simultaneous-central
  limits are unknown.
- Robot State flag masks need clarification or a capture; only its low-seven-bit
  battery field is declared.
- Safe write-without-response pacing is unmeasured; use write with response.
