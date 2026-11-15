# Nonin Onyx II 9560 — Research Notes

## Product & Company Status
- **Product**: Onyx II Model 9560 fingertip pulse oximeter with Bluetooth 2.0 Classic — the first wireless fingertip oximeter (2008). Professional/OEM telehealth device, long since discontinued; still sold as NOS by resellers ([Concord Health Supply](https://www.concordhealthsupply.com/Nonin-Onyx-II-9560-Bluetooth-Oximeter-p/non-9560.htm)).
- **Manufacturer**: Nonin Medical — **alive** (Plymouth, MN). Abandonment is at product level: the 9560 is superseded and no longer produced.
- **Transport**: Bluetooth 2.0 Classic supporting **both SPP and HDP** (Health Device Profile, IEEE 11073, Continua Version One certified) — per [MDPI review](https://www.mdpi.com/2075-4418/4/3/104) and the [9560 manual](https://www.medaval.ie/docs/manuals/Nonin-9560-Manual.pdf).
- **Cloud story**: certified to Microsoft **HealthVault** — which Microsoft **shut down on 2019-11-20** (announced April 2019). The HealthVault link was always optional; the device has no intrinsic cloud dependency and streams locally to any SPP/HDP host.

## Protocol Facts
- **SPP mode**: Nonin published the byte-level framing in the "Model 9560 OEM Specification and Technical Information" document; a mirror is at [numed.co.uk](https://www.numed.co.uk/files/uploads/Product/Nonin%209560%20Bluetooth%20Specification.pdf). The OEM spec documents the SPP data packet format, store-and-forward memory access (last 20 spot readings), and control commands.
- **HDP mode**: standards path — IEEE 11073-20601 oximeter specialization (MDC) over Bluetooth HDP/L2CAP. Interoperable with open 11073 manager stacks such as [signove/antidote](https://github.com/signove/antidote) (IEEE 11073-20601 stack, BlueZ HDP transport).
- Pairing is standard legacy BT pairing; the device was designed to connect to "cell phones, PDAs, PCs" per [pulsegmbh.de product page](https://pulsegmbh.de/p_spo2.html).

## APK Provenance
- **No companion app exists.** This was an OEM/integrator device; consumers were expected to use partner telehealth apps or HealthVault. Nothing to fetch via apkeep — this is expected and simplifies RE (protocol is vendor-documented).

## Local Feasibility Verdict
**Confirmed.** Two independent local paths: (1) plain RFCOMM/SPP with vendor-documented framing — usable with generic serial tools on Linux/Android/Windows; (2) standards-based HDP + IEEE 11073 via Antidote on Linux/BlueZ. Zero cloud.

## Safety
- Spot-check SpO2/PR readings, indicative use. Class II medical device originally; do not use for unattended clinical decisions.

## Open Questions
- Confirm exact SPP packet layout from the OEM spec PDF when writing the full spec (not reproduced here — read the vendor doc directly).
- Which pairing behavior the 9560 uses when bonded to a modern Android host (HDP support was deprecated and removed from recent Android; SPP path still works).
