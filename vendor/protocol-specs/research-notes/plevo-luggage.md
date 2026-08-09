# Plevo (Runner / Infinite / Up) — BLE Smart Luggage Research Notes

## What it is
Plevo smart luggage line (Kickstarter 2018, ~$320K raised; PLEVO LLC,
Buenos Aires/Miami): carry-on and checked suitcases plus Urban/Journey
bags with a motorized Smart Lock (unlock via app with Face ID / Touch ID,
or a **Morse-code tap pattern on the bag itself** as phone-free backup),
built-in weight sensors, removable battery pack, GPS tracking, distance
alert. App: "PLEVO" (`com.plevo`).

## Why it's at-risk / effectively orphaned (dated evidence)
- 2018-06/08: Kickstarter + Indiegogo InDemand campaigns
  (https://www.prweb.com/releases/after-raising-more-than-a-quarter-million-dollars-on-kickstarter-crowdfunding-for-plevo-smart-luggage-moves-to-indiegogo-indemand-887997940.html).
- 2025-09-03: still doing PR (Entrepreneur advertorial), but the store
  shows products only as "Pre-Order" — classic zombie-store pattern.
  (https://www.entrepreneur.com/living/this-kickstarter-funded-company-is-making-luggage-smarter/347361)
- 2026-08-03 (verified): Android app `com.plevo` returns 404 on Google
  Play; Apple Search API shows no Plevo luggage app (the "My Plevo" /
  "Plevo Check" iOS apps are an unrelated German car-sharing company,
  Plevo GmbH). APKPure keeps a stub page for `com.plevo` but lists zero
  downloadable versions. The only surviving binary lead is APKCombo,
  which lists **v1.0.5 dated 2018-11-15** — i.e. the app was likely
  never updated after 2018 and has since been pulled from both stores.

## Local BLE feasibility
- Lock/unlock and weight readout are BLE app<->bag functions; GPS
  location and flight-status features were cloud (dead/unknown).
- The Morse-code mechanical fallback means failed BLE RE cannot strand an
  owner — good safety property.
- No known community RE (GitHub search 2026-08-03: nothing). Greenfield.

## APK details — partially fetchable (verified 2026-08-03)
- Package: `com.plevo` (APKPure slug confirmed; APKCombo page live).
- apkeep against apk-pure fails (APKPure lists no versions for the
  package). APKCombo has v1.0.5 (2018-11-15) but its download is
  JS/token-gated — not fetchable by plain curl in this session.
  Practical routes: browser download from APKCombo, the
  nirewen/apkcombo-downloader CLI, or adb pull from an owner handset.
- Version on APKCombo predates any later firmware, but 2018-era firmware
  is what most delivered bags run.

## Safety class
LOW for RE: Morse-code fallback on the lock. Moderate real-world value:
owners whose phones die/change have already lost app access since the
app is delisted — local BLE tooling is the only rescue path.

## Open questions
- Does first pairing require a Plevo cloud account? (2018 app — likely
  email signup; if the pairing secret is server-issued, local control
  needs an enrolled-phone HCI capture.)
- BLE name prefix / UUIDs — unknown; nRF Connect scan needed.
- Is the company actually still shipping? Site is live with pre-orders;
  no dated delivery evidence found post-2019.

## Next steps
1. Pull com.plevo v1.0.5 from APKCombo via browser (JS flow) — extract
   BLE UUIDs and pairing logic with jadx.
2. nRF Connect scan of a live Plevo bag to confirm UUIDs/name.
3. HCI snoop lock/unlock + weigh from an enrolled phone.
