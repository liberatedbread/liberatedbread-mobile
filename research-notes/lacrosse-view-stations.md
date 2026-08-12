# La Crosse View Wi-Fi Stations (V40A-PRO, V21-WTH, C85845, S81120…) — Research Notes (VERDICT: dud, at-risk)

## What it is
La Crosse Technology (La Crosse, WI; family-owned, active) sells Wi-Fi
weather stations whose displays bridge sensors to the **La Crosse View**
cloud/app. Products are current and sold widely.

## Local situation — none
- The station's Wi-Fi is used **only** to push to the La Crosse View cloud;
  no local web UI, no documented LAN API, no custom-server option.
- Home Assistant core `lacrosse_view` integration is **`iot_class: Cloud Polling`**
  ([home-assistant.io/integrations/lacrosse_view](https://www.home-assistant.io/integrations/lacrosse_view/)) —
  the integration itself goes through the vendor API, and its 2022–2025 issue
  history is a litany of cloud flakiness.
- Setup requires creating a La Crosse View account in the app
  ([vendor setup doc](https://lacrossetechnology.zendesk.com/hc/en-us/articles/4405783172123)).
- No community local-RE project found (checked 2026-08-07): unlike Ecowitt/
  Ambient/Tempest/Davis there is no LAN endpoint, UDP broadcast, or custom
  upload to point at. The station hardware (ESP-class Wi-Fi) likely talks
  TLS to the cloud — sniffing would be MITM, out of scope.

## Risk assessment
- Service currently up (vendor support site active, Zendesk updated). But the
  product line is 100% cloud-dependent: if La Crosse View dies, the Wi-Fi
  function of these stations dies with it — the classic "at-risk" profile.
- Sensors are La Crosse 433 MHz TX; some are decodable by rtl_433
  (`lacrosse` decoders) — RF tier, not Wi-Fi.

## Verdict
**Reject for now; revisit if cloud dies.** If La Crosse View ever shuts down,
these become a genuine RE target (intercept provisioning, spoof the cloud
endpoint like picobrew). Until then there is no local path to document.

## APK
`com.lacrosse.technology.lacrosseview` (fetchable via apkeep) — not fetched;
no local endpoints to extract, and cloud API RE is out of scope.
