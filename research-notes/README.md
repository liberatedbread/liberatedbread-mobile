# research-notes/ — UNVALIDATED scratch

**Nothing in this directory is a spec, and nothing here is checked against
`device-specs/schema.json`.** These are raw reverse-engineering notes — the
first place a hardware or APK session's findings land — usually as an `.md`
write-up beside a rough `.yaml` sketch. Treat every file here as a work in
progress that **may be incomplete, unverified, or simply wrong.**

A device graduates from here to a real spec under
`device-specs/devices/*.yaml`, which is validated (`python
scripts/validate_specs.py`), indexed, and shipped downstream. Until then, do
not build against anything in this tree and do not assume a claim here has been
confirmed on hardware.

What *is* enforced here: the clean-room identifier scrub. This tree is scanned
for leaked researcher-network addresses exactly as the published trees are (see
[docs/CLEANROOM_RULES.md](../docs/CLEANROOM_RULES.md) — a live session's paste
lands here first, so the rule is if anything stricter). Placeholder your own
LAN addresses, MACs, hostnames, serials, and keys before committing a note.
