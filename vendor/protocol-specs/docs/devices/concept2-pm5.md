# Concept2 Performance Monitor 5 (PM5)

> **Status**: Spec Available (unverified) — active; Concept2 publishes the BLE spec
> **Protocol**: BLE
> **Manufacturer**: Concept2, Inc.
> **Manufacturer Status**: Active

## Overview

The PM5 monitor on Concept2's RowErg/SkiErg/BikeErg. Concept2 publishes its BLE interface, so it is a friendly documented target — pure peer-to-peer BLE, no cloud.

## Protocol Summary

Custom base UUID CE06xxxx-43E5-11E4-...; Device Info (0x0010), Control (0x0020, CSAFE command/response), Rowing (0x0030, status notifications with power/pace/stroke rate). GAP name `PM5 <serial>`.

See `device-specs/devices/concept2-pm5.yaml` for the full machine-readable spec.

## References

- <https://www.concept2.com/service/monitors/pm5/software>
