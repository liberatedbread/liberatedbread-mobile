# Chamberlain/LiftMaster myQ — Research Notes (DUD: local control actively blocked)

## What it is
myQ is Chamberlain Group's WiFi platform (hubs 821LM/MYQ-G0301, openers with
built-in WiFi) covering ~60%+ of the North American residential garage
market. Vendor very much **active** (myq.com reachable 2026-08-07) — this is
a *hostile* active vendor, not an abandoned one.

## Verdict: DUD for local control — cautionary tale
- There is **no LAN API** on myQ hubs/openers; all app traffic goes to
  Chamberlain cloud. Documented local paths: none.
- Chamberlain **actively broke third-party cloud API access** in late 2023;
  Home Assistant removed the myQ integration in release 2023.12
  (home-assistant.io/blog/2023/11/06/removal-of-myq-integration/).
- Earlier they removed HomeKit from the MyQ Home Bridge and discontinued it.
- Nov 2023: Chamberlain briefly blacklisted the ratgdo board's commands,
  then relented under public pressure — evidence of active enforcement
  against local interop.
- The only remaining community "paths" are cloud MITM/token scraping
  (out of scope here and repeatedly broken) or reflashing/replacing hardware.

## Rescue path
Hardware replacement of the control path:
- **ratgdo** (see ratgdo note) — speaks Security+ 2.0 serial locally; the
  standard answer for yellow-learn-button openers.
- Any dry-contact controller (OpenGarage, Garadget, Meross MSG100,
  iSmartGate, Tailwind iQ3 2.0/2.1, Shelly) works on pre-2012 Sec+ 1.0 and
  non-Chamberlain openers.
- Vendor warning (Tailwind, 2026): 2025-manufacture white-learn-button
  Chamberlain openers accept **only** MyQ controls — ratgdo compatibility
  for those units must be verified before advising owners.

## APK
Not fetched — no local protocol exists to recover from the app.

## Rating
Dud — verified 2026-08-07 against HA blog (2023-11-06), LTT forum
(2023-11-02), and jpk.io ratgdo build log (2026-06-24).
