# Philips PulseRelief + BlueTouch — App-Controlled BLE Pain Therapy — Research Notes

Date researched: 2026-08-04.

## What it is
Two Philips consumer pain-therapy wearables launched 2014–2015, both driven
exclusively over BLE by the "Philips Treatment" app:
- **PulseRelief PR3840/00 (and PR3841)**: wireless one-channel TENS/EMS pod
  (15 TENS + 5 EMS programs, 60 intensity levels) that snaps onto hydrogel
  electrodes ([Philips product page](https://www.philips.ae/c-p/PR3840_00/pulserelief-wireless-electrotherapy) — "Unfortunately this product is no longer available").
- **BlueTouch PR3741/00, PR3743/00**: blue-light therapy patch for back pain
  ([Philips UK support page](https://www.philips.co.uk/c-p/PR3743_00/bluetouch-app-controlled-pain-relief-patch/partsandaccessories) — marked **Discontinued**).

## Why it is abandoned
- Both products discontinued years ago (Philips pages above); the product line
  was quietly dropped from Philips' consumer health portfolio.
- The companion app's cloud side is already rotten: Philips' own Treatment-app
  privacy notice says "our service is temporarily suspended for maintenance"
  ([philips.com.om privacy notice](https://www.philips.com.om/c-w/privacy/treatment-app-privacy-notice.html)).
- App is ancient: targets Android 4.4–8 era; modern-Android install may fail
  (per APK mirror metadata). Devices have no local controls — no app = brick.

## Local BLE feasibility: HIGH (confirmed by static analysis)
- App scans by **advertised service UUID** (BluetoothScanner.java,
  `ScanFilter.setServiceUuid`):
  - PulseRelief: `de18f4e1-9352-4d9c-a802-58f25ec97cc3`
  - BlueTouch: `d25f1008-5579-46e5-a115-5068c9961894`
- Full characteristic maps for both devices recovered from
  `model/meta/PulseReliefCharacteristics.java` and `BlueTouchCharacteristics.java`
  (see YAML). Semantics are self-describing: SELECTED_PROGRAM, CHANNEL_INTENSITY,
  TREATMENT_TIME_REMAINING, SET_PROGRAM_NUMBER, SET_TREATMENT_TIME,
  INCREMENT/DECREMENT/ZERO_CHANNEL, ELECTRODE_CONNECTION_STATUS, BATTERY_LEVEL, etc.
- All treatment control is local BLE; the app needs no account (diary/cloud
  features optional). GattManager implements plain queued write/read/notify.

## APK Provenance
- **Package**: `com.philips.cl.painrelief` ("Philips Treatment")
- **Source**: apkeep, apk-pure; versions 2.5, 3.0, 3.1, 3.3 listed; downloaded 3.3
- **APK SHA-256**: `75a07422e106d4a48c8ae65d1f85cf5338df92b9b992f93450a655a9fe55c997`
- **Framework**: Native Java, unobfuscated (`com.philips.cl.painrelief.*`),
  old Adobe Mobile analytics bundled

## Protocol notes
- PulseRelief command characteristics (write): SET_PROGRAM_NUMBER, SET_TREATMENT_TIME,
  INCREMENT_CHANNEL, DECREMENT_CHANNEL, ZERO_CHANNEL, SET_SYSTEM_TIME, FACTORY_RESET.
- State characteristics (read/notify): ELECTRODE_CONNECTION_STATUS, SELECTED_PROGRAM,
  CHANNEL_INTENSITY, TREATMENT_TIME_REMAINING, BATTERY_LEVEL, BODY_PART, PAIN_SCORE,
  POST_TREATMENT_SENSATION.
- Log/diag channel: START_GET_LOG, CONTINUE_NEXT_BLOCK, LOGDATA, SEND_LOG_FINISHED.
- BlueTouch has a parallel but distinct UUID set (see YAML).
- Value encodings TBD (byte-level formats need HCI snoop or deeper read of
  `bluetooth/device/PulseReliefDevice.java` handlers).

## Open questions
1. Byte encodings for program/intensity/time writes.
2. Whether app 3.3 runs on modern Android (targets API ~23–26 era) — else use an
   old phone/VM; or reimplement from this spec directly.
3. BlueTouch treatment start/stop flow (characteristic set is smaller; possibly
   only status + satisfaction scoring, with on-device session timing).

## Safety
safety_class MEDIUM (PulseRelief is an electrical stimulator; BlueTouch is
LED/heat only, LOW). App-level intensity stepping only; firmware enforces limits.
