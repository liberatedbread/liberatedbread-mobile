# AcuRite Access / Atlas — Research Notes (VERDICT: dud for local-only)

## What it is
AcuRite (Chaney Instrument / Primex Family) Iris 5-in-1 and Atlas 7-in-1
stations; AcuRite Access hub (09155M) hears their 433 MHz sensors and uploads
to My AcuRite cloud. Atlas was the flagship (UV/light lux, dual wind).

## Local situation — interception only
- Access hub has **no documented local API, no custom-server option**: it
  hard-codes uploads to `hubapi.myacurite.com`.
- The only "local" capture is DNS-redirecting the hub's cloud hostname to a
  LAN server — **Acuparse** ([acuparse.com](https://www.acuparse.com/),
  active releases) parses those intercepted posts. That is a
  MITM/interception path → **out of scope for this repo's local-only rule**.
- Sensors themselves are readable locally over RF with rtl_433 (well
  supported: `acurite` decoders), but that is SDR sniffing, not Wi-Fi/LAN
  device access → also out of scope for a wifi spec.
- Older smartHUB: end of service 2019-02-28
  ([official AcuRite blog, 2018-02-24](https://www.acurite.com/blogs/default-blog/extending-end-of-service-and-support-for-acurite-smarthub)).

## Product/company status (checked 2026-08-07)
- **Atlas 7-in-1 (01008) and the Access-with-Iris bundles are listed on
  AcuRite's own "Discontinued Products" support category**; third-party
  support channels report Access "no longer available".
- AcuRite/My AcuRite portal itself still operates (support site active),
  so existing users are cloud-dependent with no exit path.
- 38+ discontinued-product articles on the support site — the Wi-Fi line is
  being wound down.

## Verdict
**Reject for local Wi-Fi spec.** Only paths are (a) DNS-intercept of cloud
uploads (Acuparse) or (b) rtl_433 RF sniffing — neither is LAN device access.
If the repo ever adds an "interception" or "RF" tier, Acuparse + rtl_433
decoders are the references.

## APK
My AcuRite app exists (`com.acurite.…`) but pointless: no local endpoints to
extract. Not fetched.
