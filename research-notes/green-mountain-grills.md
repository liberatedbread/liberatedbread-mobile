# Green Mountain Grills WiFi Pellet Grills — Research Notes

## What it is
Green Mountain Grills (GMG, Reno NV — company ACTIVE) WiFi-enabled pellet
grills/smokers: Daniel Boone, Jim Bowie, Ledge/Peak (Prime/Prime+ series),
Trek/Davy Crockett (portable). Grill controller joins the home WiFi; the
vendor app works in "local mode" on the LAN and optionally via GMG cloud
for remote access.

## Local feasibility — confirmed, no cloud needed at all
The controller speaks an unauthenticated ASCII protocol over **UDP port
8080** on the LAN. Fully reverse-engineered and re-implemented many times:

- github.com/jwhitby91/gmg_home_assistant — HACS custom integration
  (climate entity, grill + 2 probe temps, set temp, power on/off/cold-smoke).
- github.com/facultymatt/gmg-js — Node client + web UI.
- github.com/FeatherKing/grillsrv, github.com/brandenco/green-mountain-grill
  — Go implementations.
- HA Community thread "Green Mountain Grill" (community.home-assistant.io/t/149007,
  2019–2024) — confirms grill also answers HTTP on port 80 (status page).

## Protocol (from gmg_home_assistant source, all UDP 8080, ASCII)
| Frame | Meaning |
|---|---|
| `UL!` (broadcast) | Discovery — grills reply with serial (`GMG...`) |
| `UR001!` | Status query — big positional field reply: on/off, grill temp, set temp, probe 1/2 temps + set temps (temps as byte pairs, °F) |
| `UT<temp>!` | Set grill target temp (150–500 °F) |
| `UF<temp>!` | Set probe 1 target temp (32–257 °F) |
| `Uf<temp>!` | Set probe 2 target temp |
| `UK001!` | Power on |
| `UK002!` | Power on, cold-smoke mode |
| `UK004!` | Power off (starts fan cooldown cycle) |

No auth, no token, no handshake — any host on the LAN can drive the grill.
First-time WiFi provisioning is local (grill AP mode + app, or point-to-point
mode where the grill hosts its own AP and the same UDP protocol works).

## APK
Not needed — protocol fully RE'd by multiple independent implementations.
GMG app (`com.greenmountaingrills.app` or similar) not fetched.

## What needs cloud
Nothing. Cloud is only for out-of-home monitoring; the vendor app has an
explicit local mode. A blocked-internet grill loses nothing on the LAN.

## Open questions
1. Newer Prime+/Peak 2.0 firmware — verify the same command set (community
   reports 2024 suggest yes; one user noted the grill's HTTP page reports
   port 8080 "even though that's not what it's listening on" — UDP vs TCP).
2. Full status-reply field map (indexes beyond ~30, e.g. warn states,
   auger/fan readings) — only partially mapped in the libraries.
3. Prime+ "WiFi server mode" changes, if any.

## Safety
Live-fire appliance (wood pellets, auger-fed firepot). Power-off is a timed
fan cooldown, not instant — clients must never bypass it. Range-clamp set
temps (150–500 °F) as the libraries do. Unattended power-on over LAN with
no auth is a real hazard: document the risk, don't remove the cooldown.
