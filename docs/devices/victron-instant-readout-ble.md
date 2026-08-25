# Victron Instant Readout (BLE)

> **Status**: Spec Available (unverified) — active; Victron published the format
> **Protocol**: BLE
> **Manufacturer**: Victron Energy
> **Manufacturer Status**: Active

## Overview

A read-only BLE telemetry broadcast most modern Victron products emit (MPPT chargers, BMV/SmartShunt monitors, inverters, SmartLithium). Victron itself published the advertisement format — no connection, no cloud.

## Protocol Summary

BLE manufacturer data, company id 0x02E1, record type 0x10, AES-CTR encrypted with a per-device key extracted once from VictronConnect. Record types 0x01 Solar Charger, 0x02 Battery Monitor, etc.

See `device-specs/devices/victron-instant-readout-ble.yaml` for the full machine-readable spec.

## References

- <https://communityarchive.victronenergy.com/questions/93919/victron-bluetooth-ble-protocol-publication.html>
- <https://github.com/keshavdv/victron-ble>
