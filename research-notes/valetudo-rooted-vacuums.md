# Valetudo — cloud-replacement for rooted robot vacuums — Research Notes

## What it is
Valetudo (Hypfer/Valetudo, actively maintained; release 2025.08.0+) is
open-source software installed *on the robot itself* that replaces the vendor
cloud connection with a local stack: web UI on the robot's port 80, a REST
API (`/api/v2`, Swagger-documented), and MQTT for Home Assistant
autodiscovery. The vendor app and cloud become unnecessary; the robot can
be permanently firewalled from the internet. Rooting research is by Dennis
Giese (dontvacuum.me); custom firmware images via Dustbuilder
(dustbuilder.dontvacuum.me).

## Supported robots (exhaustive upstream list, valetudo.cloud, 2026-08-07)
- **Xiaomi**: V1, 1C (dreame.vacuum.mc1808 only), 1T, P2148 (Ultra Slim),
  Vacuum-Mop P, Vacuum-Mop 2 Ultra, X10 Plus
- **Dreame**: D9 (non-Max, 3 buttons), D9 Pro, F9, L10 Pro, Z10 Pro,
  W10/W10 Pro, L10s Ultra, D10s Pro/Plus, L10s Pro Ultra Heat, L20 Ultra,
  X30 Ultra, L40 Ultra, X40 Ultra, X40 Master
- **Roborock**: S4, S4 Max, S5, S5 Max, S6, S6 Pure, S7, S7 Pro Ultra,
  Q7 Max (NAND-era Q7 Max units may fail — check before buying)
- **MOVA**: Z500, S20 Ultra, P10 Pro Ultra
- **Viomi**: V6, SE (never attempt viomi.vacuum.v8 — brick risk)
- **Eureka**: J12 Ultra, J15 (Pro/Max) Ultra, E20 Plus/Evo Plus
- **Cecotec**: Conga 3290/3790; **Proscenic**: M6 Pro; **Commodore**:
  CVR 200; **IKOHS**: Netbot LS22 (these four are 3irobotix CRL-200S family)

## Rooting = the account-free path
This is the only fully account-free local-control route for the
Xiaomi-ecosystem generation: no Mi/Dreame/Roborock account is needed at any
point for most models. Methods per family (docs on valetudo.cloud):
- OTA exploit (pre-2020-03 Xiaomi V1 — laptop only, no disassembly)
- 3.3 V USB-UART to the debug connector + Dreame breakout PCB (most
  Dreame-made units; try 500000 baud if 115200 is garbage)
- ADB (3irobotix/Vacuum-Mop P family; flash Viomi V6 firmware recommended)
- Dustbuilder-generated firmware + OTA/fastboot flashing
Verification traps documented upstream: hardware revisions hiding under one
marketing name (Xiaomi 1C, Dreame L20 Ultra serial R2394 vs R2253, Q7 Max
NAND era), secure-boot firmware versions (e.g. L10 Pro ≥ FW 1138), and
late-2025 Dreame units with negative miio deviceIds needing a manual fix.

## What needs cloud
Nothing, after rooting. Provisioning on supported models can be done without
any vendor account (Valetudo 2025.08.0 discussion notes newer robots expose
local provisioning interfaces). Map data, schedules and no-go zones live on
the robot (Valetudo RE fork adds Roborock map save/load).

## Open questions
1. Support is bounded by 0-day availability — newly released models are
   generally NOT rootable; check the list before purchase.
2. Documenting Valetudo's REST/MQTT surface as the repo spec would make the
   spec client-agnostic (any LAN host can drive the robot).
