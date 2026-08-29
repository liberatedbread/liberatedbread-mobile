# [Device Name]

> **Status**: [Research / In Progress / Complete]
> **Protocol**: [BLE / WiFi / Zigbee / Other]
> **Manufacturer**: [Company Name]
> **Manufacturer Status**: [Abandoned / Shutdown / Server-dependent]

## Overview

Brief description of the device and why it's being reverse engineered.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | |
| Chipset | |
| Radio | BLE 4.x / WiFi 802.11n / etc. |
| FCC ID | |

## Initial Setup

How a factory-fresh device is provisioned, and how confident we are in it. See
[Initial Device Setup](../protocols/device-setup.md) for the patterns, and mirror
this into `device.setup` in the machine-readable spec.

| Property | Value |
|----------|-------|
| Setup required | Yes / No (most BLE devices: No) |
| Method | `softap_http` / `softap_soap` / `ble_provisioning` / `ble_direct` / `wired` / `device_ui` / `button_pairing` / `cloud_account` |
| Setup AP / advertised name | e.g. `Wemo.*`, `Vector-XXXX` |
| Passphrase protection | plaintext / device_encrypted / tls / not_applicable |
| Confidence | high (ran it) / medium (public source) / low (inferred) |

**Factory reset**: which button, held how long, in what power state, and the LED
or screen signal that confirms it. Note what the reset clears and what survives.
Mirror it into `device.setup.factory_reset.procedures` in the machine-readable
spec, and mark a procedure you have not run `verified: false` with a `basis`
saying where it came from.

**Rebinding to a new network**: in place, remotely triggered, or physical reset
only. If the old network has to still be up, say so — that changes what a user
must do *before* replacing a router.

## Pairing

Whether a client has to pair or bond before the control surface answers — a
different question from provisioning, and the one that decides whether a
"connect and go" implementation works. See
[Pairing, Bonding and Unpairing](../protocols/pairing.md), and mirror this into
`device.pairing`. Required on every BLE spec; "nothing pairs" is the common
answer and worth stating.

| Property | Value |
|----------|-------|
| Pairing required | Yes / No / Unknown |
| Security mode | `none` / `just_works` / `passkey_entry` / `numeric_comparison` / `out_of_band` / `legacy_pin` / `network_join` / `app_layer` |
| Bonding | `none` / `optional` / `required` (does the device *store* it?) |
| PIN source | `fixed_default` / `printed_label` / `device_screen` / `vendor_app` / `derived` / `user_chosen` |
| One central at a time | Yes / No / Unknown |
| One bond at a time | Yes / No / Unknown — a new client *replaces* the old |
| Confidence | high (ran it) / medium (public source) / low (inferred) |

**Entering pairing mode**: the button and how long, the signal that says the
device is now pairable, and how long the window stays open. If the device is
always pairable, say so.

**Unpairing**: how to drop a bond *without* a factory reset, or state plainly
that there is no such route — that answer tells a user what adopting a
second-hand unit will cost them.

**Recovery**: what a user must do when something else is holding the device —
close the vendor app, forget it in the OS Bluetooth settings, power-cycle it.

## Protocol Summary

### BLE Services (if applicable)

| UUID | Name | Description |
|------|------|-------------|
| `0x????` | | |

### HTTP Endpoints (if applicable)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/...` | |

### Commands

#### Command: [Name]

**Request**:

| Offset | Length | Description |
|--------|--------|-------------|
| 0 | 1 | Command ID |

**Response**:

| Offset | Length | Description |
|--------|--------|-------------|

## Tools Used

- [ ] Wireshark / nRF Connect / etc.

## References

- [Link to FCC filing]
- [Link to any existing teardowns]

## Contributors

- @username - initial research
