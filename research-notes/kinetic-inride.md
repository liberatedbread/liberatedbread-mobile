# Kurt Kinetic inRide / Smart Trainers — Research Notes

## What it is
Kurt Kinetic inRide: a BLE power-sensor pod that mounts on Kinetic fluid trainers and
broadcasts computed wattage (one of the first Bluetooth Smart power meters, 2012;
[DC Rainmaker review](https://www.dcrainmaker.com/2012/12/kinetic-inride-bluetooth-smart-power-meter-accessory-in-depth-review.html)).
Also covers Kinetic Smart trainers (R1 etc.) driven by the same "Kinetic Fit" app.

## Why it is abandoned / at-risk
- Kinetic's own support site states the inRide app is **"discontinued and unavailable
  online"** ([kurtkinetic.com support](https://www.kurtkinetic.com/support-sub/hc/en-us/articles/360008888632-Which-generation-inRide-sensor-do-I-have-)).
- The Kinetic Fit app is off Google Play (mirrors only; final version 1.4.23, ~2020).
- The trainer line has been stagnant for years; company support pages still up but the
  software ecosystem is dead.

## Local BLE feasibility — strong
- inRide pairs as a **standard BLE Cycling Power** device with third-party apps —
  TrainerRoad officially supports it
  ([TrainerRoad support](https://support.trainerroad.com/hc/en-us/articles/201377324-Kurt-Kinetic-inRide-Power-Meter)).
  Standard CPS = fully local, no cloud, no RE needed for basic power data. (Verify exact
  profile per inRide gen 1/2/3 with a scan — Wahoo forum reports gen differences.)
- Kinetic Fit dex shows FTMS (`00001826`) for smart-trainer control plus a custom family
  `e9410100`–`e9410304-b434-446b-b5cc-36592fc4c724` (likely Kinetic smart-trainer
  control/telemetry, e.g. R1) and DIS `180a`. Classes: `InRideSensor.java`,
  `InRide2Service.kt`, `InRideSensorFactory.java`.
- No account needed for third-party apps; Kinetic Fit cloud (workout sync) is optional.

## APK details (apkeep, apk-pure)
- Package: `com.kinetic.fit`, version 1.4.23 (final)
- SHA-256: `ff5399a36c8606f947b9537959f6ed0b6601e153a0a3ce6879c806e4d4eb98f9`

## Open questions
- Map the `e9410xxx` custom service: trainer control opcodes vs FTMS usage per model.
- inRide v1 vs v2/v3 profile differences (CPS availability per generation).
- Whether Kinetic Fit requires login for ERG control of R1 (likely not, but confirm).
