# Generic FTMS Walking Pads (incl. Mobvoi Home Walking Pad) — Research Notes

## What it is
A large and growing class of no-name / store-brand under-desk walking pads
ships with a **standards-compliant Bluetooth FTMS (Fitness Machine Service,
0x1826)** implementation instead of a proprietary protocol. The worked
example: the **Mobvoi Home Walking Pad** (advertises as "Mobvoi TM Fit";
companion app TicSports, `com.mobvoi.aitreadmill`), fully documented in a
2026-06-24 writeup by Ivan Morgillo, who drives it from a Linux box with
plain `gatttool`/Python into Home Assistant — no app, no account.

## Why this class matters
- Many cheap pads are abandoned-app magnets, but if the firmware speaks
  standard FTMS, the app dying is irrelevant: any FTMS client (qdomyos-zwift,
  a 50-line bleak script) controls the belt forever.
- The practical triage question for any unknown walking pad is therefore
  "does it advertise 0x1826?" — answerable with one nRF Connect scan.

## Documented protocol (Mobvoi unit, reported, working in production since 2026-01)
Control Point `0x2AD9` (properties: write-without-response + indicate —
use `gatttool --char-write`, NOT `--char-write-req`):

| Opcode | Meaning |
|--------|---------|
| `01` | Request Control (always first) |
| `07` | Start / Resume |
| `08 01` | Stop |
| `08 02` | Pause |
| `03 [lo][hi]` | Set Speed, 0.01 km/h little-endian |

Data notifications on `0x2ACD` (Treadmill Data): speed, distance, duration.

Discrepancy to note: the Bluetooth SIG opcode for Set Target Speed is `0x02`
(and KingSmith's MC-21 honors `0x02`, HCI-snoop-confirmed by
mcdax/walkingpad-controller). The Mobvoi writeup documents `0x03` working on
that firmware. Treat the opcode as per-firmware; try `0x02` first, fall back
to `0x03`. (Hypothesis: the writeup's byte order or opcode column may be
off-by-one, or Mobvoi's firmware is lenient.)

Operational quirks (Mobvoi unit):
- Pad only advertises for 1–2 minutes after power-on.
- Start needs a target speed first: `03 64 00` (1.0 km/h) → `07` → `03 64 00`
  again; prepend `08 01` to reset from a previous session state.
- BlueZ holds the connection briefly after gatttool exits — do a whole
  session in one interactive connection.
- BLE handshake takes 5–6 s; debounce any physical button triggering it.

## Local BLE feasibility
- Confirmed (Mobvoi): full local control + session tracking, no cloud, no
  account. Full script: github.com/hamen/tapirulan-home-assistant.
- Class-wide: hypothesis per-unit, but FTMS is a certification-driven
  standard; pads claiming Kinomap/Zwift compatibility are FTMS by
  definition.

## APK details
- TicSports (`com.mobvoi.aitreadmill`) exists on Android; not fetched —
  unnecessary, since the standard protocol needs no RE. The vendor app log
  file (`/sdcard/Android/data/com.mobvoi.aitreadmill/files/tic_sport/…log.txt`)
  leaks the pad's real BLE MAC, which is useful because Android masks MACs
  in `dumpsys bluetooth_manager` output.

## Open questions
- Which other no-name pads are FTMS (collect a list of advertised names:
  "Mobvoi TM Fit", generic "FS-*", etc.).
- Whether FTMS Request Control is enforced or advisory on these units
  (KingSmith MC-21 rejects it and proceeds anyway).

## Sources
- ivanmorgillo.com, "Walking Pad, Controlled by Code: BLE, FTMS, and a Phone
  Button", 2026-06-24 (full working setup)
- github.com/hamen/tapirulan-home-assistant (controller script)
- Bluetooth SIG FTMS 1.0 spec (0x1826 / 0x2ACD / 0x2AD9)
- KingSmith MC-21 FTMS evidence: mcdax/walkingpad-controller (opcode 0x02)
