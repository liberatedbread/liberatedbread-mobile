# PrusaLink (Prusa MK4 / XL / Mini)

> **Status**: Spec Available (unverified) — active; vendor-documented OpenAPI
> **Protocol**: WiFi
> **Manufacturer**: Prusa Research
> **Manufacturer Status**: Active

## Overview

PrusaLink is Prusa's on-printer web server (MK4, MK3.9, XL, Mini) with a published OpenAPI spec. Local HTTP, no cloud.

## Protocol Summary

HTTP /api/v1 (info, status, job, files upload/print) over HTTP Digest (maker + password) or an X-Api-Key header. A legacy OctoPrint-compatible /api/ surface exists for older clients.

See `device-specs/devices/prusalink-local-api.yaml` for the full machine-readable spec.

## References

- <https://github.com/prusa3d/Prusa-Link-Web/blob/master/spec/openapi.yaml>
