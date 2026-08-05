# Data API

The OpenGreenIoT Protocol Docs site publishes a machine-readable JSON API
so applications (Home Assistant integrations, mobile apps, CI pipelines)
can programmatically consume structured device specifications and detect
updates.

For the structure of a device spec — and how to read the `setup` block that
carries provisioning, factory reset and rebinding — see
[Reading a Device Spec](spec-format.md).

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `/api/v1/manifest.json` | Registry of all known device specs with checksums and timestamps |
| `/api/v1/devices/<id>.json` | Full device specification for a single device, normalized to JSON |

## Manifest (`/api/v1/manifest.json`)

The manifest is a lightweight index used for update polling.  Fetch this
first, compare against a cached copy, and only download per-device JSON
for specs that changed.

```json
{
  "api_version": "1",
  "generated_at": "2026-03-12T01:11:51+00:00",
  "schema": "https://opengreeniot.pigscanfly.ca/device-spec.schema.json",
  "device_count": 4,
  "devices": [
    {
      "id": "admore-light-bar",
      "name": "AdMore Light Bar Pro",
      "manufacturer": "AdMore Lighting Inc.",
      "protocol": "ble",
      "status": "active",
      "helpful_urls": [
        {
          "title": "AdMore Connect App Help",
          "url": "https://admorelighting.com/admore-connect-app-help/"
        }
      ],
      "updated_at": "2026-03-12T01:11:51+00:00",
      "url": "/api/v1/devices/admore-light-bar.json",
      "checksum": "sha256:5c04e0af..."
    },
    {
      "id": "chef-iq-sense",
      "name": "CHEF iQ Sense",
      "manufacturer": "CHEF iQ (Chefman)",
      "protocol": "ble",
      "status": "unsupported",
      "updated_at": "2026-03-12T01:11:51+00:00",
      "url": "/api/v1/devices/chef-iq-sense.json",
      "checksum": "sha256:df484d15..."
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `api_version` | string | API version (`"1"`); increments on breaking changes |
| `generated_at` | string | UTC ISO 8601 timestamp of when this manifest was generated |
| `schema` | string | `$id` of the JSON Schema used for validation |
| `device_count` | integer | Number of device specs in the registry |
| `devices` | array | Device entries sorted alphabetically by `id` |

Each device entry:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Device identifier (matches `target_id` in `targets.csv`) |
| `name` | string | Human-readable device name |
| `manufacturer` | string | Original manufacturer |
| `protocol` | string | Primary protocol (`ble`, `wifi`, `zigbee`, `zwave`, `obd2`, `uart`, `can`) |
| `status` | string | Manufacturer support status (`active`, `abandoned`, `shutdown`, `unsupported`) |
| `openness` | string | Whether the protocol was published or recovered (`open_by_design`, `documented_api`, `undocumented`, `hostile`); defaults to `undocumented` when the spec is silent |
| `helpful_urls` | array | Optional top-level human references from the source spec; omitted when absent |
| `helpful_videos` | array | Optional top-level video references from the source spec; omitted when absent |
| `updated_at` | string | UTC ISO 8601 timestamp of the spec's last git commit |
| `url` | string | Path to the per-device JSON endpoint |
| `checksum` | string | `sha256:<hex>` of the per-device JSON file bytes (content-addressable) |

## Per-device endpoint (`/api/v1/devices/<id>.json`)

Returns the full device specification as JSON, structurally identical to
the source YAML.  The top-level keys are `device`, plus one or more transport
blocks such as `services`, `http_endpoints`, `mqtt_topics`, `obd`, `bus` or
`cloud`, and optional blocks such as `entities`, `helpful_urls` and
`helpful_videos`.

```
GET /api/v1/devices/chef-iq-sense.json
```

```json
{
  "device": {
    "name": "CHEF iQ Sense",
    "manufacturer": "CHEF iQ (Chefman)",
    "manufacturer_status": "unsupported",
    "protocol": "ble",
    "identification": { ... }
  },
  "services": [ ... ],
  "entities": [ ... ],
  "helpful_urls": [
    {
      "title": "Protocol write-up",
      "url": "https://example.com/protocol",
      "description": "Explains the frame format."
    }
  ]
}
```

The checked-in `device-specs/index.json` carries `helpful_urls` and
`helpful_videos` only for specs that define them. Absent fields are omitted,
not emitted as empty arrays. Each reference entry requires `title` and an
HTTP(S) `url`; `description` is optional. Contributors should only add links
they have verified resolve.

## Recommended update-polling flow

Applications should poll the manifest periodically (e.g., once daily at
startup, or via a webhook).  GitHub Pages serves these files with
standard HTTP caching headers.  A well-behaved client can use conditional
requests to avoid re-downloading unchanged data:

```
# 1. Fetch the manifest
GET /api/v1/manifest.json
If-None-Match: "<etag from previous response>"
# → 304 Not Modified if nothing changed

# 2. Compare each entry's checksum/updated_at against your cache
for each device in manifest.devices:
    if device.checksum != local_cache[device.id].checksum:
        # 3. Fetch the updated per-device spec
        GET /api/v1/devices/{device.id}.json
        local_cache[device.id] = {spec, checksum: device.checksum}
```

Recommended polling interval: once per day (or once per app launch).
GitHub Pages is not a high-frequency API; treat it as a CDN-backed
static registry, not a real-time service.

## Building locally

```bash
pip install -r requirements.txt
python scripts/build_index.py
# Output in site/api/v1/manifest.json and site/api/v1/devices/*.json
```

To validate without writing files (useful in pre-commit hooks):

```bash
python scripts/build_index.py --check
```
