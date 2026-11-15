# Target: June Intelligent Oven

Execution plan: `../JUNE_OVEN_PLAN.md`. This file is the evidence brief.

## Target metadata
- target_id: `june-oven`
- app package_id(s): `com.junelife.companion` (Android, final 1.24.1.11,
  versionCode 1240111); `com.junelife.ios.companion` (iOS, final 1.24.2,
  2022-11-02). Weber's current grill app `com.weber.connect` shows manifest
  activities under `com.junelife.companion.app.*`, so the *phone app* appears to
  share June's Android lineage. Do not extend that to the oven — see §"Oven
  firmware is bespoke" below.
- device class: countertop convection oven, 5" touchscreen, interior camera
- transport(s): **Wi-Fi → vendor cloud only.** No LAN API, no BLE control path,
  no AP-mode provisioning. Gen 1 and Gen 3 carry BLE hardware; no BLE service is
  documented in use.
- local-only viability: **low.** Every companion-facing function is relayed
  through two vendor hosts. Nothing on stock hardware speaks a local protocol.
  This is a `cloud.required: true` / `local_access.status: none_known` device.

## Known facts (public + observed)

Public claims (paraphrased):
- Weber retires the June app and all cloud services **2026-09-22**; the oven
  keeps cooking from its touchscreen. Lost: remote control, live camera,
  recipes/June Premium, push notifications, and all software updates.
- June states food recognition runs entirely on-device and needs no internet —
  so it survives, frozen at whatever model the oven holds on the cutoff date.
- June's own documentation states a new or factory-reset oven **requires** a
  Wi-Fi connection and a software download on first boot. This is the brick
  risk: reset units after 2026-09-22 may not be recoverable.
- Three hardware generations under FCC grantee 2AJGA. Gen 1/2: NVIDIA Tegra K1,
  2 GB RAM, 8 GB flash. Gen 3 (2020, JCH03): MediaTek MT8385, 2 GB LPDDR4,
  16 GB soldered eMMC. Firmware "juneOS" is AOSP-derived. Final firmware
  1.24.1.34 — preserved privately by a former June engineer, never published.

Observed / derived (not by us — see References):
- `keithah/homebridge-june-oven` contains a clean-room protocol spec verified
  end-to-end against a physical oven (model `meerkat`), plus working Python and
  TypeScript implementations. Provenance: Android emulator + Frida, hooking
  libsodium for signed plaintext and conscrypt's `SSLOutputStream.write` for
  pre-encryption frames.
- `mvanhorn/printing-press-library` → `internal/june/testdata/vectors.json`:
  byte-exact synthetic conformance vectors — 72-byte signatures for 11011 and
  11002 frames, a worked SRP-6a exchange, a Damm example, a NaCl secretbox
  example. No real credentials. **This is the test oracle for any
  reimplementation.**
- APK static recon (Kimi report, androguard 4.1.4): three host families
  (`api.`, `messaging.`, `recipes.junelife.com`) each with a `dev-` twin;
  20 deduped REST paths; OkHttp `CertificatePinner` with three hardcoded
  `sha256/` SPKI pins; SpongyCastle SRP-6a classes; `libsodiumjni.so` in seven
  ABIs. No "firmware", "OTA", "mqtt" or "amazonaws.com" strings — firmware
  delivery is oven-side and out of APK scope.

APK identity for reproducibility (**do not commit the binary** — see
`docs/CLEANROOM_RULES.md`):
- `com.junelife.companion` 1.24.1.11, 21,032,158 bytes
- sha256 `e9de2c3af3fd07a12984f2b460f51ee8139df5156e0b8a20827aabecc03635b7`
- signer SHA1 `A7:12:63:B9:E5:76:BC:D5:95:0C:B5:79:8D:87:8B:BF:92:8E:C5:53`,
  DN `CN=June, OU=June, O=June, L=San Francisco`

## Bluetooth: intended, never shipped

Owners remember "talk of adding BLE support". That talk is real and it traces to
exactly one source. A subreddit sweep — 100 posts and 250 comments across
2025-01 → 2026-08, searched for `bluetooth|ble|local control|lan` — returns a
single substantive claim, from a self-identified former June/Weber oven software
engineer (u/empiricalis), 2026-07-26:

> "At one point I had done some R&D work on unifying the oven and grill
> software, which *could* have allowed for local control via Bluetooth. That
> was, obviously, deprioritized when the oven was discontinued."

Read that precisely, because the loose version of it will waste someone's month:

- It describes **R&D toward putting the oven on Weber's grill software stack**
  (which is BLE-based — see the iGrill note at the end of this file). Local BLE
  control would have been a *consequence* of that unification, not the project.
- "*could* have allowed" is conditional. This is not "we built it and never
  shipped the client." There is no claim that BLE control firmware was ever
  written, let alone flashed to a retail oven.
- It was deprioritized when the oven was discontinued (2023). The unification
  never happened — which is itself evidence the two stacks stayed separate.

**Conclusion: assume no BLE control surface exists in any shipped oven
firmware.** The hardware is there (Gen 1: BT classic + BLE per FCC; Gen 2:
Wi-Fi grants only; Gen 3: BT classic + BLE re-added, "a new chip set… to improve
connectivity"). The intent was there. The firmware, on all available evidence,
is not. Weber's own FAQ says "Bluetooth is not supported at this time."

This is worth one cheap experiment and no more: **stand a powered oven next to a
BLE scanner and see whether it advertises anything at all.** Liberated Bread
already does exactly this. Nobody has published the result for any generation.
A negative closes the question permanently; a positive is a genuine discovery.
Do not budget beyond that scan.

Everything else in the community discussion is **LAN** advocacy, not BLE — the
petition, the "release a final firmware with local network access" asks, the
Bose SoundTouch precedent. Those are requests to Weber, not evidence of a
capability.

## Oven firmware is bespoke

The same engineer, 2026-07-24, on whether Weber's other connected products share
code with the oven:

> "essentially none of the code of the June Oven is shared with Weber's other
> connected products. Lessons, concepts, terminology? Sure. The actual oven code
> is bespoke, and again, the institutional knowledge is essentially gone."

This **conflicts with** the community belief (u/stryfedonkey, 2026-08-05) that
"WeberOS was apparently built on or was integrated into JuneOS", and it qualifies
the APK-lineage evidence in the metadata above. The reconciliation that fits all
the evidence: the *phone apps* share a codebase; the *oven firmware* does not.

Consequence for anyone planning work: **watching Weber's grill line is not an
early-warning feed for June oven firmware or protocol.** It may still be one for
the companion app lineage. Do not size a workstream on the stronger claim.

## Other facts from the same source

Same engineer, same threads — all first-hand, none independently verified:

- **"The oven ships in a locked-down 'user' mode with ADB and terminal access
  removed."** This closes the cheapest firmware-access path before anyone
  spends a week on it.
- He has **preserved the final firmware, 1.24.1.34**, and as of 2026-07-27 was
  attempting to **flash it to an oven with no internet connection** — which is
  precisely the fix for the brick-risk population. Unpublished; outcome unknown.
  Worth following.
- He has publicly offered to help more actively **if Weber releases him from his
  NDA**. That, not a reverse-engineering breakthrough, is the highest-leverage
  thing the petition could actually win.
- On the Homebridge plugin: "This plugin is still toast … when the server is
  shut down." Confirms it is a cloud client, not a local one.

## Device discovery signals
- BLE: no service or advertisement documented for any generation, and per the
  section above, probably none exists. Radios present on Gen 1 and Gen 3.
  Unexplored — the scan above is the open experiment.
- Wi-Fi:
  - SSID patterns: none — there is no AP-mode provisioning. Wi-Fi credentials
    are typed on the oven's own touchscreen.
  - mDNS / UPnP: none observed, none documented.
  - Ports: one unverified community report of an open **TCP 8156** on the oven's
    LAN interface. Unconfirmed, unidentified service. Treat as a hypothesis to
    be settled by `nmap -sV` against a real oven, not as a fact.
- Cloud: discovery is not a scan at all. An owner obtains an 8-digit PIN from
  the cloud, types it into the oven, and the oven's identity arrives via
  `GET /2/devices/{deviceId}/associated`.

## Threat model + guardrails
- Scope: owner-operated repair on hardware the user owns, on their own network.
- The oven's 1 Hz cook-control loop and its temperature-limiting hardware run
  on-device and are **never** touched. We send the same five opcodes the vendor
  app sends; we do not modify oven behaviour.
- The `10020` ack vocabulary (`door-open`, `not-ready`, `cleaning`,
  `not-allowed`) is the protocol's own safety channel. Reimplement it verbatim;
  never collapse it into a generic failure, never work around it.
- June shipped a remote-preheat disable and a 30-minute no-food auto-off after
  documented 2019 incidents of ovens self-preheating. Both live on the oven.
  Preserve them; do not offer any path that defeats them.
- Non-goals: firmware modification, flashing, OTA replacement, and building or
  hosting a replacement cloud. All out of scope for this repo.
- Never commit tokens, `oven_id`, `device_id`, Ed25519 seeds or device
  passwords. An Ed25519 seed is a key the oven trusts to start a heat cycle.

## First experiments (do these first)

Only the first needs no hardware. Experiment 4 is new and cheap.

1) **Conformance first, hardware never.** Implement the 72-byte signature, the
   canonical envelope, SRP-6a and Damm against `vectors.json`. Byte-exact
   agreement proves wire compatibility with no oven and no network. Everything
   else is downstream of this passing.
2) Pair a real oven while the cloud lives, and **export the pairing material**
   (`oven_id`, `device_id`, `device_name`, `password`, `ed25519_seed_hex`).
   After 2026-09-22 this set cannot be re-minted.
3) Capture one full control loop: `status` → `11002` preheat → `10020` ack →
   `10018 active` → `10013` telemetry → `10011` camera frame → `11004` cancel →
   `10017` → `10018 idle`.
4) **BLE-scan a powered oven** (Gen 1 and Gen 3 especially) and record whether it
   advertises anything at all. Unpublished for every generation, five minutes of
   work with the app we already ship, and it settles the Bluetooth question
   above in whichever direction it falls.
5) **Passive-capture 24 hours of the oven's traffic** behind a gateway you
   control, across an overnight update window, a cook and a reboot. This
   outranks everything below it: the DNS query log names the update host, which
   no amount of APK analysis can reach, and it is the one item here that becomes
   impossible on 2026-09-22. `docs/devices/june-oven-lan-recon.md` Tier 0.
6) `python scripts/june_discover.py --address <ip>` — settles the port-8156
   question and checks whether ADB-over-TCP really is absent. Expected to find
   nothing; publish the nothing.
7) Only with a spare oven and a bench: DNS-repoint `messaging.junelife.com` and
   walk the certificate ladder in `docs/devices/june-oven-lan-recon.md` Tier 2.
   This decides whether any replacement cloud can ever work. **Out of scope for
   Liberated Bread**, and — contrary to the research report — it is *not* racing
   the shutdown: you answer the DNS query yourself, so Weber is never in the
   path and the oven only has to keep dialling. Do experiment 5 first; this one
   keeps.

## Protocol hypotheses (to validate)

Almost none — this protocol is documented, not hypothesised. The full wire
format is in `../JUNE_OVEN_PLAN.md` §3. Genuinely open:

- Does the **oven** pin TLS? (The *app* provably does — three hardcoded SPKI
  pins. The oven is unmeasured.) Decides whether any replacement cloud is
  reachable. Experiment 7.
- What is TCP 8156? Experiment 6.
- Where does the oven get the time, and what happens to TLS when its clock is
  wrong after the cloud dies? May gate a replacement cloud independently of
  pinning. Experiment 5 answers it for free.
- Does a powered oven advertise over BLE at all? Expected answer: no. Settled by
  experiment 4; see "Bluetooth: intended, never shipped" above before spending
  any time here.
- Full `primitive_type` vocabulary. Only `bake` and `roast` are confirmed
  on-oven; the app has broil, air-fry, toast, dehydrate, pizza.
  `/2/devices/{id}/features` was never captured.
- Cook-program schema beyond `food.plan.steps[].temperature_cavity`.
- The `recipes.junelife.com` surface — entirely uncaptured, and unreachable
  after 2026-09-22.

## Control surface inventory (what a replacement app must support)
- **Onboarding/pairing**: generate PIN → display for the user to type on the
  oven → act as SRP-6a *server* → seal `companion_info` → POST → wait for the
  second `10026` (never DELETE early) → resolve `oven_id` via `/associated`.
- **Core controls (MVP)**: preheat (`11002`, mode + target temp), cancel
  (`11004`), set timer (`11006`), change target (`11005` — rejected mid-cook;
  the working pattern is cancel-and-restart).
- **Live state**: `10018` idle/active; `10013` cavity temperature, probe array,
  progress; `10014`–`10017` cook-plan transitions.
- **Camera**: `10011` frames, ~1 fps stills, pre-signed URLs expiring ~300 s.
  Never video.
- **Error handling**: surface `10020` statuses verbatim. Correlate
  `request_order` to your `order`; a frame with a bad signature produces
  *nothing at all*, so absence of an ack is a real, distinguishable state and
  must time out rather than hang.
- **Persistence**: Ed25519 seed and device password in the platform
  keychain/keystore — the same discipline the HA token already gets. Token is
  7-day and re-minted by re-registering `device_id`.
- **Settings**: endpoint base URLs must be user-overridable. This is what makes
  the client outlive the vendor.

## Evidence checklist
- [x] APK version code + hashes + signer DN (above)
- [x] Protocol constants, message catalog, signature construction
- [x] Conformance vectors identified (`vectors.json`)
- [ ] HCI snoop log — n/a, no BLE path known
- [ ] PCAP of oven↔cloud traffic — **none has ever been published**, and after
      2026-09-22 none can be. This is the permanent gap, and the only item on
      this list with a hard expiry. Playbook: `docs/devices/june-oven-lan-recon.md`
- [ ] Oven's DNS query log → the OTA host, unreachable by APK analysis
- [ ] NTP behaviour and clock source
- [ ] DHCP hostname / option-55 fingerprint / MAC OUI per generation
- [ ] Port 8156 identification (`scripts/june_discover.py`)
- [ ] Oven-side TLS trust behaviour (not deadline-bound — see experiment 7)

## Spec output (clean-room)
- `device-specs/devices/june-oven.yaml`
- `docs/devices/june-oven.md`

## References (URLs only)
- https://github.com/keithah/homebridge-june-oven
- https://github.com/mvanhorn/printing-press-library
- https://www.reddit.com/r/Juneoven/comments/1v75wr7/new_and_reset_ovens_will_be_bricks_after_922/
- https://www.change.org/p/demand-a-final-firmware-update-for-june-ovens
- https://en.wikipedia.org/wiki/June_(company)
- https://github.com/sanjay900/igrill

## Adjacent target, not part of this one
`sanjay900/igrill` — Weber iGrill BLE probe. Vendor services
`06EF000x-2E06-4B79-9E33-FCE2C42805EC`, `64AC000x-4A4B-4B58-9F37-94D3C52FFDF7`,
`6C91000x-58DC-41C7-943F-518B278CEAAA`; the AES challenge is bypassed by writing
back the device's own encrypted challenge unmodified. **No protocol overlap with
June** — the connection is corporate (Weber owns both), not technical. It is BLE
and would fit the existing mobile architecture with no new transport work, so it
is worth its own target file. Do not fold it into June.
