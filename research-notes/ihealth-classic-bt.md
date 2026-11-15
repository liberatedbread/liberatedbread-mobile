# iHealth Classic BT Line (BP3/BP5/BP7, HS3, BG5) — Research Notes

## Product & Company Status
- **Products**: iHealth early "Made for iPhone" connected-health line — BP3/BP5 (arm) and BP7 (wrist) blood pressure monitors, HS3 scale, BG5 glucose meter. All discontinued.
- **Transport**: Bluetooth Classic **V3.0+EDR** (distributor spec sheet, [FlipHTML5, 2016](https://fliphtml5.com/wkqc/qjzk/)). iHealth's own SDK docs list these exact models as **"classic bluetooth devices"** that pair via the OS Bluetooth settings rather than in-app scanning ([iHealth SDK docs](https://chenxuewei-ihealth.github.io/ihealthlabs-sdk-docs/docs/ios/quickstart/)).
- **Company**: iHealth Labs is alive but **pivoted to COVID/flu rapid antigen tests** ([ihealthlabs.com news, 2026](https://ihealthlabs.com/pages/news)) — the connected-device line is legacy.
- **⚠ Cloud dependency (official path)**: the vendor SDK requires a **cloud authentication call before any device connection is permitted** — "call the authentication interface to get permission... otherwise you will not be able to scan the connection to any device" (SDK docs above; `IHSDKCloudUser` in the [iOS SDK example](https://github.com/iHealthLab/iHealth-ios-sdk-example)). The raw RFCOMM link itself has no cloud need — the gate is purely in iHealth's software.

## Protocol Facts
- Link layer is plain Bluetooth Classic; on Android these devices were driven over RFCOMM (SPP UUID), paired in OS settings per the SDK docs.
- Byte-level command protocol is **proprietary and not publicly documented**; no credible community RE found (searched 2026-08 — only generic SPP noise). The vendor SDKs (binary `.a` / jar) embed the protocol.
- BG5 glucose meter is the same TaiDoc-era platform family as many OEM meters — a capture session may reveal shared framing, but that is speculation.

## APK Provenance
- **Package**: `com.ihealth.MyVitals` (MyVitals app) — listed on APKPure.
- **Fetch failed**: `apkeep -a com.ihealth.MyVitals -d apk-pure` returns an empty version list (APKPure listing exists, no downloadable versions). No APK acquired, no static pass possible. Raises difficulty: protocol must come from a **live HCI/SPP capture** against real hardware, or from unpacking the vendor SDK jars from another mirror.

## Local Feasibility Verdict
**Hypothesis, medium-high difficulty.** Local control is almost certainly achievable over RFCOMM (device-side has no cloud logic), but there is no public protocol doc and the official app path is cloud-gated. Requires hardware + capture, or a working APK mirror.

## Safety
- BG/BP readings inform treatment — MEDIUM safety class.

## Open Questions
- Alternate APK mirror for `com.ihealth.MyVitals` (APKCombo, APKMonk) for static analysis of the RFCOMM command bytes.
- Whether the SDK's cloud-auth is a one-time activation or per-connection.
- BG5 vs TaiDoc TD-4279 framing overlap.
