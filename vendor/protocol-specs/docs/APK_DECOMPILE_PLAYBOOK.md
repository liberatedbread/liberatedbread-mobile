# APK decompile playbook (one target at a time)

Use this when you do **not** have the physical device.

> **Canonical artifact location:** `~/research/<device-dir>/` is the one true home for all
> downloaded APKs, decompiled output, hashes, and raw research notes. Nothing from
> `~/research/` is ever committed to the repo. See [Research directory convention](#research-directory-convention).

## Goal

Produce a clean-room, derived protocol lead sheet for a single target from APK static analysis,
following the rules in [`docs/CLEANROOM_RULES.md`](CLEANROOM_RULES.md).

---

## 1. Download methods — ranked by reliability

These are the results of real APK hunts against 10+ targets. The ranking is from hard-won
experience, not guesswork.

### Tier 1: apkeep via Google Play (gold standard)

```bash
apkeep -a <package_id> .
```

Requires `APKEEP_EMAIL` and `APKEEP_AAS_TOKEN` env vars. This is the only source that delivers a
signed, unmodified APK straight from Google's servers. It worked for `com.gyde.thermogauge` (Gerbing)
when all five web mirror attempts failed.

**Caveat:** app must still be published on Play. Gerbing was unpublished 2024-04-05; this worked
only because the APK was still cached server-side. For truly delisted apps this may fail.

### Tier 2: apkeep via APKPure API

```bash
apkeep -a <package_id> -d apk-pure .
```

This uses **APKPure's backend API**, not their website. Critically different from curl/wget on
apkpure.com — the API does not serve a Cloudflare JS challenge. Succeeded for:
- `de.wgsoft.motoscan` (MotoScan, 36.5 MB APK, verified vendor signature)
- `com.etekcity.vesyncplatform` (Etekcity scale, .xapk bundle)

**Caveat:** version lag. APKPure sometimes trails Play by weeks or months. Always check the
version against what Play advertises.

### Tier 3: apkeep via Huawei AppGallery (last resort)

```bash
apkeep -a <package_id> -d huawei-app-gallery .
```

Often has older versions — Huawei's store runs its own review/update cycle. Use when Tier 1 and
Tier 2 both fail. Accept the stale-version risk and note it in the evidence log.

### Tier 4: ADB pull from a device that has the app (when you have the device)

```bash
adb shell pm path <package_id>
adb pull <path>/base.apk ~/research/<device-dir>/<package_id>.apk
```

This is actually the most trustable source when available — it's the exact APK the vendor shipped
to a device. See [`scripts/pull_apks_adb.sh`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/scripts/pull_apks_adb.sh).

### ❌ Do not use: curl/wget on mirror websites

These **always fail** in practice. Every mirror site (APKCombo, APKPure website, AppBrain,
APKMirror) serves a Cloudflare JS challenge page instead of the actual APK. You get back a 200 OK
with an HTML body, not a ZIP. Confirmed on 5+ separate attempts across 3 different mirror domains.
This is not intermittent — it's by design, and it's universal.

If `apkeep` doesn't support a particular mirror, the mirror is effectively unreachable.

---

## 2. Xamarin / .NET APK handling

Many BLE accessory apps are built with **Xamarin.Forms** (Microsoft's cross-platform framework).
These apps store their real logic in `assemblies/*.dll` (compiled .NET assemblies), **not** in
`classes.dex`. jadx will happily decompile the Java bootstrap wrappers — but the UUIDs, service
logic, and protocol handlers live in the .NET DLLs, which jadx cannot touch.

### How to recognize a Xamarin APK

```bash
unzip -l app.apk | grep 'assemblies/'
```

If you see files like `assemblies/Core.dll`, `assemblies/<AppName>.dll`, and
`assemblies/Mono.Android.dll`, this is Xamarin.

### Extracting and analyzing .NET DLLs

```bash
# Extract the DLLs (never commit these)
mkdir -p ~/research/<device-dir>/decompiled/dotnet
cd ~/research/<device-dir>
unzip -o <apk-file> 'assemblies/*.dll' -d decompiled/dotnet/
```

**Quick scan for field/variable names** (works great for BLE service/characteristic names):

```bash
strings decompiled/dotnet/assemblies/Core.dll | grep -iE 'guid|uuid|service|char|device'
```

This will surface .NET string constants — names like `SERVICE_UUID`, `TX_CHARACTERISTIC_UUID`,
`RX_CHARACTERISTIC_UUID`, etc. In the Gerbing case (`com.gyde.thermogauge`), this found 10 UUID
field names immediately without needing the full decompiler.

**For actual UUID values:** .NET stores `System.Guid` as a binary struct (16 bytes in LE),
**not** as a string literal. `strings` won't find the raw UUID bytes because they're 128-bit
binary values, not ASCII text. You need a .NET decompiler:

```bash
# One-time install
dotnet tool install -g ilspycmd

# Decompile to readable C#
ilspycmd -d ~/research/<device-dir>/decompiled/dotnet-src/ \
    ~/research/<device-dir>/decompiled/dotnet/assemblies/Core.dll
```

Then grep the decompiled C# for UUID constants — `ilspycmd` renders `Guid` fields as
`new Guid("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")`.

**Alternative:** `strings` with `-e l` (little-endian 16-bit) may catch the UUID if the struct
happens to align on a word boundary, but this is unreliable. Use `ilspycmd`.

### Gerbing case study

- APK appeared to be a standard Java APK — jadx decompiled 24,000+ classes without complaint
- No UUIDs found in DEX output after exhaustive search
- Suspicion: app UI felt "platform-y" with Xamarin-style splash screens
- `unzip -l` confirmed `assemblies/Core.dll` and 6 other .NET DLLs
- `strings assemblies/Core.dll | grep -i uuid` found `SERVICE_UUID`, `TX_CHAR_UUID`, `RX_CHAR_UUID`,
  and 7 other field names — but zero actual UUID values
- `ilspycmd` on `Core.dll` resolved all 10 UUIDs to their canonical values
- Total time lost before checking for Xamarin: ~3 hours. Total time after: 20 minutes.

---

## 3. APK mirror failure patterns

All major APK mirror websites use the same Cloudflare anti-bot protection. The failure modes are
consistent and predictable:

| Mirror | Direct download result | API / alternative |
|--------|----------------------|-------------------|
| **APKCombo** | Cloudflare JS challenge page (HTML, 200 OK). The `/old-versions` page loads in browser but download links redirect to JS/HTML. | None. apkeep does not support apkcombo. Effectively unreachable. |
| **APKPure website** | CDN redirects (302) to a landing page. You get a few KB of HTML, not an APK. | `apkeep -d apk-pure` (API passthrough) — works. |
| **AppBrain** | Same Cloudflare HTML intercept. | None. |
| **APKMirror** | Cloudflare challenge, plus sometimes a human verification interstitial. | None from CLI. Browser + manual download may work if you have a session cookie. |

**The rule:** never use `curl` or `wget` against any APK mirror website. It looks like it works
(200 OK!) but you got an HTML page, not a binary. Use `apkeep`'s API-passthrough sources or pull
from a device.

---

## 4. Research directory convention

All downloaded artifacts live in `~/research/`, never inside the repo.

```
~/research/
├── gerbing-thermogauge/
│   ├── target.md              # Discovery plan (copy of targets/<id>.md, or original notes)
│   ├── com.gyde.thermogauge.apk
│   ├── SHA256SUMS.txt         # Hashes of every APK in this directory
│   └── decompiled/
│       ├── jadx/              # jadx output (Java)
│       └── dotnet/            # .NET assemblies + ilspycmd output (Xamarin targets)
├── etekcity-smart-scale/
│   ├── target.md
│   ├── SHA256SUMS.txt
│   ├── com.etekcity.vesyncplatform.xapk
│   ├── xapk_extract/          # Unpacked .xapk contents
│   └── decompiled/
│       └── jadx/
└── bmw-motorcycle-motoscan/
    ├── target.md
    ├── SHA256SUMS.txt
    └── decompiled/
        └── jadx/
```

Rules:

- **One directory per target**, named after the `target_id`
- **`target.md`** is the discovery plan (may start as a copy of `targets/<name>.md` from the repo,
  then accumulate raw notes during RE)
- **`SHA256SUMS.txt`** records the hash of every APK/XAPK in the directory — provenance matters
- **`decompiled/`** holds all decompiler output. Never committed to the repo per
  [`CLEANROOM_RULES.md`](CLEANROOM_RULES.md)
- **APKs and decompiled code are NEVER committed to the repo.** The repo only contains derived
  facts (UUIDs, opcodes, state machines)

---

## 5. Research-to-device-spec workflow

```
┌─────────────────────────────────────────────────────────────────┐
│  PHASE 1: DISCOVERY                                             │
│                                                                 │
│  ~/research/<device-dir>/target.md   ← discovery plan           │
│  ~/research/<device-dir>/*.apk       ← downloaded APKs          │
│  ~/research/<device-dir>/decompiled/ ← jadx / ilspycmd output   │
│  ~/research/<device-dir>/SHA256SUMS.txt                         │
│                                                                 │
│  Raw notes, half-formed UUIDs, failed experiments — all here.   │
│  This is your scratchpad. Nothing here touches the repo.        │
├─────────────────────────────────────────────────────────────────┤
│  PHASE 2: SPEC WRITING                                          │
│                                                                 │
│  device-specs/devices/<name>.yaml  ← machine-readable spec      │
│  docs/devices/<name>.md            ← human-readable docs        │
│  targets/<name>.md                 ← cleaned-up target notes    │
│                                                                 │
│  Write these in the protocol-specs repo, from derived facts     │
│  only. No vendor code, no decompiled sources — just the         │
│  protocol you inferred.                                         │
├─────────────────────────────────────────────────────────────────┤
│  PHASE 3: CLEANUP                                               │
│                                                                 │
│  When the spec is merged:                                       │
│    rm -rf ~/research/<device-dir>/decompiled/                   │
│    # Keep the APK + SHA256SUMS if provenance matters, or:       │
│    rm -rf ~/research/<device-dir>/                              │
│                                                                 │
│  The spec is the artifact of record. Research artifacts are     │
│  disposable once the spec is accepted.                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. Standard decompile steps (non-Xamarin)

For standard Java/Kotlin APKs (no `assemblies/` directory):

```bash
# 1. Download
apkeep -a <package_id> -d apk-pure ~/research/<device-dir>/

# 2. Hash
sha256sum ~/research/<device-dir>/*.apk > ~/research/<device-dir>/SHA256SUMS.txt

# 3. Decompile (uses jadx via scripts/run_static_target.sh)
#    This writes to workspace/static/<target_id>/ — keep it out of the repo.
./scripts/run_static_target.sh <target_id>

# 4. Read the summary
cat workspace/static/<target_id>/summary.md
```

For `.xapk` bundles (split APKs from APKPure), extract first:

```bash
unzip <file>.xapk -d ~/research/<device-dir>/xapk_extract/
# Then point jadx at the base APK or the entire extracted directory
```

---

## 7. What to extract (derived facts only)

Only these go into the repo — everything else stays in `~/research/`:

- **Transports used:** BLE, Wi-Fi, Classic Bluetooth, OBD-II/CAN
- **BLE service and characteristic UUIDs** (128-bit or 16-bit)
- **Characteristic properties:** read, write, notify, indicate
- **Probable endpoint domains / IPs** for Wi-Fi devices
- **Protocol framing:** opcodes, CRCs, chunk sizes, endianness
- **State machines:** connect → auth → command → disconnect
- **Encoding:** binary, ASCII, JSON, protobuf, etc.
- **Command tables:** write payloads mapped to functions

---

## 8. What to avoid

- **Do not commit APKs or decompiled vendor code** — see [`CLEANROOM_RULES.md`](CLEANROOM_RULES.md)
- **Do not copy vendor strings/UI content verbatim** beyond minimal fair-use paraphrase
- **Do not use `curl`/`wget` on mirror websites** — see [APK mirror failure patterns](#3-apk-mirror-failure-patterns)
- **Do not assume an APK is pure Java without checking for `assemblies/`** — see
  [Xamarin / .NET APK handling](#2-xamarin--net-apk-handling)
- **Do not ship UUIDs without values** — `strings` may find field names but not `System.Guid`
  struct values. Use `ilspycmd` for .NET targets.
- **Do not commit `~/research/` artifacts to the repo** — see
  [Research directory convention](#4-research-directory-convention)

---

## Currently hunting

See [`GAPS.md`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/GAPS.md) for the current list of targets that need device-spec YAMLs.
27 targets are in early research phase — pick one and run the playbook.
