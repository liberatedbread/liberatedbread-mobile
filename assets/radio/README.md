<!-- Copyright 2026 Pigs Can Fly Labs LLC
     SPDX-License-Identifier: Apache-2.0 -->

# Bundled radio data

What ships in the app so the radio suggestions work with no network at all.

## `us_state_bounds.json`

Coarse geographic extents for the 50 states, DC and Puerto Rico.

- **Source:** <https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_state_20m.zip>
  — the US Census Bureau's cartographic boundary file at 1:20,000,000. A work
  of the United States government, and therefore public domain.
- **Retrieved:** 2026-08-28 (the file records its own date in `retrieved`).
- **Regenerate:** `python3 scripts/regen-radio-state-bounds.py`

Why it exists: neither the RepeaterBook nor the myGMRS API has a proximity
query. Both are state-scoped. So "repeaters within 40 km of here" becomes "ask
these two or three states, then filter by distance locally", and that first
step needs to know roughly where each state is.

Bounding boxes, not polygons, and deliberately generous ones. Being too
generous costs one HTTP request whose listings the distance filter then drops.
Being too tight loses the repeater across a state line — which is precisely
the repeater someone standing near that line wants.

`boxes` is a list per state because of Alaska: the Aleutians run east past 180
degrees, so a single box for Alaska spans nearly the whole planet and would
make it a candidate from Florida. States that cross the antimeridian are split
at it.
