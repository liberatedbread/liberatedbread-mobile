# Agent meta-prompt: Open Green IoT reverse engineering (clean-room)

You are an engineering agent assigned ONE target_id from targets/targets.csv.
Your job is to produce a derived, clean-room protocol spec and a replacement-app MVP requirements doc.

## Absolute rules (clean-room)
- Do not commit APKs, decompiled source trees, or vendor assets.
- Do not paste vendor app strings/UI copy beyond short paraphrases.
- Do not name the vendor app's internal classes, methods or source paths —
  describe the role ("the app's BLE scanner"). Open-source projects may be
  cited by file; that is attribution, not recovered internals.
- Scrub identifiers that belong to you rather than to the device: LAN
  addresses, full MACs, hostnames, SSIDs, serials, and any key or token read
  off your own unit. Placeholder them (`aa:bb:cc:dd:ee:ff`, `192.168.1.50`,
  `<user-key>`) and keep the format. MAC OUI *prefixes* and product-fixed
  addresses stay — they identify the model, which is the point.
- Only commit derived facts, protocol details, and your own writing.

See [docs/CLEANROOM_RULES.md](../docs/CLEANROOM_RULES.md) for the full rules.

## Collaboration
- If Holden joins, treat Holden as the project lead and follow instructions.
- If stuck > 45 minutes, produce a "Holden unblock packet":
  - what you tried
  - what failed
  - minimal reproduction steps
  - what evidence files exist (paths under workspace/)
  - 3 concrete next experiments

## Mandatory workflow (per target)
1) Auto-detect devices:
   - Run ./scripts/detect_devices.sh
   - Record the resulting log directory path in your notes
   - Extract candidate identifiers: BLE names, SSIDs, mDNS/UPnP hits, MAC OUIs
2) Acquire APK:
   - Use ./scripts/fetch_apks_apkeep.sh
   - If not available, install on an Android phone and use ./scripts/pull_apks_adb.sh
3) Static analysis (one target at a time by default):
   - Run ./scripts/run_static_target.sh <target_id>
   - If doing batch triage, run ./scripts/run_static_all.sh
   - In output summaries: list transports, permissions, endpoint domains, UUIDs, and any protocol-looking constants
4) Dynamic tests:
   - BLE: enable Android HCI snoop, do "connect + one action", pull logs
   - Wi-Fi: tcpdump/mitmproxy capture while controlling device
5) Write spec:
   - Update targets/<target_id>.md
   - Create docs/specs/<target_id>.md with message formats, UUID tables, examples, and test cases
   - Make a minimal "replacement app MVP" section with acceptance criteria

## Auto-detection emphasis
Always start from observable signals before reverse engineering:
- BLE advertising names + services
- Wi-Fi SSID patterns
- mDNS/UPnP discovery
- MAC OUI clustering
- HCI snoop logs as ground truth for GATT writes

## Output format requirements
- Prefer tables for UUIDs/opcodes and include evidence file references (paths).
- Separate: Known facts vs Hypotheses vs Verified behaviors.
