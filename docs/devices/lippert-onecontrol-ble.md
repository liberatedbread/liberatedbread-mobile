# Lippert OneControl BLE Gateway

> **Status**: Spec Available (untested)
> **Protocol**: BLE GATT with application-layer unlock
> **Manufacturer**: Lippert Components / LCI (active)

## Safety

This gateway can move RV awnings, slide-outs and levelling jacks, and can
control a generator. A command sent without a person watching the mechanism
can crush someone, damage the vehicle or create a carbon-monoxide hazard.
Start with read-only discovery and status. Keep people, pets and obstructions
clear, use the manufacturer's interlocks, and never experiment while the RV
is occupied by someone unaware of the test.

## Overview

The spec covers the Unity X270D, X270L, X1.5 and X180T gateways (the X4 is
named but not scoped):
`device-specs/devices/lippert-onecontrol-ble.yaml`. It records the
advertisement, the pairing variants, the GATT initialization order, and the
decoded MyRvLink command templates for lights, relays, HVAC zones and the
generator. This project has not driven a gateway from the document.

The spec is incomplete. It was first published truncated, and the blocks it
relied on (the TEA unlock and step-2 key layouts, the COBS/CRC-8 framing,
the event and device-table layouts, the advertisement TLVs and the X180T
IDS-CAN tunnel) were never in the repository. Its `remaining_unknowns`
lists each gap; the facts live in the community integration
[phurth/ha-onecontrol](https://github.com/phurth/ha-onecontrol) and have to
be re-derived from there. Awning commands are not declared at all.

## Setup and pairing

Two pairing routes exist. Do not assume that one gateway supports both.

### Push-to-Pair gateways

1. Scan for a name beginning `LCIRemote` and check the pairing-available bit
   in the manufacturer data.
2. Begin pairing, then press **Connect** on the OneControl panel. Depending on
   the panel this is a physical or on-screen control.
3. Connect immediately, request MTU 185 and complete a Just Works bond. On
   BlueZ, register a NoInputNoOutput agent first.
4. Run the spec's initialization: unlock on `0x0012`/`0x0013`, then subscribe
   to `0x0034` and `0x0011`.
5. If a four-byte seed arrives on `0x0011`, ask for the six-digit owner-tag
   PIN and answer with the step-2 key described in the spec. Some X270L units
   use this application-layer check even though their BLE bond was Just
   Works.

### PIN gateways

1. Read the six-digit PIN from the gateway's owner tag.
2. Connect directly from a local Bluetooth adapter with an agent that returns
   that PIN as the SMP passkey.
3. Run initialization and answer any application-layer seed as above.

An ESPHome Bluetooth proxy cannot relay the passkey exchange and cannot share
a BlueZ host's bond. Pair from the radio that will run the client.

Do not publish the sticker PIN, derived keys, a unit's MAC address or its RV
configuration. Those belong to the owner, not to the protocol document.

## Factory reset and rebinding

No reset that clears phone bonds is established. The gateway also stores the
RV manufacturer's output mapping, switch inputs and interlocks; losing that
configuration is not an acceptable experiment. Do not send a reset or
configuration write speculatively.

To add a phone or host, repeat the appropriate pairing route with a fresh
Connect press or the sticker PIN. Whether a new bond evicts an older one is
unknown. There is no Wi-Fi network to rejoin.

## Protocol summary

Authentication has three separate layers: SMP bonding, an application-layer
TEA unlock on every connection, and on some gateways a second PIN-derived
answer. A generic BLE client cannot skip the latter two. The YAML declares
the initialization order, the relevant UUIDs, the seed sizes and byte order,
the advertisement variants and its remaining unknowns, but not the TEA
details or the step-2 key layout. Every MyRvLink frame is COBS-encoded with
a CRC-8, so its custom protocol handler is required for the command surface;
no generic entity support is claimed.

## References

The spec links the public
[phurth/ha-onecontrol](https://github.com/phurth/ha-onecontrol) integration
(MIT), which every byte here comes from, and cites the issue reports that
distinguish Push-to-Pair, application-PIN and SMP-PIN variants. Those
community findings are `reported` here, not hardware verification by this
project.
