# Neurio W1-HEM / Generac PWRview — Research Notes

## What it is
Neurio W1-HEM is a WiFi whole-home energy monitor (2–4 CTs + voltage taps)
from Neurio Technology (Vancouver). Generac acquired Neurio in 2019 and
rebadged it as the PWRview Home Energy Monitor.

## Why it's abandoned — the local API is the rescue
- Generac support notice: support for the Neurio W1-HEM and the PWRview mobile
  app was **discontinued on 2025-03-10**; the Neurio PWRview app was pulled
  from the app stores (support.generac.com PWRview topic; cleanenergy.generac.com
  article "Which PWRview App Should I Download", both retrieved 2026-08-07).
- The old cloud API (`api.neur.io`) and its OAuth flow are the pieces at risk;
  owners have already watched the cloud integration break during the Generac
  migration (home-assistant/core#40588, 2020).

## Local API — vendor-documented, no auth
Neurio's own developer docs (api-docs.neur.io, section "Sensor Local Access")
document a JSON endpoint served directly by the sensor:

```
GET http://<device-ip>/current-sample
→ {
    "sensorId": "0x0000C47F51019B7D",
    "timestamp": "2018-09-22T13:28:31Z",
    "channels": [ {"type": "PHASE_A_CONSUMPTION", "ch": 1,
                   "eImp_Ws": ..., "eExp_Ws": ..., "p_W": 645,
                   "q_VAR": 79, "v_V": 123.087}, ... ],
    "cts": [ {"ct": 1, "p_W": 645, "q_VAR": 79, "v_V": 123.087}, ... (4 CTs) ]
  }
```

- Channel `type` values: PHASE_A/B/C_CONSUMPTION, NET, GENERATION,
  CONSUMPTION, SUBMETER. Energy in watt-seconds (import/export), power in W,
  reactive in VAR, voltage in V.
- No authentication, plain HTTP on port 80. 1 Hz polling is the community norm.
- The device also serves a small local web UI (device status/config).

## Cloud requirement
None for data: `/current-sample` works with the device firewalled from the
internet. Initial Wi-Fi provisioning is local too — the sensor hosts its own
setup AP and web pages (the dead mobile app is not required for the local JSON
path). What dies with the cloud is only the app, appliance disaggregation, and
historical dashboards — none of which the local endpoint ever provided.

## Integrations
- Home Assistant: REST sensor on `/current-sample` (worked examples in HA
  community thread 69946, 2018–2021); the old core `neurio_energy` integration
  was cloud-based and should not be used.
- Hubitat: community "Neurio/PWRView Home Energy Monitor Driver" (2021-06).

## Open questions
1. Full list of local web UI pages (config without the app — e.g. changing
   Wi-Fi after the app is gone). Community reports setup via the on-device AP.
2. Whether firmware updates ever shipped post-Generac — assume frozen firmware.

## Safety
CTs + voltage taps in the breaker panel — installer-grade work. Measurement-only.
