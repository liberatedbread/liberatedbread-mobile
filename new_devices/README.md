# new_devices/ — UNVALIDATED scratch

**Nothing in this directory is a spec, and nothing here is checked against
`device-specs/schema.json`.** These are draft device write-ups and protocol
reports that have not yet been turned into a validated spec. Treat every file
here as a work in progress that **may be incomplete, unverified, or simply
wrong** — a report here is a proposal, not a confirmed fact.

A device graduates from here to a real spec under
`device-specs/devices/*.yaml`, which is validated (`python
scripts/validate_specs.py`), indexed, and shipped downstream. Until then, do
not build against anything in this tree.

The clean-room rules still apply to everything here — see
[docs/CLEANROOM_RULES.md](../docs/CLEANROOM_RULES.md). Placeholder your own LAN
addresses, MACs, hostnames, serials, and keys, and never paste the vendor app's
internal class or method names — paraphrase the role instead.
