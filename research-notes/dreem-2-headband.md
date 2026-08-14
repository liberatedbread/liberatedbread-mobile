# Dreem 2 EEG Sleep Headband — Research Notes

Consumer EEG sleep headband by Rythm/Dreem (Paris, founded 2014). Five EEG electrodes,
pulse oximeter, accelerometer, bone-conduction audio for deep-sleep sound stimulation.
Category: sleep tracker (EEG wearable).

## Why it is abandoned
- Beacon Biosignals acquired Dreem's R&D business on 2023-07-11 and pivoted it to
  B2B clinical-trial monitoring — [Beacon press release](https://beacon.bio/press-releases/beacon-biosignals-acquires-dreem-launches-at-home-sleep-monitoring-services-for-clinical-trials/).
- Consumer Dreem 2 accounts were deactivated after the acquisition; the consumer app
  was removed from stores and the consumer cloud is gone — secondary source:
  [businessmodelcanvastemplate, 2024-08-09](https://businessmodelcanvastemplate.com/blogs/owners/dreem-who-owns); corroborated by user reports collected in
  [LiveWorkSleep, 2026](https://liveworksleep.com/dreem-headband-discontinued-alternatives/).
- The hardware line survives only as the clinical Dreem 3S / "Waveband" (FDA 510(k)
  K223539) with a gated Beacon Pal app — not usable by consumers.

## Local BLE feasibility
- The headband is a BLE peripheral; the consumer app paired over BLE and streamed /
  offloaded recordings over BLE.
- **Prior art exists**: [A closer look at the Dreem EEG Headband — majorinput.co.uk, 2022-02-18](https://www.majorinput.co.uk/post/a-closer-look-at-the-dreem-eeg-headband)
  documents logging low-quality EEG from the Dreem in real time, with scripts on GitHub
  (linked from the post). This proves the BLE stream can be tapped without the cloud.
- The cloud was used for sleep staging, CBT-i programs and account sync. Raw
  acquisition and audio stimulation are on-device; how much configuration requires an
  authenticated session is the key unknown.
- **Verdict: promising but hard.** App removal + account deactivation raise the bar.

## APK provenance
- **Package**: believed `com.rythm.dreem` (consumer "Dreem" app) — **NOT fetchable**:
  absent from apk-pure; removed from Google Play. No mirror located during triage.
- Difficulty impact: high. Options: adb pull from a device that still has the app,
  Internet Archive / APKCombo manual search, or RE from the prior-art scripts above.

## Open questions
- Does a factory/never-paired Dreem 2 require cloud account activation before BLE works?
- BLE service/characteristic map and stream frame format (prior-art repo may have these).
- Bone-conduction stimulation trigger path (on-device closed loop vs app-driven).

## Status
- apk_acquired: **no** (app withdrawn; not on mirrors checked); apk_decompiled: no.
- Safety class: MODERATE — EEG wearable with audio neurostimulation; consumer wellness
  device, but any RE client should not alter stimulation behaviour blindly.
