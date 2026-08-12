"""MkDocs post-build hook that generates the device-spec JSON API.

Run automatically after ``mkdocs build`` (and ``mkdocs gh-deploy``) so the
API files are always included in the published site without needing a
separate CI step.

The hook runs :func:`scripts.build_index.run`, which discovers, validates,
and emits the manifest + per-device JSON into ``<site_dir>/api/v1/``.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure the scripts directory is importable
_scripts_dir = Path(__file__).resolve().parent
if str(_scripts_dir) not in sys.path:
    sys.path.insert(0, str(_scripts_dir))

import build_index  # noqa: E402


def on_post_build(config, **kwargs) -> None:  # noqa: ARG001
    """Generate the device API index after mkdocs writes site/."""
    site_dir = Path(config["site_dir"])
    print("\n--- Generating device-spec JSON API ---")
    rc = build_index.run(output_dir=site_dir)
    if rc != 0:
        raise SystemExit(
            f"build_index returned {rc} — aborting build to prevent stale API publish"
        )
    print("--- Device-spec JSON API generated ---\n")
