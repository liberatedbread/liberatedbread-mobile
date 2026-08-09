# Rainforest Automation EAGLE-200 — Research Notes

## What it is
EAGLE-200 (RFA-Z109) is a WiFi+Ethernet gateway that joins a utility smart
meter's Zigbee Smart Energy (HAN) network and exposes the meter's data:
instantaneous demand, delivered/received summation, price, utility messages.
Rainforest Automation (BC, Canada) — support site active as of 2025-10.

## Local API — vendor-documented
Rainforest publishes the "EAGLE-200 Local API Manual" (v1.0, 2017; linked from
support.rainforestautomation.com article 76). The local API talks to the
device directly on the LAN:

- HTTP POST to port 80 (`/cgi-bin/post_manager`), XML command body, e.g.
  `<Command><Name>get_instantaneous_demand</Name></Command>` → XML response
  with demand, multiplier/divisor, timestamps. A JSON variant is also offered.
- Commands include: `get_instantaneous_demand`, `get_current_summation`,
  `get_price`, `get_message`, `list_network`, plus `get_history_data` for the
  on-device upload queue.
- Auth: HTTP Basic where the credentials are `CloudID:InstallCode` — **both
  printed on the label on the bottom of the unit**. No internet account is
  needed to use the local API (darconeous curl gist, 2022-08).
- Push option: the EAGLE can also "upload" its data to an arbitrary HTTP
  endpoint — point it at a LAN server and nothing leaves the network.

## Cloud requirement
None for data access. The one external dependency is the **utility**, not a
vendor cloud: the EAGLE's MAC must be joined to the meter's HAN by the utility
(standard process, done once, no ongoing connectivity). After that the box
works standalone.

## Integrations
HA custom component "Rainforest Eagle-200 local meter reader" (HA community
thread 110656, 2019–2022); openHAB REST examples; Universal Devices nodeserver
notes (2023).

## Open questions
1. Transcribe the full command/response XML schema from the Local API Manual
   PDF (multiplier/divisor application, digit formatting).
2. Distinguish EAGLE-200 from the older EAGLE (RFA-Z109 gen1, 2014): older
   unit serves a similar local page but different endpoint behavior (per HA
   thread report).
3. Successor "Eagle 3" — same API? (UD forum, 2023-12 — verify.)

## Safety
LOW — no mains wiring; reads the utility meter over Zigbee SE.
