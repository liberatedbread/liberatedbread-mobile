# Vestaboard — Local API Research Notes

## What it is
Vestaboard: 6×22 (132-character) mechanical split-flap display for home/office
ambient messaging. Company (Vestaboard Inc., San Francisco) alive — shop and
legal pages updated June 2026. Stands out for an **official, documented Local
API** alongside its cloud API.

## Local interface — confirmed (vendor-documented)
Docs: docs.vestaboard.com → Local API.

- Endpoint: `http://vestaboard.local:7000/local-api/message`
  (mDNS hostname `vestaboard.local`, or board IPv4; IPv6 flagged unreliable
  by vendor).
- `POST /local-api/message` — write a message: JSON array of 132 character
  codes (0 = blank, 1–26 = A–Z, 27–36 = digits, 62–70 = colored tiles:
  red/orange/yellow/green/blue/violet/white/black family per vendor charset).
- `GET /local-api/message` — read back the currently displayed message.
- Auth header on every request: `X-Vestaboard-Local-Api-Key: <apiKey>`.
- Enablement (one-time): request an "enablement token" from Vestaboard
  (web form / mobile app), then one POST to the board's
  `/local-api/enable` with that token → board replies
  `{"message": "Local API enabled", "apiKey": "..."}`. The apiKey is used
  for all future requests.
- Vendor explicitly blesses decoupling: "If you would like to decouple your
  Vestaboard from our cloud, you can set your firewall accordingly and only
  use the Local API."

## Cloud dependency — the honest bit
- Eligibility for the enablement token requires the board to be **paired and
  online for the latest firmware update** (vendor auth doc) — i.e. one-time
  cloud contact and a Vestaboard account are required today.
- Firmware updates will continue to require cloud connectivity.
- If the company dies: boards with an already-issued local apiKey keep
  working locally indefinitely; boards without one cannot newly enable the
  local API unless the enable endpoint accepts arbitrary tokens (untested —
  key open question).

## Existing implementations
- jparise/vesta (Python) — `LocalClient` with enable/read/write.
- ShaneSutro/Vestaboard (Python) — local API support since v1.2.0.
- DanielBaulig/vestaboard — Home Assistant HACS integration using local API.
- jefflaplante/vesta — Go CLI supporting local API keys.

## APK
Companion app exists but unnecessary — vendor-documented protocol.
Not fetched.

## Open questions
1. Does `/local-api/enable` validate the enablement token against cloud, or
   only format-check it? (Determines post-cloud-death enablement.)
2. Exact character-code table (transcribe from docs during spec work) and
   behavior of Vestaboard Note (smaller model) on the same API.
