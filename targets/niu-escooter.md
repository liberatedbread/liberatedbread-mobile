# NIU electric scooter

## Target metadata
- target_id: niu-escooter
- app package_id(s): `com.niu.manager` (Android)
- device class: electric scooter / moped
- transport(s): cellular → NIU cloud (documented); BLE scooter ↔ phone (undocumented)
- local-only viability: **unknown, and that is the finding.** Every documented path is
  cloud. Whether local control is possible at all depends on what the BLE link actually
  carries — an open question nobody has published an answer to.

## Why this one is in scope
Textbook cloud dependency: the scooter reports to NIU's servers, the app reads from NIU's
servers, and authentication is an OAuth2 token issued by NIU. If the service is retired the
app stops working and every documented data path dies with it. Project scope rules say
cloud-only devices get documented and deprioritised — so this entry exists to record the
dependency accurately and to point at the one experiment that could change the picture.

## Known facts (public + observed)
- Account host `https://account-fk.niu.com`; API host `https://app-api-fk.niu.com`. Older
  captures show `app-api.niu.com`. Hosts appear region-dependent.
- Auth: `POST /v3/api/oauth2/token` on the account host → OAuth2 bearer token. Most data
  calls additionally need the scooter serial number (`sn`).
- Endpoints: `/v5/scooter/list`, `/v5/scooter/motor_data/index_info` (SoC, position,
  odometer), `/v3/motor_data/battery_info`, `/motoinfo/overallTally`, `/v5/track/list/v2`.
- Mixed versioning (v3 and v5 both live) is the API's real shape, not a transcription error.
- Original capture work covers **dual-battery scooters only**; single-battery response
  shapes may differ.
- BLE: exists, used by the app in proximity. No public UUIDs, framing or pairing flow.
- Observed: nothing. All `reported` from maintained third-party integrations.

## Device discovery signals
- Cloud: not a discovery problem — the account lists the scooters.
- BLE: **unknown.** Advertised name, service UUIDs and address behaviour all need a first
  scan. This is the missing piece.

## Threat model + guardrails
- Scope: **owner's own scooter and own account only.**
- Credentials and tokens: a token grants access to the owner's scooter including its live
  location. Capture only from your own account; never commit a token, serial number or
  account identifier to this repo. Treat a captured token as a password.
- Location data is personal data — a scooter's track history is a movement record of a
  person. Handle captures accordingly and do not attach raw ones to issues.
- Cloud calls hit a third party's production service: read-only, at human rates. No
  enumeration of serial numbers, no probing endpoints that were not observed in the app's
  own traffic, nothing against an account that is not yours.
- Any BLE command discovery happens on a stationary scooter, on the centre stand.

## First experiments (do these first)
1) **BLE scan** a powered scooter with nRF Connect; record advertised name, address,
   service and characteristic UUIDs. Nothing about the local path is known until this exists.
2) HCI snoop log across one app connect plus one simple in-proximity action.
3) Answer the decisive question: **is the BLE link a full control channel, or only a
   proximity/unlock handshake with everything else deferred to the cloud?** That determines
   whether local control is achievable at all, and therefore whether this target is worth
   pursuing further or stays documented-and-deprioritised.
4) Cloud side, only if useful: confirm the endpoint list against your own account with
   mitmproxy, and note single- vs dual-battery response differences.

## Protocol hypotheses (to validate)
- BLE is likely a short-range control/unlock channel with telemetry still routed via
  cellular — if so, local telemetry may be impossible without firmware work.
- The scooter may accept commands only when the app has a valid cloud token, making the
  BLE path cloud-gated even in proximity. Adjacent scooter platforms bind a
  server-issued key at pairing; check whether NIU does the same.
- Region-specific hosts suggest per-region deployments that may differ in API version.

## Control surface inventory (what a replacement app would need)
- Core (MVP), cloud path: battery state, position, odometer, ride history — everything the
  documented endpoints already provide.
- Core (MVP), local path: unknown until the BLE question above is answered.
- Advanced: any command that moves or unlocks the vehicle — gated behind explicit
  confirmation, stationary only.
- Non-goal: anything touching a scooter or account that is not the operator's.

## Evidence checklist
- [ ] nRF Connect scan export (BLE UUIDs) — the blocking item
- [ ] HCI snoop log of app connect + one action
- [ ] Determination: BLE = full control channel vs proximity handshake
- [ ] Endpoint confirmation against an owned account (no tokens committed)
- [ ] Single- vs dual-battery response shape comparison

## Spec output (clean-room)
- `docs/devices/niu-escooter.md`
- `device-specs/devices/niu-escooter.yaml` — a `cloud` spec (`required: true`) with hosts,
  OAuth2 shape, endpoints, `failure_mode` and `data_leaves_device`. A spec may satisfy the
  schema on `cloud` alone, which is how "cloud-only, no local path" becomes machine-readable
  rather than prose.
- `local_access: replacement_hardware` records the only shipped local route — swapping the
  motor controller for an aftermarket Bluetooth one — with `covers` limited to drive
  parameters and `not_covered` listing telemetry, GPS and alarm as still cloud-tethered.
  Fitting one frees the throttle map, not the scooter.

## Open questions
- Does the BLE link work with the cloud unreachable?
- Do single-battery models use different endpoints or just different response shapes?
- Is there an on-scooter diagnostic connector as a third path?

## References (URLs only)
- https://github.com/Bonnee/niu-app-api
- https://github.com/marcelwestrahome/home-assistant-niu-component
- https://github.com/cascha42/niu-info
- https://github.com/ub4raf/Ninebot-PROTOCOL
- https://play.google.com/store/apps/details?id=com.niu.manager
