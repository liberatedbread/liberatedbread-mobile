# Revolv Hub — Research Notes (REJECTED, canonical dud)

## What it was
2013-era red teardrop hub with seven radios (Wi-Fi, Zigbee, Z-Wave, Insteon,
433/900/915 MHz) and a "lifetime subscription" pitch. Acquired by Nest
2014-10.

## Timeline (verified)
- Nest announced the service shutdown February 2016; **all hubs were remotely
  bricked 2016-05-15** — app and hub ceased to function
  ([VentureBeat 2016-04-04](https://venturebeat.com/ai/alphabets-nest-will-permanently-turn-off-all-revolv-hubs-on-may-15-2016),
  [Hackaday 2016-04-07](https://hackaday.com/2016/04/07/alphabet-to-turn-off-revolvs-lights/)).
- Became the canonical "who owns your hardware" case; FCC commented; owners
  were eventually offered compensation.

## Verdict: dud — confirmed
- The hub was a thin client: all logic and control in Revolv's cloud; no
  local API, no local web UI, no documented ports.
- Post-brick, no community resurrection gained traction (radios sat behind a
  locked-down SoC with no published boot path); a decade on there is still no
  local-control project of record.
- This is the reference example of cloud-bricked hardware with zero local
  fallback. Rejected.

## Note for the repo
Useful only as a cautionary entry in any "dead ecosystem" index — there is
nothing to specify.
