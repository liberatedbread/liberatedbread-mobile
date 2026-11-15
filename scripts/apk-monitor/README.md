# APK Monitoring Agent

Automated pipeline that discovers new IoT Bluetooth APKs, reverse-engineers their protocols using multiple AI models, and merges the best results.

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌───────────────────────────────┐
│  APK Search │────▶│  BT Scanner  │────▶│      RE Agent Launcher        │
│  (APKPure)  │     │ (jadx/grep)  │     │  ┌───────┐ ┌──────┐ ┌─────┐ │
└─────────────┘     └──────────────┘     │  │Claude │ │OpenAI│ │QWEN │ │
                                          │  └───┬───┘ └──┬───┘ └──┬──┘ │
                                          └──────┼────────┼────────┼────┘
                                                 │        │        │
                                          ┌──────▼────────▼────────▼────┐
                                          │     Cross-Check & Vote      │
                                          │  (each reviews the others)  │
                                          └─────────────┬───────────────┘
                                                        │
                                          ┌─────────────▼───────────────┐
                                          │     Auto-Merge Winner       │
                                          │ (if score ≥ 5.0, votes ≥ 2)│
                                          └─────────────────────────────┘
```

## Setup

1. **Install dependencies:**
   ```bash
   pip install anthropic openai   # optional: falls back to curl
   ```

2. **Install RE tools:**
   ```bash
   # apkeep (APK downloader)
   cargo install apkeep
   # jadx (APK decompiler)
   # apktool (APK resource decoder)
   ```

3. **Configure:**
   ```bash
   cp config.env.example config.env
   # Edit config.env with your API keys and paths
   ```

4. **Set up local QWEN model (optional):**
   ```bash
   # Using ollama:
   ollama pull qwen2.5-coder:32b
   # Or use vllm, llama.cpp, etc. — any OpenAI-compatible endpoint works
   ```

5. **Set up transcripts repo:**
   ```bash
   mkdir -p /path/to/re-transcripts
   cd /path/to/re-transcripts && git init
   # Update TRANSCRIPTS_REPO in config.env
   ```

## Usage

```bash
# Full pipeline (discover → scan → RE → vote → merge)
./run_monitor.sh

# Discovery + BT scan only (no API calls)
./run_monitor.sh --scan-only

# Run RE agents on a specific existing target
./run_monitor.sh --target pax-vape

# Run voting on existing candidate specs
./run_monitor.sh --vote pax-vape

# Verbose output
./run_monitor.sh -v
```

## Cron Setup

```bash
# Install the example crontab (runs daily at 3am)
crontab -e
# Add: 0 3 * * * /path/to/scripts/apk-monitor/run_monitor.sh
```

See `crontab.example` for more options.

## How It Works

### 1. APK Discovery (`apk_discovery.py`)
- Searches APKPure for IoT/Bluetooth-related keywords
- Filters out already-known packages (from `targets/targets.csv`)
- Tracks seen packages in `workspace/apk-monitor/seen_packages.json`
- Downloads new APKs via `apkeep`

### 2. Bluetooth Scanning (`bt_scanner.py`)
- Decompiles APKs with jadx (preferred) or apktool
- Greps for BLE patterns: GATT, permissions, UUIDs, scan APIs
- Scores each APK with a confidence metric (0.0–1.0)
- Extracts custom (non-SIG) UUIDs for the RE agents

### 3. RE Agent Launcher (`re_agents.py`)
- Launches three parallel reverse-engineering agents:
  - **Claude** (Anthropic API) — best at structured analysis
  - **OpenAI** (GPT-4o) — good at broad pattern recognition
  - **Local QWEN** (via ollama/vllm) — runs locally, future fine-tuning target
- Each agent receives the same context: scan results, UUIDs, protocol hints
- Each produces a YAML device spec + Markdown protocol doc
- Transcripts saved to the configured transcripts repo

### 4. Cross-Check & Vote (`merge_voter.py`)
- Each agent reviews the other agents' specs
- Scores on completeness, accuracy, usefulness, clean-room compliance
- Winner = highest average score across reviewers
- Auto-merges if: score ≥ 5.0 AND votes ≥ 2

### 5. Auto-Merge
- Winning spec copied to `device-specs/devices/<target>.yaml`
- Protocol doc copied to `docs/devices/<target>.md`
- New target appended to `targets/targets.csv`
- Committed on a `re-merged/<target>/<date>` branch

## Directory Layout

```
scripts/apk-monitor/
├── __init__.py           # Package marker
├── config.env.example    # Configuration template
├── crontab.example       # Example cron entries
├── run_monitor.sh        # Shell entry point (cron-friendly)
├── monitor.py            # Main orchestrator
├── apk_discovery.py      # APK search + download
├── bt_scanner.py         # Bluetooth pattern detection
├── re_agents.py          # Multi-model RE agent launcher
├── merge_voter.py        # Cross-check voting + auto-merge
└── README.md             # This file
```

## Output Locations

| Artifact | Path |
|----------|------|
| Downloaded APKs | `workspace/apks/monitor/` |
| Scan results | `workspace/apk-monitor/scans/<pkg>/` |
| Seen packages state | `workspace/apk-monitor/seen_packages.json` |
| Run logs | `workspace/apk-monitor/runs/` |
| Candidate specs | `device-specs/candidates/<target>_<agent>.yaml` |
| Candidate docs | `docs/devices/candidates/<target>_<agent>.md` |
| Merged specs | `device-specs/devices/<target>.yaml` |
| Merged docs | `docs/devices/<target>.md` |
| Vote decisions | `workspace/apk-monitor/decisions/<target>.json` |
| RE transcripts | `$TRANSCRIPTS_REPO/<target>/<agent>/<timestamp>_transcript.md` |

## Future Work

- Fine-tune the QWEN model on successful RE transcripts
- Add dynamic analysis (HCI snoop capture + packet parsing)
- Integrate with the OpenGreenIoT mobile app for live testing
- Add Slack/email notifications for new discoveries
- Support split APKs (.apks, .xapk)
