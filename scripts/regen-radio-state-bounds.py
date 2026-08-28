#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Regenerate assets/radio/us_state_bounds.json from Census TIGER data.

The app maps "here, plus a radius" to the set of state codes worth asking
RepeaterBook and myGMRS about, because neither API has a proximity query --
both are state-scoped. That mapping needs a coarse geographic extent per
state, and this builds one from the authoritative public-domain source: the
Census Bureau's cartographic boundary file (1:20,000,000, the smallest they
publish, which is ample for a bounding box).

Boxes rather than polygons on purpose. The consumer's question is "might a
repeater in this state be within R km of here", and answering it too
generously costs one extra HTTP request that returns listings the distance
filter then drops. Answering it too tightly loses a repeater across a state
line, which is exactly the repeater someone near a border wants.

ANTIMERIDIAN: Alaska's Aleutians run past 180 degrees east, so its single
bounding box spans nearly the whole planet and would make Alaska a candidate
from Florida. States whose extent crosses the line are therefore emitted as
two boxes, split at the meridian. That is why "boxes" is a list.

Usage:
    python3 scripts/regen-radio-state-bounds.py            # downloads
    python3 scripts/regen-radio-state-bounds.py FILE.zip   # uses a local copy
"""
from __future__ import annotations

import io
import json
import struct
import sys
import urllib.request
import zipfile
from datetime import date, timezone, datetime
from pathlib import Path

SOURCE_URL = (
    "https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_state_20m.zip"
)
STEM = "cb_2023_us_state_20m"
OUT = Path(__file__).resolve().parent.parent / "assets/radio/us_state_bounds.json"


def read_dbf(data: bytes) -> list[dict[str, str]]:
    """Parse the dBase III attribute table shipped beside a shapefile."""
    numrec, hlen, rlen = struct.unpack_from("<IHH", data, 4)
    fields: list[tuple[str, int]] = []
    off = 32
    while data[off] != 0x0D:
        name = data[off : off + 11].split(b"\0")[0].decode("latin-1")
        fields.append((name, data[off + 16]))
        off += 32
    rows = []
    for i in range(numrec):
        rec = data[hlen + i * rlen : hlen + (i + 1) * rlen]
        pos = 1  # byte 0 is the deletion flag
        row = {}
        for name, flen in fields:
            row[name] = rec[pos : pos + flen].decode("latin-1").strip()
            pos += flen
        rows.append(row)
    return rows


def read_shp_points(data: bytes) -> list[list[tuple[float, float]]]:
    """Return each record's (lon, lat) vertices.

    The per-record header carries a bounding box already, but it is the one
    that goes wrong at the antimeridian -- so the points are read and the
    boxes computed here, where the split can be made.
    """
    off = 100  # file header
    records = []
    while off < len(data):
        _num, clen = struct.unpack_from(">II", data, off)
        content = off + 8
        shape_type = struct.unpack_from("<I", data, content)[0]
        points: list[tuple[float, float]] = []
        if shape_type == 5:  # Polygon
            num_parts, num_points = struct.unpack_from("<II", data, content + 36)
            start = content + 44 + num_parts * 4
            for i in range(num_points):
                lon, lat = struct.unpack_from("<2d", data, start + i * 16)
                points.append((lon, lat))
        records.append(points)
        off = content + clen * 2
    return records


def boxes_for(points: list[tuple[float, float]]) -> list[dict[str, float]]:
    """One box, or two when the state crosses the antimeridian."""
    if not points:
        return []
    lons = [p[0] for p in points]
    groups = [points]
    if max(lons) - min(lons) > 180:
        east = [p for p in points if p[0] >= 0]
        west = [p for p in points if p[0] < 0]
        groups = [g for g in (east, west) if g]
    out = []
    for group in groups:
        out.append(
            {
                "minLon": round(min(p[0] for p in group), 4),
                "minLat": round(min(p[1] for p in group), 4),
                "maxLon": round(max(p[0] for p in group), 4),
                "maxLat": round(max(p[1] for p in group), 4),
            }
        )
    return out


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        raw = Path(argv[1]).read_bytes()
    else:
        print(f"downloading {SOURCE_URL}")
        with urllib.request.urlopen(SOURCE_URL, timeout=120) as resp:
            raw = resp.read()

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        dbf = zf.read(f"{STEM}.dbf")
        shp = zf.read(f"{STEM}.shp")

    rows = read_dbf(dbf)
    shapes = read_shp_points(shp)
    if len(rows) != len(shapes):
        print("attribute and geometry record counts disagree", file=sys.stderr)
        return 1

    states = []
    for row, points in zip(rows, shapes):
        code = row.get("STUSPS", "")
        name = row.get("NAME", "")
        # The FIPS code is carried because RepeaterBook's export API keys on
        # it (state_id), while myGMRS uses the postal abbreviation. Having
        # both here means neither client has to hold a lookup table of its
        # own that could drift from the other's.
        fips = row.get("STATEFP", "")
        boxes = boxes_for(points)
        if not code or not boxes:
            continue
        states.append(
            {"code": code, "fips": fips, "name": name, "boxes": boxes}
        )
    states.sort(key=lambda s: s["code"])

    doc = {
        "source": SOURCE_URL,
        "source_note": (
            "US Census Bureau cartographic boundary file, 1:20,000,000. A work "
            "of the United States government: public domain."
        ),
        "retrieved": datetime.now(timezone.utc).date().isoformat(),
        "regenerate": "python3 scripts/regen-radio-state-bounds.py",
        "states": states,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(doc, indent=2, sort_keys=False) + "\n")
    print(f"wrote {OUT} ({len(states)} states)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
