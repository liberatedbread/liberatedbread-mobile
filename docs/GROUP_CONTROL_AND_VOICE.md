<!-- Copyright 2026 Pigs Can Fly Labs LLC
     SPDX-License-Identifier: Apache-2.0 -->

# Group control across both transports, and a voice surface

Design note for "turn all the TVs off" — one gesture in the app, one sentence to
an assistant. Nothing here is implemented yet; this is the shape of the work and
the reasoning behind the order it should land in.

## Where we actually are

The group subsystem is not the missing piece. `GroupOp`
(`lib/core/group_actions.dart`) already carries `turnOn` / `turnOff` /
`setBrightness` / `readBattery` / `readSensors`; `GroupRunner`
(`lib/services/group_runner.dart`) runs an op across members and reports
per-device progress as a stream of `GroupRunEvent`s; `DeviceGroupStore`
persists user groups; and the Groups tab already shows two kinds of group — the
user's own, and automatic by-kind buckets from `autoGroupsProvider`.

`DeviceCategory.tv` exists, with `pluralLabel` → **"TVs"**. The moment a TV can
be *saved*, a "TVs" group appears in the Groups tab with no UI work at all.
That is the one genuinely free part of this feature, and it is worth designing
towards deliberately rather than adding a bespoke TV screen beside it.

Four things stand in the way. They are independent, and only the third needs
anything from upstream.

### 1. Wi-Fi devices are never persisted

`SavedDevice` (`lib/services/saved_device_store.dart`) holds BLE ids.
`NetworkDevice` (`lib/models/network_device.dart`) has no store at all — it
exists for the lifetime of a scan and is then dropped. Its own header says why
a naive store would be wrong:

> a network device has no RSSI and no connectable flag, and it has an address
> that changes with DHCP rather than a hardware identity

Every TV in the catalogue is Wi-Fi. So today there is nothing for a TV group to
be built *from*.

### 2. Network control is trapped in a widget

The whole Wi-Fi send path — transport dispatch, the ECP2 signed-session
lifecycle, SOAP read-backs, Kasa framing — lives in private methods of
`lib/screens/network_device_screen.dart`, a 1417-line `StatefulWidget`. There is
no way to send a command to a network device without building that screen.
`GroupRunner`, meanwhile, takes a `BleService` and speaks GATT directly.

### 3. TV power is not a `turn_off` role

Every TV spec models power as `platform: "button"` with `commands: { press: … }`,
and the upstream schema *enforces* that a button binds exactly `press` and
carries no state. Group ops resolve strictly by entity action role — see the
header of `lib/core/group_actions.dart`, which explains that working role-first
is what makes bulk sends safe *by construction*: `advanced` commands and lock
verbs are unreachable from a fan-out because the resolver never sees raw command
names, so there is no blacklist to keep current.

That property is worth more than TV support, and this design does not trade it
away. The fix belongs upstream, and is written up as **P13** in
protocol-specs (`docs/contributing/spec-evolution.md`): TVs gain a
`platform: "switch"`, `name: "Power"` entity beside their remote buttons,
binding `turn_on` / `turn_off` where the hardware genuinely supports them, plus
a new `toggle` role for the sets whose only power channel flips state.

**Do not work around this locally.** `vendor/protocol-specs/` is a git subtree;
edits there are invisible upstream and fail CI. P13 lands upstream first, then
`./scripts/update-specs.sh` brings it down.

### 4. No voice surface

One `MethodChannel` exists in the entire repo (`lib/services/multicast_lock.dart`,
for the Wi-Fi multicast lock). No App Intents, no SiriKit, no Android shortcuts.

## What is actually reachable today

Worth stating plainly, because it makes the feature smaller than it looks. Of
the nine TV specs, only **Roku, Sony Bravia, Vizio and Panasonic Viera** are
controllable from this app: LG (websocket), Samsung (websocket), Hisense (MQTT)
and Android TV (TLS-protobuf) declare transports the Rust core does not speak,
so `qualify_network` returns `None` and they resolve to no controls at all.

Of those four, three have discrete power-off commands. Only Viera is
toggle-only. So a first cut of "turn all TVs off" correctly turns off Roku, Sony
and Vizio, and honestly reports that it left the Viera alone.

---

## The work

### A. Persist Wi-Fi devices

New `lib/services/saved_network_device_store.dart` plus a provider, modelled
directly on `saved_device_store.dart` / `saved_device_provider.dart` and reusing
`prefs_json_list.dart` — a JSON array under one prefs key, with per-record
defensive decoding so one corrupt entry cannot take the list down.

The identity question is the whole design. Key on something stable — the SSDP
`USN`, the mDNS instance name, or the serial from the device description — and
treat `host` as a **cache**, re-resolved from a targeted scan when a run starts.
Keying on `host` would produce a store that silently addresses a different
device after a DHCP lease change, which is worse than not persisting at all.

Carry `category` and `specKey` exactly as `SavedDevice` does, recorded when a
spec match resolves, so an out-of-range TV can still be classified and bucketed
without a round trip.

### B. Let a group hold both kinds of member

`DeviceGroup.deviceIds` gains a scheme prefix — `ble:…` / `net:…` — with
`DeviceGroup.fromJson` reading an unprefixed id as `ble:` so existing stored
groups migrate silently. `groupMembersProvider` then resolves against both
stores instead of only `savedDevicesProvider`.

`autoGroupsProvider` needs the same widening, and gets the "TVs" bucket for
free once it sees saved network devices. `isGroupable` and
`kNonGroupableCategories` stay exactly as they are — `tv` was never excluded.

### C. Extract a headless network sender

Pull `_send`, `_sendHttp`, `_sendKasa`, `_sendSoap` and the ECP2 session
lifecycle out of `network_device_screen.dart` into
`lib/services/network_command_sender.dart` plus a provider, with the transport
clients injected the way `lib/providers/network_control_provider.dart` already
injects them for tests. The screen becomes a consumer of the service.

**Land this as a pure refactor, with no behaviour change and no new feature
riding along.** It is independently reviewable, it shrinks the largest file in
`lib/`, and everything downstream depends on it. Doing it inside the group work
would make both halves harder to review.

### D. Make the runner transport-dispatching

`GroupRunEvent` and `GroupDeviceStatus` are already transport-agnostic — they
name a device id, a status and a detail string, with nothing GATT-shaped in
them. So the runner can either grow a dispatch step or gain a network sibling
emitting the same stream; either way the detail screen does not change.

One thing must **not** be carried across. `GroupRunner` runs strictly
sequentially, and its header explains why: `flutter_blue_plus` serializes all
BLE work behind one process-wide mutex whose waits are untimed, so parallel
connections would only queue invisibly and a wedged one would stall the queue
with nothing to say which device was at fault. **That reasoning is specific to
the BLE stack.** HTTP and SOAP sends have no shared mutex, and a ten-TV group
run one-at-a-time with generous timeouts would be needlessly slow. Network
members should run concurrently under a bounded pool.

Keep the existing discipline that does generalise: every step timed, every
member's failure attributable to that member, and `lib/core/stop_signal.dart`
reused for cancellation rather than re-rolled.

### E. Resolve ops for network entities, and the toggle rule

A network sibling to `resolveGroupWrites`, role-first exactly as today. The
GATT admission step has no analogue — there is no discovered service tree to
check a spec's promises against — so the network resolver's honesty comes from
the spec match alone.

Then the rule that makes a bulk power-off safe, as a **pure function** so it is
unit-testable with no network at all:

1. If `turn_off` resolves — send it. Done.
2. Else if `toggle` resolves **and** the entity declares a readable power
   state — read the state first, and send the toggle **only** if it reads on.
   If it reads off, skip: the device is already where the user asked it to be.
3. Else — skip, with an honest reason ("No discrete power-off, and this device
   does not report whether it is on").

A failed state read counts as **not confirmed on**, so it skips rather than
retries. Three specs volunteer the reason: on Vizio, Philips and Hisense the
state endpoint becomes *unreachable* rather than wrong when the set is asleep,
so a read that times out is itself evidence the TV is off.

Skipping is never silent dropping — that convention already runs through
`group_actions.dart` and the detail screen renders the reason per member. A
user whose Viera stayed on is entitled to know the app decided that on purpose.

### F. Rust: the `toggle` role

`rust/src/spec/bindings.rs` gains a `TOGGLE` role for the `switch` platform,
beside `TURN_ON` / `TURN_OFF`.

Add it to **both** role tables, not just `NETWORK_ROLES`. The comment above that
table is explicit about why:

> Kept beside the BLE `RoleSpec` table, and using the same role names on
> purpose: two tables that disagreed about what `switch` offers would give one
> device different controls depending on how it happened to connect.

A `toggle` known only to the network table would reintroduce exactly that
disagreement — and the role is not TV-specific in any case: `autobaba-led-backpack`
and `nyan-bt-image-controller` are both BLE and both already declare a
`power_toggle` command that nothing can currently bind.

Then regenerate:

```bash
flutter_rust_bridge_codegen generate
```

Never hand-edit `lib/src/rust/**` or `rust/src/frb_generated.rs`; CI fails on
drift between the bindings and `rust/src/api/**`.

### G. UI

Close to nothing. The Groups tab gets its "TVs" bucket from `autoGroupsProvider`,
`GroupOp.turnOff` already reads "Turn all off", and `group_detail_screen.dart`
generates its op buttons from `GroupOp.values` filtered by each member's
supported ops. The work is in making the data true, not in drawing it.

---

## Voice

### iOS — App Intents

Expose each saved group × op as an App Intent, so it surfaces in Siri and in
Shortcuts, and can be added to a Home Screen widget or an automation.

This works well for the case being asked about, and it is worth being precise
about why: **the TV case is the LAN case.** A background App Intent can drive
HTTP and SOAP sends fine. iOS restricts background BLE, so a *BLE* group op
invoked by voice will need the app foregrounded — which is a real limitation,
but not one that touches "turn all the TVs off".

### Android — a shortcut

`shortcuts.xml` plus a `MethodChannel` into the group runner, so Assistant and
Gemini can launch a group op. Android's third-party assistant hooks are thin;
what this realistically buys is a launchable shortcut, not a first-class voice
intent.

### What this does not reach

Alexa and Google Home. Those come from the Home Assistant route — a spec-driven
HA integration exposing the P13 Power switch as a `media_player`/`switch`, after
which "turn off the TVs" works through HA areas and `homeassistant.turn_off`
with **no group code at all**, and Assist, Google, Alexa and Siri-via-HomeKit
all inherit it from that one entity mapping.

That route is **deferred**, pending a wider rethink of how Home Assistant fits
the project. It is not designed out: keeping power semantics upstream in the
specs (P13) is exactly what keeps it open, because any future HA consumer reads
the same `switch` entity this app will.

### Platform tests are strict

`test/platform/ios_entitlements_test.dart`, `ios_info_plist_test.dart` and
`android_manifest_test.dart` assert over these files directly. Any native change
updates them in the same commit — they are not incidental coverage, they are the
reason the multicast entitlement has survived intact.

---

## Order to land it in

| Phase | Work | Unblocks |
|---|---|---|
| 1 | **P13 upstream**, then `./scripts/update-specs.sh` | every consumer |
| 2 | Extract `network_command_sender` (pure refactor) | 3 |
| 3 | Network persistence + mixed-transport groups | "TVs" group in-app |
| 4 | iOS App Intents + Android shortcut | Siri, Shortcuts |
| — | Home Assistant integration | deferred |

Phase 2 is worth starting even if the rest slips: it stands on its own as a
reduction of the largest file in `lib/`.

## Rules this work runs into

- **Never edit `vendor/protocol-specs/`.** It is a git subtree. P13 goes
  upstream; `./scripts/update-specs.sh` brings it down.
- **Never hand-edit generated FRB bindings.** Change `rust/src/api/**`, then
  `flutter_rust_bridge_codegen generate`.
- **Keep both transports whole.** A change to the Wi-Fi path must leave BLE
  working, and vice versa — which is the entire point of §D's warning about
  not exporting the BLE sequencing rule to LAN.
- **`scripts/ci-coverage-audit.sh` fails if any file under `lib/` is absent
  from the coverage report.** Every new file above needs a test reaching it,
  not merely a well-covered neighbour. That sets the real test burden for this
  feature, and it is worth planning the fakes early — `test/fakes/` already has
  hand-written doubles for the BLE service, the codec and the ECP2 socket, and
  no mocking framework is used.
- Mirror CI before finishing: `./scripts/test.sh`. Run
  `./scripts/ci-netdisco-tests.sh` deliberately when touching the Wi-Fi path.
