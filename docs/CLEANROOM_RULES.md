# Clean-room rules (legal + ethical)

## What we do NOT commit
- APK files (or split APK bundles)
- Decompiled Java/Kotlin sources, smali, resources.arsc outputs
- Vendor images, fonts, animations, strings copied from the vendor app/UI
- Vendor documentation text beyond short, fair-use quotations (prefer paraphrase)

## What we MAY commit (derived facts)
- Hashes, package IDs, version codes, manifest-level permissions lists (summarized)
- BLE GATT service/characteristic UUIDs, characteristic properties
- Wire protocols: message formats, opcodes, CRCs, state machines
- Local network endpoints, ports, multicast discovery outputs (summarized)
- Test matrices and reproduction steps

## Scope limitations
- Exclude safety-critical medical devices.
- Exclude tobacco/vape devices except PAX (explicitly allowed by project policy).
- Prefer local-first control; if a device is cloud-only, document that and deprioritize.

## Purpose: repair
This work exists to support repair cafés, owner maintenance and independent servicing. The
deliverable is not a museum piece — it is enough documented protocol for someone to fix a
device they or their neighbour owns. Maintenance functions that write to a device (service
interval resets, sensor ID programming, clearing recorded faults) are in scope and are the
point.

Functions that can brick a unit or leave a vehicle unusable — coding, flashing,
immobiliser and key operations, adaptation writes — are **documented and flagged
`advanced`**. Reviving neglected hardware needs them: a salvaged module has to be coded to
the machine it went into, and a half-written flash has to be finished. Flagging them means
a consumer warns and confirms; it does not mean we withhold the information. What the flag
asks for is a recovery path known in advance.

Genuinely excluded: falsifying recorded usage data such as odometers, and anything
performed on a vehicle in motion. Mechanically safety-critical procedures — brake bleeding,
for one — continue in the manufacturer's service manual; a protocol document is not a
substitute for it.

## Capability disclosure (writing the `advanced` flag)

How **Purpose: repair** above is applied when authoring a spec.

**Default: expose everything the protocol supports.** If we know an opcode, we document it.
We do not withhold a capability because it is powerful, and we do not quietly narrow a
device to its read-only surface. Withholding does not make anyone safer — it just sends
people to a worse-documented source with no warning attached.

**A signpost, not a gate.** Consumers should put an advanced command behind a deliberate
action (a toggle, a confirmation) so nobody trips into one by accident, and show
`advanced_reason` at that moment. They should **not** hide the capability, require an
account, or nag.

**How to write `advanced_reason`.** State what changes, what the realistic consequence is,
and how to recover — the recovery path is the part the flag exists to demand. Concrete
beats scary:

- Good: "Raises the motor current limit. Above the motor's rating this can overheat the
  primary gear. Read and save the current block first so you can restore it."
- Bad: "Dangerous — advanced users only."

**No moralising.** Note consequences a reasonable owner would want to know — warranty,
legal classification, irreversibility — once, factually, then get out of the way. It is
their device. "There is almost never a legitimate reason to do this" is not our call to
make: someone restoring a serial number after a controller swap has a perfectly good
reason.

### Three separate axes — do not conflate them

The schema now carries three things that sound alike. A command can be any combination:

| Field | Question it answers | Where |
|-------|--------------------|-------|
| `advanced` (bool) | **Consequence** — how far past a normal consumer app does this go? | BLE commands |
| `command_class: basic \| advanced` | **Capability** — which adapter can even run this? | `obd.requests` |
| `verification` | **Confidence** — how sure are we that it works? | OBD facts |

A legislated single-frame OBD request is `command_class: basic` yet can still be
consequential; a `confirmed` opcode can still be advanced; a `hypothesis` read is usually
mundane. `obd.requests` additionally carries `writes` for "does this mutate state", which
is the OBD-side analogue of the consequence axis.

!!! note
    The word "advanced" currently means two different things — consequence on BLE commands,
    adapter capability on OBD requests. Renaming one of them (`command_class` →
    `adapter_class` is the better fit, since it really is about adapters) is an open
    decision.

### What this does not license

- **Do not invent opcodes.** Exposing everything means everything we actually know.
  Unverified bytes are labelled as unverified, never presented as usable fact.
- **Do not execute writes during discovery.** Autodetection stays scan-and-read only; an
  advanced command is something a user chooses, never something a scan triggers.
- **Do not auto-match on non-unique signals** when a spec carries advanced commands — a
  misidentified device means pointing a write at unrelated hardware.
- The scope limitations and exclusions above still apply.

## Consent + ownership
Reverse engineer only devices you own/control, on networks you own/control, or where you
have permission. At a repair café that means the owner's informed consent for each change,
and telling them afterwards what was changed.
