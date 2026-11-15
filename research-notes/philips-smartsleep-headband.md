# Philips SmartSleep Deep Sleep Headband — Research Notes

Soft headband (HH1600/HH1601, 2018) with two EEG/EOG forehead sensors that detects
deep sleep and plays quiet audio tones to enhance slow-wave sleep. Companion app:
SleepMapper. Category: sleep wearable.

## Why it is at-risk
- Product is **discontinued** by Philips (marked "Discontinued" on philips.com product
  pages; the whole SmartSleep consumer suite — headband, snoring relief band,
  connected Somneo — has been wound down) — [Philips product page](https://www.usa.philips.com/c-p/HF3670_60/smartsleep-connected-sleep-and-wake-up-light) shows the
  sibling SmartSleep Connected light as discontinued; the headband vanished from retail 2022-ish.
- Philips as a company is alive, so this is *at-risk* rather than dead: the SleepMapper
  app (com.philips.sleepmapper.root) is still distributed and still fetchable, but the
  device line it serves no longer exists — classic pre-orphan state.

## Local BLE feasibility
- The headband talks to the phone over BLE. Notably, the radio is **off during the
  night** (by design, to avoid EMF during sleep); data is dumped over BLE when the
  session ends — [review paper PDF](https://pdfs.semanticscholar.org/0801/3b3df3349de3e35b195cedb047f787218814.pdf).
- Tone playback during deep sleep is closed-loop **on-device**; the app only
  configures sessions and collects results. That means core function is inherently
  local; cloud is account/sync/coaching only.
- Philips help docs confirm a SleepMapper *account* is used for data backup across
  phones, but sync to the headband itself is BLE — [Philips support, 2021-09-20](https://www.usa.philips.com/c-t/XC000014438/my-philips-smartsleep-deep-sleep-headband-cannot-connect-to-the-sleepmapper-app).
- No prior community RE found. **Verdict: viable; greenfield protocol.**

## APK provenance
- **Package**: `com.philips.sleepmapper.root` (SleepMapper)
- **Source**: apkeep, apk-pure (2026-08-03)
- **APK SHA-256**: `666772c1a285aeea6459601289f66c2a25ecbfb49a760e690e92389f1153e8f6` (71 MB)
- Shared codebase with DreamMapper (Philips Respironics CPAP): packages
  `com.philips.dreammapper.*`, `com.philips.respironics.*` — the headband-specific BLE
  code must be separated from CPAP BLE code during deeper analysis.

## BLE UUIDs (cheap static triage, from DEX strings)
Custom 128-bit UUID candidates (roles TBD — not yet attributed headband vs CPAP):

| UUID |
|------|
| `210b4d64-8147-471e-b6cb-244a2c939455` |
| `22a4e311-a097-4517-9b81-cf32af60b982` |
| `4553867f-f809-49f4-aefc-e190a1f459f3` |
| `676d860a-a2a9-4d7b-b25d-8be9a51dd69c` |

Also seen: `0000feff` (16-bit), SPP `00001101`, CCCD `00002902`. `BluetoothGatt` use
confirmed (5 call sites in strings). A focused jadx pass on non-respironics packages
is the next step.

## Open questions
- Which of the custom UUIDs belong to the headband; session config command format.
- Whether a SleepMapper account login is mandatory before the app will talk to the headband.
- Advertising name (likely "SmartSleep" or "HH1600").

## Status
- apk_acquired: yes; apk_decompiled: strings-triage only; uuids_recovered: partial;
  protocol_recovered: no.
- Safety class: MODERATE — plays audio tones during sleep based on EEG staging;
  wellness device, but RE clients should treat stimulation control carefully.
