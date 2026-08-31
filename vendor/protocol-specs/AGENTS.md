# Agent guide — Liberated Bread Protocol Specs

Guidance for AI coding agents (Claude Code and others) working in this repo.
Humans: start with [README.md](README.md).

## What this is

The clean-room **knowledge base** of reverse-engineered protocols for
locally-controllable IoT devices — so abandoned hardware keeps working without
the vendor cloud. The two most common transports, and the ones the mobile app
speaks, are:

- **BLE** (`protocol: ble` / `ble_gatt`) — GATT services, characteristics,
  message formats.
- **Wi-Fi/LAN** (`protocol: wifi`, with `http` / `soap` / `ssdp` / `udp`
  transport blocks) — discovery via mDNS/DNS-SD and SSDP/UPnP, control over HTTP
  and SOAP, and device provisioning.

Specs are not limited to those two. The authoritative `device.protocol` enum in
`device-specs/schema.json` also covers `zigbee`, `zwave`, `obd2`, `uart`, and
`can` (e-bikes, OBD-II dongles, and other wired/radio buses) — treat that enum
as the source of truth for what a spec may declare.

**The specs are the product.** `device-specs/devices/*.yaml` is written to be
implementable on its own, validated against `device-specs/schema.json`. We do
**not** ship a supported device-client library; helper scripts under `scripts/`
are verification/research scaffolding, not a client surface.

## Clean-room rules (absolute)

See [docs/CLEANROOM_RULES.md](docs/CLEANROOM_RULES.md). In short:

- **Never commit APKs, decompiled source trees, or vendor assets.** They are
  gitignored (`workspace/`, `*.apk`, `*.pcap`, …) — keep it that way.
- Do not paste vendor app strings/UI copy beyond short paraphrases.
- Do not name the vendor app's internal classes, methods or source paths.
  Describe the role instead: "the app's BLE scanner", not `SenseScanner.java`.
  Citing an *open-source* project by file is fine — that is attribution.
- **Scrub identifiers that are yours, not the device's.** Hardware
  verification fills your notes with the LAN address, MAC, hostname, serial
  and keys of your own unit; none of it is reusable and all of it is public
  once committed. Replace with a placeholder (`aa:bb:cc:dd:ee:ff`,
  `192.168.1.50`, `<user-key>`) and keep the format so the example still
  teaches. Keep OUI prefixes and product-fixed addresses like a SoftAP's
  `10.10.100.254` — those are the fact. Applies to `research-notes/` and
  `docs/devices/` too.
- Only commit **derived** facts, protocol details, and your own writing.

## Setup, test, lint

- **Claude Code on the web:** `.claude/hooks/session-start.sh` installs the
  Python deps automatically.
- **Local:**

```bash
pip install -r requirements.txt -r requirements-dev.txt
ruff check .                      # lint the helper scripts
pytest -q                         # test suite
python scripts/validate_specs.py  # validate every spec against schema.json
python scripts/validate_glyphs.py # glyph references, manifest and SVG hygiene
python scripts/check_links.py     # helpful_urls still resolve (network; not in CI)
python scripts/build_index.py --check   # JSON API freshness (what CI checks)
mkdocs build --strict             # docs must build clean
```

CI (`.github/workflows/ci.yml`) runs exactly these.

**Do not commit `device-specs/index.json`.** It is generated, and CI's
`publish-index` job rebuilds and commits it on every push to main — that is the
whole reason it moved out of branches: with several spec PRs open at once, a
60 kB machine-written file that every one of them touches conflicts with every
other one. A PR carrying it fails CI (`Reject a hand-carried index.json`) with
the command to drop it. If you want to see the index your specs produce,
`python scripts/generate_index.py` still writes it locally — just leave it out
of the commit (`python scripts/generate_index.py --check` reports staleness
without writing).

## Instruction glyphs (`glyphs/`)

Small **original** drawings of the hardware a reset or pairing step refers to —
which button, what the LED does — referenced from specs by `glyph` /
`indicator_glyph` and rendered beside the step. Full guide:
[docs/contributing/glyphs.md](docs/contributing/glyphs.md). The three rules
worth knowing before you touch the directory:

- **Draw it, never derive it.** Vendor artwork is inadmissible in any processed
  form — not a manual crop, not a trace over a product photo, not a recoloured
  app asset. `origin: original_drawing` in `glyphs/MANIFEST.yaml` is an
  attestation, and it is the only value the validator accepts.
- **Tracked with Git LFS.** Run `git lfs install` in a fresh clone or you get
  pointer files instead of drawings.
- **Every glyph is referenced and every reference resolves.** An orphan in the
  store is a validation failure. Run `python scripts/validate_glyphs.py`.

## Manual links (`helpful_urls` with `kind: manual`)

An owner holding abandoned hardware wants the manual, and "the manual" is the
single most common thing they cannot find once the vendor's site is gone. Add
one wherever you can:

```yaml
helpful_urls:
  - title: "Kwikset Kevo 2nd generation installation and user guide (PDF)"
    url: "https://s7d5.scene7.com/is/content/BDHHI/Kwikset/Tech-Docs/5064452.pdf"
    kind: "manual"
    description: >
      Vendor-hosted guide for the 2nd-generation lock, including the
      ten-second Reset button hold used in this spec.
```

- **Verify it resolves before committing it.** The schema says a dead link is
  worse than no link. `python scripts/check_links.py --kind manual` checks the
  ones already in tree; it is not in CI, because it talks to the open internet
  and a third-party site having a bad afternoon must not fail a spec PR.
- **Prefer vendor-hosted, then an aggregator, then the Internet Archive.**
  Archive links are not a fallback to be embarrassed about here — for a dead
  vendor they are the only thing that will still resolve in five years, which
  is the failure this whole registry exists for. Use the `/web/<timestamp>/`
  replay form, never the availability API.
- **A 403 is not a dead link.** manuals.plus, fcc.report, Codeberg and most
  Zendesk vendor portals refuse anything without a browser fingerprint. The
  checker reports those separately as "blocked" so nobody deletes a good link
  to make it go green.
- **Say which model.** Most specs here cover a family, so a bare "manual" link
  is a guessing game; a convention test requires the description.

## Adding or changing a device

1. `docs/devices/_template.md` → `docs/devices/<device>.md` (include setup,
   pairing, factory reset, rebinding).
2. Add the device to `docs/devices/index.md` and to `mkdocs.yml`'s nav.
3. Add a spec under `device-specs/devices/`, then
   `python scripts/validate_specs.py`. A BLE spec must carry a
   `device.pairing` block — "nothing pairs" is the usual answer and saying it
   is the point; see
   [docs/protocols/pairing.md](docs/protocols/pairing.md). If the device has
   more than one `setup.methods` entry, each one needs a `name` and a `role`
   (`primary` / `alternative` / `variant` / `historical`) and the list is
   ordered easiest first, with anything defunct last. Every entry is a route
   the reader CHOOSES: two things they must both do, in order, are one method
   with `stages`, not two methods. `type` is the mechanism, not a label — two
   methods on one device routinely share it. See
   [docs/api/spec-format.md](docs/api/spec-format.md#methods), and read
   [Writing a spec someone can implement](#writing-a-spec-someone-can-implement)
   before the protocol blocks. The index picks the spec up on its own once this
   merges — do not commit `device-specs/index.json`.
4. For net-new reverse engineering, follow the per-target clean-room workflow in
   [prompts/AGENT_META_PROMPT.md](prompts/AGENT_META_PROMPT.md).

## Writing a spec someone can implement

The bar is one sentence long: **someone holding the hardware and none of your
context can build a working client from the YAML alone.** Everything below is a
way that fails in practice, each one drawn from a spec in this tree that had to
be repaired. [docs/api/spec-format.md](docs/api/spec-format.md) is the field
reference; this is the craft.

**A fact in prose is a fact no consumer can read.** This is the most common
defect in the catalogue and the most expensive one downstream. Prose sitting
*beside* a field is context and is welcome; prose standing *instead of* a field
is a fact that only a human re-reading the document will ever find. GAPS.md's
"Mobile handlers' schema asks" is the receipt: twelve places where a mobile
handler had to hard-code a value, tell two commands apart by their name, or
parse a payload out of a paragraph, because the spec described the bytes
without declaring them. If you find yourself writing "the density byte is 0x01
for light, 0x02 for normal", that is a `parameters` block with an enum, not a
sentence.

**An undeclared key is invisible, not merely untidy.** The schema root and
`device` are closed worlds (`additionalProperties: false`), so a made-up
sibling key fails validation outright. The subtler version passes every gate:
protocol facts filed under `data_format` instead of `commands`/`format`, under
`device.payload_formats` instead of the root `payload_formats`, under
`description` instead of a characteristic's `notes` — all valid YAML, all
invisible to anything that reads specs by key. Look in `schema.json` before you
invent a name. If the field genuinely does not exist, put the block under
`protocol_details` — the declared escape hatch, exempt from the closed-world
rule — and propose the real field in
[docs/contributing/spec-evolution.md](docs/contributing/spec-evolution.md).

**Say how sure you are, separately for each kind of sure.** Three mechanisms
that are routinely confused:

- `verification: confirmed | reported | hypothesis` on an individual fact.
- `verified` on a setup method or reset procedure, plus `setup.confidence`.
- `device.testing` on the spec as a whole — "has *this project* driven hardware
  from this document?" `untested` is the honest default and the usual answer.
  A new spec needs the block; a reference spec must not carry one. `detail`
  refines `status` (`capture-verified` only under `untested`, `minimally-` /
  `mostly-verified` only under `verified`), and anything above a bare
  `untested` has to name its evidence in `notes` so a reviewer can check it.

Byte-level detail recovered from a decompiled app is `reported`, however
convincing it looks — `confirmed` means someone ran it against the device. An
unverified reset procedure or pairing procedure must cite a `basis`; that is
enforced, because "we think you hold it for ten seconds" and "we held it for
ten seconds" are different documents.

**Write down what you do not know.** `remaining_unknowns` and
`evidence.open_questions` cost a line each and are the difference between the
next person resuming your work and repeating it. Record negative findings the
same way: `m6-fitness-band` documents an app-to-device match that was
positively *refuted* by a firmware dump, and that note is worth more than the
correct answer alone, because it is the wrong turn everyone else was about to
take.

**Numbers are not implementable until they carry units, endianness and
scaling.** Every value a client parses needs all three. Units use the canonical
spelling, are never empty, and name exactly one quantity (`temperature_c`, not
`temp_c_or_f`); endianness is declared the same way everywhere; a temperature
that is really `u16 LE − 30` says so, along with its sentinel values. A `bytes`
parameter bounds its *length* with `min_length`/`max_length` — `min`/`max` mean
a value range everywhere else in the schema, and the consumer that read
`fardriver-controller`'s `{type: bytes, min: 1, max: 26}` that way rejected the
parameter and dropped the entire spec with it.

**A matcher that cannot match fails silently.** A `local_name` matcher needs a
`value` or a non-empty `values`; a `match: regex` needle must compile;
`local_name_prefix` is never the empty string; `mac_prefixes` must be usable
OUIs, and a high-confidence one has to show its working. These are load-bearing
in both directions — one spec is *found* by its matcher and another *withholds*
a warning based on one — and a broken needle produces no error, just a device
that never appears.

**Steps are executed by somebody. Say who.** Every step needs an `action`, and
`actor` is one of `user`, `client`, `device`. It is the field that decides
whether a setup wizard can automate a step or must stop and ask a person to
press something.

**Answer the standing questions even when the answer is "no".** A missing block
is indistinguishable from a question nobody asked, so the negative answers are
the point: a BLE spec's `pairing` block usually says nothing pairs;
`factory_reset` may be `applicable: false` or `"unknown"`; `rejoin` answers
"my router changed, now what?"; `credentials.wifi_passphrase_protection` may be
`plaintext`. Each of those is a fact somebody would otherwise spend an evening
establishing.

**Bind the control surface to something a client can render.** `commands` and
`entities` use documented vocabularies for keys and roles, entity names are
unique per variant, command templates may only reference parameters they
declare, and a `locate` command is never `advanced` — a locator is offered as a
one-tap button with no user in the loop to confirm it, so it must never be
something a user needs protecting from.

**Test vectors are the highest-leverage thing a spec can carry**, and the
standard to hold them to is `scripts/test_wemo_spec.py`: it transcribes the
published algorithm using nothing but the standard library, imports none of our
code, and asserts the transcription reproduces the spec's own vectors. If that
test cannot be written, the spec is underspecified no matter what else passes.
Use documentation-range MACs and invented serials so the vectors identify no
real unit.

**Byte-level notes are where vendor class names sneak in.** The clean-room rule
above is easiest to break in exactly the place your notes are densest — a
parser you traced through the app. Name the role, not the symbol: "the app's
temperature parser applies `(high << 4) + low`", never the class and method it
lived in. Citing an *open-source* project by file stays fine.

## Downstream

Specs here are vendored into
[liberatedbread-mobile](https://github.com/liberatedbread/liberatedbread-mobile)
as a git subtree; the mobile app renders these YAML specs directly for both BLE
and Wi-Fi/LAN devices. Keep specs implementable from the document alone.
