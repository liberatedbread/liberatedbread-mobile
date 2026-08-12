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

**Rebinding to a new network**: in place, remotely triggered, or physical reset
only. If the old network has to still be up, say so — that changes what a user
must do *before* replacing a router.

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
