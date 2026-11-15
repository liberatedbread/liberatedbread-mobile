# Instruction Glyphs

`glyphs/` holds small original drawings of the physical things a setup, reset
or pairing step refers to: which button, where it sits on the case, what the
LED does when the step takes.

They exist because of a specific gap. Prose carries timing well — "hold for ten
seconds" needs no picture. What prose carries badly is *which* button, on a
device the reader is holding for the first time, where nothing is labelled and
there are three candidates.

Glyphs are **advisory by construction**. Every step must read correctly with no
picture beside it, no schema field ever requires one, and a consumer that ships
none loses only the picture. A spec whose reset is documented but undrawn is
complete, not half-written.

## Referring to one from a spec

Two fields carry glyph paths: `glyph` (the control the step acts on) and
`indicator_glyph` (the LED or screen state that confirms it worked). Both are
available on `$defs/physical_procedure` — so on factory-reset procedures and on
pairing-mode and unpair procedures — and `glyph` is available on any
`setup_step`.

```yaml
      procedures:
        - name: "Restore button held while power is applied"
          glyph: "generic/hold-button-while-powering-on.svg"
          indicator: "Status LED blinks, then the device reboots into setup mode."
          indicator_glyph: "generic/led-flashing.svg"
```

Paths are relative to `glyphs/`, **without** the `glyphs/` prefix. That is so a
consumer vendoring this repo as a subtree, or serving the set from its own
asset bundle, can rebase every reference at once by prepending its own root. A
test catches references that write the prefix anyway.

## The two directories

- **`generic/`** — a gesture rather than a device. Hold a button; hold it while
  power arrives; press two at once; poke a recessed pinhole; find it in an
  on-screen menu; an indicator that is flashing rather than steady. These get
  referenced from dozens of specs and are where most of the value is.
- **`devices/<spec-id>/`** — this product's actual hardware, when the generic
  gesture is not enough: a button in a place nobody would guess, an LED ring
  with a meaningful pattern.

Reach for `generic/` first. A device-specific drawing is worth making when the
thing a reader needs is *where the control is*, not *what to do with it*.

## Clean-room: draw it, don't derive it

The rule from [CLEANROOM_RULES.md](../CLEANROOM_RULES.md) applies here without
exception. Vendor artwork is not admissible in any processed form: not a crop
of a manual page, not a trace over a product photo, not an app asset
recoloured. `origin: original_drawing` in the manifest is an attestation that
someone drew the file from scratch, and it is the only value the validator
accepts.

Reading a manual to learn that the button sits below the paddle is research.
Tracing the manual's diagram of it is not. The manifest keeps those apart:
`drawn_from` records the factual basis, which is a different question from
where the artwork came from.

## What a glyph has to be

Enforced by `scripts/validate_glyphs.py`:

- **Self-contained and inert.** No `<script>`, `<image>`, `<use>`,
  `<foreignObject>`, animation elements, event-handler attributes, embedded
  fonts, or any `href` pointing outside the file. A glyph renders inside other
  people's applications.
- **No `<text>`.** Words in a drawing render wrong in the next locale and in
  any consumer whose font stack differs. If a glyph needs a label, the step
  text beside it is the label.
- **A `viewBox` and a non-empty `<title>`.** No fixed `width`/`height` — the
  consumer decides the size.
- **Under 64 kB.**

House style, not enforced but worth matching: a `0 0 96 96` viewBox,
`stroke="currentColor"` with `fill="none"` so the glyph inherits the
consumer's text colour in both light and dark themes, stroke width 3 with round
caps and joins, and a `<desc>` describing the drawing.

## Adding one

1. Draw it. Put it in `generic/` or `devices/<spec-id>/`, named for what it
   shows in kebab-case.
2. Add a `glyphs/MANIFEST.yaml` entry with `title`, `alt` and `origin`. The
   `alt` text describes **the drawing** — what a screen reader says instead of
   showing it — not the instruction, which is already in the step text beside
   it and is noise repeated.
3. Point at least one spec at it. An unreferenced glyph is a validation
   failure: the store only grows, and it lives in LFS.
4. `python scripts/validate_glyphs.py && pytest -q scripts/test_glyphs.py`.

Look at it before you commit. A glyph is reviewed by looking at it, which is
the one thing a diff cannot do for you:

```bash
inkscape --export-type=png --export-width=200 --export-background=white \
    --export-filename=/tmp/glyph.png glyphs/generic/hold-button.svg
```

## Git LFS

Everything under `glyphs/` is tracked with Git LFS — `.gitattributes` carries
the rules and a test checks that every extension in the store is covered. Run
`git lfs install` once in a fresh clone; without it you get pointer files where
the drawings should be, and the validator says so in as many words rather than
failing on a parse error.
