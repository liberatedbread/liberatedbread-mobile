# Pairing, Bonding and Unpairing

A device that answers a scan and then refuses to talk is not broken, and the
protocol is not wrong. Something below the protocol wants a pairing that has
not happened — or remembers one that has.

This is the layer underneath everything else documented here, and until
recently the schema had nowhere to put it. `device.pairing` is that place.

!!! note "Four different things, and only two of them are 'setup'"
    They are distinguished deliberately, and `device-specs/schema.json` keeps
    them apart:

    - **`device.discovery`** — finding the device. See
      [WiFi Discovery](../devices/wifi-discovery.md).
    - **`device.pairing`** — whether a client must pair or bond with it before
      the control surface answers, and what a person has to do at the hardware
      for that to be possible. This page.
    - **`device.setup`** — one-time provisioning: giving a factory-fresh device
      network credentials and an owner. See
      [Initial Device Setup](device-setup.md).
    - **`initialization`** — the handshake run on *every* connection.

    A device can need all four, or none. Most BLE sensors need only the first.

## Say no out loud

The most common and most useful answer is that nothing pairs:

```yaml
device:
  pairing:
    required: false
    confidence: medium
    security_mode: none
    bonding: none
    enter_pairing_mode:
      required: false
```

That is four lines to say "connect and go", and it is worth writing because
silence says something different to every reader. An implementer who assumes
the worst goes looking for a pairing flow that does not exist; one who assumes
the best ships something that breaks on the first device that does bond. The
block is required on every BLE spec for exactly this reason — `required:
unknown` is an honest third answer, and it is still an answer.

## The two fields people conflate

`security_mode` says what the device **demands**. `bonding` says what it
**stores**. They are separate because the pair of them is what predicts the
failure everyone eventually hits.

| security_mode | Means |
|---|---|
| `none` | No link-layer pairing at all. Characteristics are readable and writable on a bare connection. |
| `just_works` | Pairing happens but is unauthenticated — no MITM protection. What most consumer BLE hardware does. |
| `passkey_entry` / `numeric_comparison` / `out_of_band` | The authenticated LE Secure Connections methods. Someone has to read something off the device. |
| `legacy_pin` | BR/EDR or LE legacy pairing with a fixed or printed PIN. |
| `network_join` | Admission to a mesh with a network key — what Zigbee and Z-Wave inclusion actually are. |
| `app_layer` | The transport asks for nothing; the real authorisation sits above it, in `initialization` or a command exchange. |

`none` and `just_works` get used interchangeably and they are not the same
fact. `none` means nothing is stored on either side, so every connection
starts clean. `just_works` means a bond **is** established and persists, which
is what makes the device stop answering a second client three weeks later. An
implementer who reads one as the other ships something that works perfectly on
a fresh device and fails on a used one.

`bonding: optional` alongside `security_mode: none` is a real combination, not
a contradiction: the device demands nothing, but a central that starts pairing
anyway — which most OS stacks will do on an insufficient-authentication error,
without the application asking — gets a bond the device is happy to keep.

## Exclusivity: the failure that looks like a protocol bug

From `docs/protocols/ble-common.md`, and worth repeating because it costs
people days:

> The failure that looks like a protocol bug but is not: a device that refuses
> to connect is usually already connected to something else — a phone with the
> vendor app open in the background, or an OS-cached bond quietly reconnecting.

`exclusivity` is where that stops being folklore:

```yaml
    exclusivity:
      single_connection: true    # one central at a time
      single_bond: true          # one stored bond — a new client REPLACES the old
      recovery: >
        Close the vendor app before connecting. The monitor holds exactly one
        client key, so pairing a second phone unbinds the first.
```

`single_connection` and `single_bond` fail differently and both present as a
timeout. `recovery` is the actionable half — what the user must actually go and
do — and it is the field a consumer puts on screen.

## Entering pairing mode, and leaving it

Hardware that is not pairable all the time needs a person, and `required: true`
without saying how is worse than silence: the reader now knows there is a step
and still cannot take it. A convention test enforces that.

```yaml
    enter_pairing_mode:
      required: true
      window_seconds: 30
      indicator: "The ring LED lights to show the lock is discoverable."
      indicator_glyph: "devices/nuki-smart-lock/ring-led-pairing.svg"
      procedures:
        - name: "Hold the lock button until the ring LED indicates it is discoverable"
          verified: false
          basis: "Nuki's public BLE API documentation."
          glyph: "devices/nuki-smart-lock/pairing-button-hold.svg"
          steps:
            - action: "Press and hold the button on the face of the lock."
              actor: user
```

`window_seconds` matters more than it looks. A client that scans, prompts the
user and then connects can easily spend a thirty-second window on its own UI.

`unpair` is the other end, and it exists as its own block because it is
routinely confused with a factory reset. They are different in the way that
matters to a user: unpairing moves a device to a new phone, and a reset also
costs them its name, schedules and history. Where the device offers no route
short of the reset, say so — `supported: false`, `requires_factory_reset:
true` — rather than leaving the reader to find out.

## PINs are protocol facts; PINs are also credentials

Both, depending on where the value comes from, and the distinction is enforced
by the schema rather than left to judgment:

- `source: fixed_default` — the same on every unit of the product. That is a
  protocol fact and belongs in the spec, `value` and all. The OBDLink CX's
  `123456` is not a secret; it is proof that somebody is standing at the car.
- Anything else — printed on this unit's label, shown on its screen, derived
  from its serial — is a credential belonging to whoever owns that unit.

Only `fixed_default` may carry a `value`; the schema rejects the rest. That is
the schema half of a rule
[CLEANROOM_RULES.md](../CLEANROOM_RULES.md#scrub-your-own-identifiers) already
states in prose: a pairing PIN read off your own hardware is a live credential
and is useless to every other reader besides.

## "None" and "unknown" are different answers

Both `pairing.required` and `factory_reset.applicable` take `false` and
`"unknown"`, and the distinction is load-bearing:

- **`false`** — established absence. The device has no pairing, or no reset,
  and the spec says *why*. Airthings' Wave family has no reset control at all;
  the button Airthings document at length belongs to the View series, which is
  different hardware, so someone following those instructions is hunting for a
  control that does not exist. b-parasite holds no state a reset could clear.
  Hyperice say plainly their device has no reset button.
- **`"unknown"`** — nobody has established it. That is a legitimate answer and
  the schema supports it properly: it forces `confidence: low`, and any
  procedure listed under it must be `verified: false` with a `basis`. It
  should still say what was looked for and where it was not found.

The one to avoid is `unknown` used as a shrug. "No factory-reset procedure is
documented in the sources used here" tells a reader nothing they could not
have guessed; "Beurer's own support position is that the PO60's stored
measurements cannot be cleared on the device" is a finding, and a
consequential one — that oximeter holds health data that no owner can remove.

## Procedures, glyphs and honesty

Pairing-mode entry and unpairing share one shape with factory reset —
`$defs/physical_procedure` — because on most devices they are the same button
held for different lengths of time. That shape carries `hold_seconds`,
`press_count`, `power_state`, an `indicator`, and the rule that a procedure
saying `verified: false` must cite a `basis`.

`power_state` deserves its own mention. `booting` is the while-powering-on
case, and it is the single most common reason a correct-looking procedure does
not take: the user holds the button on a running device and nothing happens.

Procedures may also carry a [glyph](../contributing/glyphs.md) — a small
drawing of the button, or of the LED pattern that confirms success. Prose
carries the timing perfectly well. What it carries badly is *which* unlabelled
button, on a device the reader is holding for the first time.
