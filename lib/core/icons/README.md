# MDI glyph tables

The catalogue speaks Material Design Icons — Home Assistant's set, which the
whole upstream vocabulary is written against — and this app ships Flutter's
Material Icons and no MDI font. These files are that translation, nothing
more: the spec still decides *which* icon an entity gets, and a table here
says what that icon looks like in the font we have.

## Why several files rather than one map

One map is what this was, and it became the file every device branch had to
edit. A branch adding air-quality readings and a branch adding a TV remote
both appended to the same twenty lines and conflicted on every rebase — over
entries that have nothing to do with each other and could never disagree.

So the tables are split **by the kind of device that needs them**. A branch
teaching the app about a new class of hardware adds its glyphs to that
domain's file (or a new one beside it), and two such branches touch disjoint
files. `entity_icon.dart` merges them; the merge is the only shared line, and
it moves once per new file rather than once per glyph.

## Adding glyphs

Put the entry in the domain file that fits, keyed by the exact `mdi:` name
the spec asks for, lowercase. If a new device class does not fit any of
these, add a file — `foo_glyphs.dart` exporting `const fooGlyphs` — and add
it to the merge in `entity_icon.dart`.

Deliberately not exhaustive. MDI has around 7,000 names; shipping the font to
cover them would cost about a megabyte for a handful of entities. An unmapped
name falls back to what the entity's `device_class` implies, which is the
answer the app gave before specs could ask for an icon at all — so a new
`icon:` upstream degrades to the old behaviour rather than to a blank.
