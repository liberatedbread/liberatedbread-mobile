# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

No tagged release has been cut yet. Everything below is work toward the first
`0.1.0` release; once it ships, these entries move under a dated `## [0.1.0]`
heading.

### Security

- **Home Assistant token no longer leaks into logs.** A corrupt stored config
  was logged via `'$e'`, and `FormatException.toString()` quotes a window of
  its source — which here was the *decrypted* config, exposing 36 contiguous
  characters of the long-lived access token and the entire webhook id to
  logcat and terminals. Now only the exception type is logged; `redact()` /
  `redactAll()` / `logSafeUrl()` helpers and a redacting `HaConfig.toString()`
  make a repeat structurally hard.
- `run-remote-mac.sh` no longer interpolates `--remote-dir` unescaped into
  remote `ssh` commands (a quote in the path could execute arbitrary commands
  on the remote Mac).

### Changed

- **`./scripts/update-specs.sh` builds the spec index when the source cannot
  have a current one.** Upstream generates `device-specs/index.json` in CI and
  commits it after a spec merges, so a spec *branch* — or a local checkout with
  an uncommitted spec, which is how a spec and the app get written together —
  carries an index that predates the spec being tested. The app's loader is
  index-driven, so the device it names simply would not appear. The refresh now
  runs upstream's own generator over the specs it just vendored whenever the
  source is a local checkout, and on demand for any source with
  `--rebuild-index` (`--no-rebuild-index` opts out). The rebuild is left
  uncommitted deliberately: committing it would make the next `git subtree
  pull` merge our generated index against upstream's, which is the conflict
  upstream moved the build into CI to end — so a later pull discards it before
  pulling, and rebuilds after. `--check` gained the matching pair: it tolerates
  that one file being dirty when it verifies byte-for-byte as generator output
  over the vendored specs, and it now fails when the index and the specs beside
  it name different sets, which is the same invariant
  `rust/tests/vendored_assets.rs` enforces but reported at refresh time with
  the command that fixes it. The rebuild and the verification want a python3
  with `pyyaml` + `jsonschema` (`PYTHON=` overrides the interpreter); nothing
  else in this repo does, and a clean vendored tree never asks for them
- **An Airthings dashboard now shows every sensor the unit has, wherever the
  firmware puts it.** Refreshed vendored protocol-specs: temperature and
  humidity gain bindings on each Wave model's combined packet — the source
  the vendor app itself reads, and the only one verified against live
  traffic — ordered ahead of the SIG environmental-sensing characteristics,
  which are app-derived and unobserved in capture. A Wave whose firmware
  never exposes 2A6E/2A6F used to show radon and battery and nothing else;
  its temperature and humidity tiles now come from the same packet its radon
  already did. Also newly on the grid: Ambient Light on Wave Gen 2, Plus and
  Mini (raw 0–255 counts — deliberately no illuminance class, since counts
  are not lux; `mdi:brightness-5` joins the icon table for it) and Gen 1's
  dedicated 1-hour radon average beside the 24 h and long-term ones. No app
  code beyond the icon glyph: the tiles exist because the spec now declares
  the entities.

- **The BLE scan runs by itself, and keeps running.** Discovery was a button
  press with a 30-second window: whatever was advertising during those seconds
  was the answer, and a device powered on a minute later never appeared unless
  someone pressed Scan again. The Nearby tab now scans from the moment it opens
  until it is told to stop — `BleService.scan(timeout: null)` keeps the stream
  open — so a device that wakes up, is walked into the room, or is plugged in
  while the app is watching simply turns up.

  The scan asks the platform for `continuousUpdates`, which is what makes the
  rest of this possible: without it Android suppresses same-payload
  advertisements and Apple platforms coalesce duplicates, so a device is
  reported once and there is no way to tell "still here" from "switched off an
  hour ago". The coalescer only passes on a change or a five-second heartbeat,
  and the list repaints at most every 400ms — except for a newly-found device,
  which repaints at once.

  How hard the radio listens depends on whose idea the scan was
  (`ScanIntensity`). Everything the screen starts by itself — launch, a tab
  or lifecycle resume, the radio coming back — runs *ambient*: Android's
  balanced scan mode, which duty-cycles the radio to roughly a quarter and is
  the single biggest energy saving the scan has. Pressing Scan (or a Retry)
  buys an *active* burst: thirty seconds of continuous low-latency listening
  — someone hunting for a device right now should not wait on a duty cycle —
  after which the scan seamlessly downshifts to ambient, because a mode that
  one tap re-pins for the whole session would hinge the energy story on
  nobody pressing the tab's most prominent button. The advertisement divisor
  (2, to halve platform-channel traffic) now applies only to active scans:
  balanced has already thinned receptions at the radio, and stacking the two
  would double a sleepy sensor's reception gaps. Apple platforms expose no
  scan-mode knob, so there the intensity changes nothing and the cost stays
  bounded by the tab/lifecycle gating.

  A scan that never ends has to be careful about when it runs, so it does not:
  it pauses while the app is in the background (where the OS would not deliver
  results anyway) and while another tab is selected — `HomeShell` keeps all
  three alive in an IndexedStack, which is right for their state and wrong for
  their radios — and resumes on return with the list it built still there,
  aged accordingly. Resuming includes coming back out of the "Bluetooth is
  turned off" state someone has just left the app to fix. It also restarts the
  platform scan every 15 minutes, because Android silently converts a
  30-minute-old scan into an opportunistic one, and it notices the radio being
  switched off underneath it rather than sitting there claiming to search.

  Two more habits the session-long shape demands. Bluetooth switched back on
  resumes the scan by itself: on Android the radio is toggled from quick
  settings without the app ever losing focus, so no lifecycle event announces
  the fix, and the screen otherwise kept showing "Bluetooth is turned off" —
  with a Retry button — for a problem the user had already solved. A new
  `BleService.adapterReady()` stream carries the signal, and the resume runs
  through the same guard as every other automatic restart, so it never
  overrides a user's stop. And the off-tab stop waits two seconds before
  touching the radio: every return to the tab is a native scan start, Android
  blocks an app that starts more than five scans in thirty seconds, and a
  glance at the Saved tab should not spend one of them.

  The FAB now says what there is to do rather than what is happening. While a
  scan runs it is a small round stop button — the radar already reads as
  "scanning", and a full-width bar over the results would be shouting an offer
  nobody came for — with "saves battery" in its tooltip, since that is the
  reason to press it. Stopped, it is the wide "Scan" button again, because
  then nothing is happening and the way back has to be obvious. A scan stopped
  from it stays stopped: not through a tab switch, a backgrounding, or a trip
  into a device screen.

- **The scan list holds still enough to tap.** Rows were ordered on the raw
  dBm, which a continuous scan updates several times a second — and a reading
  wanders a few dB while nothing physically moves, so neighbouring rows traded
  places continuously and the row under a finger could change between deciding
  to tap and tapping. Ordering is now by the same four-step band the signal
  meter draws — one `signalBars` behind the meter, the ordering, and the
  "Strong/Good/Fair/Weak signal" caption, which previously carried its own
  thresholds and could say "Good" over two bars — then by which device was
  found first. Both keys are things that do not move, so a row changes
  position only when the device genuinely does.

- **Every dead-end on the device screen offers "Try to find device".** The
  hot/cold locator was only reachable from the connected header — but a
  FAILED or LOST connection is when "where is this thing?" is the actual
  question, since it usually means out of range or powered off. The
  connection-failed and disconnected states now carry a quieter second
  button under their Retry/Reconnect: it re-attempts the connect (the
  locator pings the live link's RSSI, so finding is connect-first — hence
  "try") and lands straight in the find screen when the link comes up. A
  failed attempt returns to the error state, which is itself an answer to
  "is it near me", and a later plain Retry does not surprise-open the
  locator.

- **Devices that have gone quiet are flagged instead of quietly disappearing.**
  A row used to be dropped after sitting out two scan windows, which meant a
  device that had been unplugged looked exactly like one that had never been
  found — the row was simply gone. Every device now carries `lastSeen` (the
  advertisement's own timestamp, so a silent device is not refreshed by a
  neighbour's traffic), and silence is read in two stages: past 90 seconds the
  row gets a warning glyph, says how long it has been quiet, drops its signal
  meter — that reading is a memory, not a measurement — and sinks below the
  devices still being heard; past five minutes it is dropped, since by then a
  tap on it can only end in a connect timeout. Ninety seconds rather than the
  forty this branch first shipped, because the ambient scan's duty cycle
  lengthens honest reception gaps: a sleepy sensor advertising every 10s is
  caught on average once per ~40s under a quarter duty cycle, and a threshold
  sized for continuous listening would flicker warnings over devices that are
  quietly fine.

- **Image upload is a generic pipeline now, not a SmartDawn one.** Seven
  devices in the catalogue declare an `image_upload` feature across six
  handlers and five pixel formats, and the app drove one — with the pipeline
  and the algorithms in a single file, so the sixth device would have meant a
  sixth copy of the pipeline. `protocol/image_upload.rs` is the shared part:
  resolve the command and bulk channels, open the session, encode the canvas,
  fragment, write. Everything it needs is data a spec already states.
  `daniao.rs` keeps what genuinely cannot be YAML — the palette+RLE pixel
  codec and the `daniao_fragment` header — and drops from 487 non-test lines
  to 286, all of it algorithm.

  The line is deliberate: a spec *names* an algorithm and the pipeline runs
  it, exactly as `protocol_handler` and `framing.scheme` already work.
  Expressing a pixel codec in YAML would mean inventing a bytecode —
  untypeable, untestable, and it would make a downloadable spec pack
  executable. So adding a display is: write the spec, and add a codec only if
  its pixel encoding is genuinely new. Proved rather than asserted — a test
  runs the pipeline on a made-up device with a different framing scheme, a
  different codec, different UUIDs and a different opener, none of which
  SmartDawn shares.

  One behaviour change fell out: the canvas ceiling is the spec's
  `max_width`/`max_height` now, where the old code hardcoded 256. SmartDawn
  declares 255 (it reports resolution in u8 advertisement fields), so a
  256-wide canvas is correctly refused where it used to be accepted. The
  codec's own u8 chunk coordinates still cap at 256, and the tighter of the
  two binds.
- **A command whose bytes this app cannot produce no longer offers a Send.**
  Two specs this branch made parseable exposed the same gap from opposite
  sides, and both were newly reachable precisely because the specs now load.
  `CommandDto.is_encodable` consulted only the command, so a characteristic
  declaring a `framing` or `encryption` transform this crate does not execute
  still had every command on it listed as sendable — seeblue's templates are
  the packet, with the SEEBlue envelope belonging to the characteristic, so a
  raw write reached the device as a packet it will not answer. And a template
  referencing a `bytes` parameter was reported encodable although the FFI
  carries parameters as `f64` and the encoder has no representation for raw
  octets, so Fardriver's `write_parameter` enabled a Send that failed on every
  press. Both now report themselves unsupported, naming the framing scheme or
  the parameter, and the same gate runs in the encoder — the single source of
  truth the codebase already claimed but only applied to the entity path.
- **The SmartDawn upload flow is driven by the spec, not by constants beside
  it.** The handler already resolved its two channels from the spec's `framing`
  blocks and built its session-open packets from the spec's command templates,
  so message types and field encodings were the spec's to change. Three things
  were not: which commands open a session and in what order, which buffer tag
  the flow writes under on the bulk channel, and where the vendor encoder
  flushes a chunk. Those describe SmartDawn's upload rather than the fragment
  scheme, so a sibling device on the same platform with a different opener
  needed a code change. They now come from the feature's `session_open` and
  `channel_tag` and the bulk channel's `framing.max_chunk_size`, with the old
  constants kept as the fallback for a spec pack written before those keys
  existed. Four tests change one declaration each and assert the bytes move
  with it — without those, every value the handler reads is also the value it
  used to hardcode, so a test against the shipped spec would pass either way.
- **Two vendored specs that failed to parse now load**, upstream: 36 commands
  and a 500-line register map that reached nobody. `seeblue-motorcycle-led`
  spelled its transport envelope into nine command templates as placeholders
  no command declared, and `fardriver-controller` bounded a `bytes` parameter
  with `min`/`max`, which mean a numeric range a run of octets does not have.
  The `KNOWN_BAD` allowlist in `rust/tests/vendored_assets.rs` is empty as a
  result — kept, because upstream now enforces both rules, so a spec should
  not arrive broken that way again.
- **Four spec keys the app was ignoring now drive it, and one it was carrying
  is gone.** Each had real information in the catalogue reaching nothing.
  - **`endianness` on `format:` fields.** The decoder hardcoded little-endian.
    Six fields across `xiaomi-miflora` and `pax-vape` declared byte order, all
    saying `little`, into a key the BLE schema did not define — so nothing
    decoded wrong and nothing would have said so if it had. The schema
    declares it now (same enum and default as the bus fields it mirrors) and
    the decoder consults it. A byte-swapped reading is not visibly broken, it
    is a different plausible number: a big-endian `0x0100` reads as 1 rather
    than 256.
  - **`entity.icon`.** The cards derived every icon from `device_class`, which
    has nothing to say about `gerbing-thermogauge`'s heat levels — `number`
    entities with no class that means "this warms you up". The spec's `icon`
    now wins, translated from its MDI name into the Material glyph this app
    can draw (`lib/core/entity_icon.dart`); `device_class` remains the answer
    for the entities that do not state one, so nothing regresses and an
    unmapped name degrades to exactly the old behaviour.
  - **`entity.precision`.** Display rounding, which is a different question
    from the transform's implied decimal places: the transform says how finely
    the value was *encoded*, `precision` how finely the device actually knows
    it. Presentation only — controls still seed from the unrounded number, so
    a slider cannot write its own rounding back to the device.
  - **`locate` on a command** (new upstream). The Find view classified alert
    commands by matching their names against six token sets, four of which
    existed only to take matches back: across the 350 BLE commands in the
    catalogue, `play_effect`, `set_mode`, `identify` and `set_volume_low` all
    read as locators and none is one, while `flash_firmware` reads as one and
    must never be one tap away. A command can now say what it is, and two do.
    The name heuristic stays as the fallback for spec packs that have not
    caught up, and the danger-token veto applies to declared locators too — a
    third-party pack is not obliged to have run the schema.
  - **`parameters.color_order` is gone.** It declared RGB channel order beside
    a `template` that already emitted the channels in an order, with nothing
    saying which won if they disagreed. It never crossed the FFI, all eight
    uses said `rgb`, and every one sat next to a template already naming
    `{red}`/`{green}`/`{blue}` in that order. The parser still absorbs the key
    so a spec pack written against the older schema loads rather than failing
    whole.
- **`assets/` is gone; everything ships from the vendored subtree.** Both the
  device specs and the number registries were duplicated — 1.2MB and 1.7MB of
  byte-identical copies of `vendor/protocol-specs/`, made by
  `scripts/sync_device_specs.sh` and committed alongside their originals. Two
  copies of the same data with nothing checking they agree is a bug waiting for
  someone to edit the wrong one.

  `pubspec.yaml` now bundles the subtree paths directly, and the loader reads
  upstream's own `index.json` instead of a rewritten `manifest.json`. Refreshing
  the catalogue becomes `git subtree pull` and nothing else, so
  `sync_device_specs.sh` is deleted rather than kept as a step people can forget.

  Not symlinks: a Windows checkout without developer mode or `core.symlinks`
  writes a text file containing a path, and Flutter's asset pipeline treats
  symlinks inconsistently across platforms. Both failures are silent — an empty
  catalogue, no error — where a wrong path is a loud missing asset.

  **Remote spec packs are unaffected**, and now have tests saying so: bundled
  specs are keyed by subtree asset path and remote ones by `pack:<name>/<file>`,
  and the two namespaces are pinned as non-overlapping so neither half can
  shadow the other in the merged catalogue.
- **`scripts/update-specs.sh` gained a `--check` mode, and CI runs it.** The
  script wraps stock `git subtree pull --squash` — that has not changed, and
  doing the subtree commands by hand still works — but its checking half was
  only ever reachable by doing a pull, so nothing verified the vendored tree on
  an ordinary commit. `--check` is that half alone: no network, no pull, works
  on a shallow clone.

  It also checks something new. The subtree is vendored *unmodified*, and an
  edit made to `vendor/protocol-specs/` here instead of upstream reads as an
  ordinary spec change in review, then silently reverts at the next refresh.
  `--check` compares the vendored tree's hash against the squash commit's —
  a squash commit's tree *is* the subtree's content — so it catches every way
  the prefix can drift, including the two that no walk over commits can see: a
  conflict resolved by editing the spec (recorded in the merge commit itself)
  and a local edit that auto-merges cleanly during a pull (recorded before it).
  Uncommitted and untracked files under the prefix count too; Flutter bundles
  an unstaged YAML in `device-specs/devices/` exactly like a real one. This is
  why the `analyze` job now checks out full history.

  The bundled-path assertions are read out of `pubspec.yaml` rather than
  repeated in the script. The old hardcoded list covered whatever was true the
  day it was written: a registry added to `assets:` afterwards shipped in the
  app and was checked by nobody.

  The pull path picked up the three things that made its failures cryptic: a
  preflight for git-subtree not being installed (it is contrib, and Apple's git
  omits it) rather than `git: 'subtree' is not a git command`; a pre-fetch of
  the recorded upstream commit, which git 2.42+ does itself but older git dies
  on; and triage for upstream having rewritten history away from that commit,
  which now prints the `git subtree add` re-baseline instead of `fatal: could
  not rev-parse split hash`.
- **iOS deployment target 12.0 → 13.0.** Flutter 3.44 no longer supports an
  iOS 12 target. The Podfile now pins the platform explicitly rather than
  leaving it commented out, so CocoaPods and the Xcode project cannot drift
  apart. Flutter 3.44 also stopped building 32-bit x86 for Android, so the APK
  ABI assertions no longer name it.

### Fixed

- **`MockNetworkScanService.stopScan()` did not stop the scan.** The same bug
  that was fixed in `RealNetworkScanService`, still present in the mock: the
  stop flag was read only at the top of the enumeration loop, so a stop during
  a sleep still yielded the device that sleep was waiting for, and the sleep
  *after* the loop never read it at all — the stream stayed open for a quarter
  of the scan window (two seconds at the default) after the scan was told to
  stop, so a UI that re-enables its button on stream close sat there saying
  "scanning". Every wait now races the stop, as the real service's does. This
  is the class that runs in demo mode and in every mock-mode integration suite,
  and it had 0 of 17 lines covered, which is how it survived the first fix.

- **The `network-discovery` job's coverage was collected nowhere.** The job that
  uploads coverage is the one that excludes the netdisco suites, so
  `lib/services/real_network_scan_service.dart` reported 108/169 lines while
  that job was covering 164/169 of it. Fifty-six lines on the service with the
  most elaborate harness in the repo counted as untested, a change to it looked
  like it was adding uncovered code, and improving those tests moved the number
  not at all. The job now writes `coverage/netdisco-lcov.info` and uploads it
  under a `netdisco` flag; Codecov merges the two reports.

- **`scripts/test.sh` ran `flutter test` without the environment it thought it
  was setting.** The two `LD_LIBRARY_PATH`/`DYLD_FALLBACK_LIBRARY_PATH`
  assignments ended in a line continuation that ran into a *comment*, so bash
  read them as a command of their own — setting a pair of shell variables
  nothing exported — and then ran `flutter test` unprefixed. The suites passed
  regardless, which is the tell: `test/helpers/host_rust_lib.dart` opens the
  library by relative path precisely because macOS strips `DYLD_*`. Both
  variables are gone rather than repaired; neither was ever what made it work.

- **Discovered GATT UUIDs were written in a form no spec could match.**
  `discoverServices` rendered each UUID with `Guid.toString()`, which is
  `Guid.str` — and that abbreviates a Bluetooth-base UUID to its 16-bit short
  form, so the example bulb's control service came back as `fff0`. Specs always
  write UUIDs out in full, so on real hardware every standard-base service UUID
  handed to the matcher was one that could not match the spec describing it,
  and the device fell back to raw GATT controls for no visible reason. Both
  `discoverServices` and the characteristic lookup now use `str128`, matching
  what the scan path already did and putting the whole app in one UUID
  vocabulary. (Mock mode emits 128-bit UUIDs, which is why nothing in CI ever
  caught it.)

- **iOS could never have discovered a Wi-Fi device.** Since iOS 14 an app may
  not touch a multicast address over a raw socket without
  `com.apple.developer.networking.multicast`, and there was no entitlements
  file in `ios/` at all. `NSBonjourServices` does not substitute for it: that
  key covers mDNS done through the Bonjour APIs, where `mDNSResponder`
  multicasts on the app's behalf, and this app uses neither — `multicast_dns`
  binds UDP 5353 and joins 224.0.0.251 itself, and the SSDP half sends
  M-SEARCH to 239.255.255.250 from its own socket. Both were blocked.

  Nothing said so. The sockets bound, the queries went out, the OS dropped
  them, and `scanFailureFor()` read the silence exactly as designed and told
  the user their Local Network permission might be off — pointing at a toggle
  that was already on.

  `ios/Runner/Runner.entitlements` now declares it and all three app build
  configurations reference it. Apple grants this entitlement by manual request
  rather than a checkbox, so signed device builds fail at signing until the
  request is approved and the provisioning profile reissued;
  `docs/ios-from-linux.md` covers what to file and what breaks meanwhile.
  Simulator builds, including all of CI, are unaffected — they do not sign.

- **macOS release builds lost half the Wi-Fi scan.**
  `com.apple.security.network.server` was in `DebugProfile.entitlements` but
  not `Release.entitlements`, on the reading that it belonged to the Dart VM
  service. Under the App Sandbox it is also what permits binding a listening
  socket, which is what `multicast_dns` does to join 224.0.0.251 on port 5353.
  So mDNS worked in `flutter run -d macos` and threw in a release build, which
  then discovered only what SSDP happened to find. The macOS local-network
  usage string also described only Home Assistant, though the prompt now
  fires when a user taps Scan.

- **A `--` inside an XML comment broke the Android manifest.** XML forbids it —
  it is the first half of the comment terminator — and the manifest merger fails
  the whole build with "Error parsing AndroidManifest.xml" and no line number.
  Every existing platform test passed, because the hand-rolled comment stripper
  in `test/platform/platform_config_reader.dart` just scans to the next `-->`.
  `test/platform/xml_wellformedness_test.dart` now closes that gap for the
  manifest, both plists and both entitlements files.

### Added

- **The Linux desktop build has an app icon.** It was the one platform without
  one: iOS, macOS, Android and web all carried the mascot, and the GTK build
  shipped whatever generic placeholder the desktop supplies — so a running
  window was unidentifiable in a taskbar or an alt-tab switcher.
  `tool/branding/generate_icons.mjs` now emits seven flattened sizes (16–256,
  the freedesktop hicolor set) to `linux/resources/`, `linux/CMakeLists.txt`
  copies them into the bundle at `data/resources/`, and
  `linux/my_application.cc` loads them and sets the default window icon list at
  startup, before any window exists. All seven ship rather than one large one
  because a desktop picks per surface, and given only a 256 the compositor
  downscales it into the muddy taskbar icon this exists to avoid.

  The icons are loaded from the bundle rather than looked up by name through
  the icon theme, which is the GTK-idiomatic call: a theme lookup only resolves
  for an *installed* app, and this one normally runs straight out of
  `build/linux/x64/<mode>/bundle`. `scripts/verify_linux_bundle.sh` asserts each
  size arrives, since a bundle missing them builds green, starts fine, and is
  wrong only somewhere CI never looks.

  A native **Wayland** session needs one more piece, and cannot use the above:
  the protocol has no per-window icons, so the compositor matches the surface's
  `app_id` to an installed `.desktop` file instead. `linux/main.cc` therefore
  sets the process name to `APPLICATION_ID` (`ca.pigscanfly.liberatedbread`,
  which also fixes the X11 `WM_CLASS`), and the new
  `scripts/install-linux-desktop-entry.sh` installs a matching entry and the
  hicolor icons under `~/.local/share` — no root, nothing outside `$HOME`, and
  `--uninstall` to undo. It is deliberately not run by the build or by
  `run-linux.sh`: writing into a developer's desktop environment is not
  something a build should do unasked.

- **Rabbit Air purifiers (full local control over Wi-Fi).** The fourth
  network transport, after SOAP (Wemo), plain HTTP (Roku) and Kasa: the
  Rabbit Air LAN protocol is an encrypted JSON envelope — `{id, cmd, ts,
  data}` — over UDP datagrams on port 9009, AES-128-CBC under a per-device
  16-byte user key with a random IV appended to each datagram. The crypto,
  the envelope renderer and the device-clock handshake (cmd 9 `time_sync`,
  then timestamps extrapolated from the learned offset) live in the Rust core
  (`rust/src/protocol/rabbit_air.rs`, pinned against the spec's documented
  example exchange); `RabbitAirControlClient` owns the UDP socket, the
  vendor's 3-attempts/2 s retry discipline and reply matching on the echoed
  request id. The spec's whole surface renders through the existing entity
  cards: a Power switch, an Auto/Pollen/Manual mode select, a 1–5 fan-speed
  number, air-quality / filter-life / Wi-Fi-RSSI sensors, and Ionizer and
  Child Lock switches. Because the wire is encrypted, the first visit to the
  device screen asks for the 32-character user key (the vendor app reveals it
  under device page → Rename → tap the device name), validated as hex and
  stored per Thing ID in the platform keychain
  (`RabbitAirKeyStore`, the Hue credential store's precedent). Discovery
  needed nothing new: the generic mDNS enumeration already finds
  `_rabbitair._udp.local`. The tokenless plaintext mode and the TCP 9009
  variant the vendor library also documents are deliberately not implemented.
- **TP-Link Kasa smart plugs (on/off control over Wi-Fi).** The third network
  transport, after SOAP (Wemo) and plain HTTP (Roku): the Kasa local protocol
  is JSON over a raw TCP socket on port 9999, obfuscated by a trivial XOR-
  autokey cipher with 4-byte length framing. The cipher and framing live in the
  Rust core (`rust/src/protocol/kasa.rs`, under test against the canonical
  softScheck / python-kasa byte vectors); `KasaControlClient` opens the socket
  and moves bytes, and Dart's `dart:convert` flattens the `get_sysinfo` reply
  into the name→value pairs the existing entity decoder reads (as the SOAP
  client does for XML). The outlet renders as an on/off switch whose state polls
  `relay_state` — the same control shape as the Wemo plug. Discovery is a
  UDP-broadcast of the encoded `get_sysinfo` to `255.255.255.255:9999` folded
  into the Wi-Fi scan, and because Kasa devices advertise neither mDNS nor SSDP,
  the network matcher gained an honest new axis: a spec's `lan_protocols` are
  matched against the vendor protocols a device actually *answered*, a strong
  identifier where a bare open port is none. Power strips (per-outlet
  addressing) and energy metering are noted as follow-ups.
- **Sensor devices read as dashboards, not as GATT dumps.** Three changes
  that land together on anything the catalogue classes as a sensor — an
  Airthings Wave, a SensorPush, a Miflora:
  - *A readings grid.* Two or more numeric readings render as compact tiles,
    two or three abreast, instead of a scroll of full-width banners — an
    Airthings Wave Plus's radon, CO₂, VOC, temperature, humidity, pressure
    and battery are one glance now. A lone reading keeps the roomier row,
    and binary sensors keep their full-width on/off presentation.
  - *Verdict chips.* Readings whose healthy range is established carry a
    colored Good/Fair/Poor chip beside the value, because "934 ppm" answers
    a question nobody asked. Bands and their sources live in
    `core/sensor_reading_level.dart`: radon 100/150 Bq/m³ (WHO reference
    level / Airthings' own shipped defaults), CO₂ 800/1000 ppm and VOC
    250/2000 ppb (Airthings defaults), humidity 25/30/60/70 %, PM2.5 10/25
    and PM10 20/50 µg/m³ (around the WHO 2021 guidelines), battery 20/10 %.
    Quantities with no honest band — temperature, pressure — show the
    number alone, and a healthy battery keeps quiet rather than fishing for
    praise. Chips are keyed on device_class *plus unit* so a band can never
    judge a value in a unit it does not hold in, and radon is keyed on its
    unit alone — older catalogue copies mislabeled it as a VOC class, and
    Bq/m³ must never be read against a ppb band.
  - *Folded plumbing.* When a matched sensor device has readings on screen,
    the raw service cards start folded — the first screen is radon and CO₂,
    not the OAD firmware-update service. Still one tap away, and every
    other device category keeps expanded cards. Folding hides the
    characteristic widgets without disposing them (`maintainState`): their
    teardown answers with `setNotifyValue(false)` on the peripheral, with
    no reference counting, which would mute the very characteristics the
    readings above are showing live.

  With them, one logical reading declared once per variant binding (the
  shape the Airthings family spec now uses) renders once instead of once
  per binding, air-quality entities get real glyphs (radon, CO₂, VOC,
  particulates, dew point, illuminance) instead of the generic sensor dot,
  and the mock simulator demos a healthy home — it now inverts
  `value_offset` as well as `scale` (the Wave Mini's centikelvin
  temperature decoded to −251 °C before), picks sea-level pressure in
  whichever unit the spec declares, and defaults radon/CO₂/VOC to values a
  house would actually show.

- **The core can drive a device that has no GATT at all.** Everything the app
  controls today is BLE: an entity binds a characteristic, a role resolves to
  a command on it, and the command becomes bytes. A Wemo plug has none of
  that. `protocol/soap.rs` is the same job one transport over — a spec command
  becomes an HTTP request, a returned value becomes an entity reading — and
  `spec/bindings.rs` gains the network sibling of the role resolution, using
  the same role names on purpose: two tables that disagreed about what
  `switch` offers would give one device different controls depending on how it
  happened to connect.

  Deliberately no I/O. This crate has no HTTP client and wants none: it
  renders the request and reads the reply back from name→value pairs, exactly
  as the BLE path hands back the bytes somebody else read. What lives here is
  what a transport cannot work out for itself — parameter defaulting, argument
  substitution, XML escaping, and the read-back rule below.

  Two device facts drove the design, both from the Crock-Pot, and both
  invisible until you write the consumer:

  - **A heat-level picker is a `select`, and nothing here spoke that role.**
    The cooker's modes are `0`/`50`/`51`/`52` — a choice from a list, not a
    number anybody can slide between. `select_option` resolves now, with the
    option table read the way `ember-mug` already writes one, and an
    unrecognised value reads as *unknown* rather than folding into the first
    entry, which on this device would say "off" while the thing is heating.
  - **`SetCrockpotState` carries mode and cook time together.** Change one
    without sending the other back and you have cleared the timer. A resolved
    action now surfaces `read_back` — the parameters whose real value the
    client must fetch first — because it changes what the caller has to *do*,
    and a control that does not know cannot be written correctly by accident.

  `tests/network_control.rs` drives the real catalogue file end to end: five
  entities resolve, the rendered requests are diffed against the bodies the
  spec publishes, and one published `GetCrockpotState` response drives all
  four cooker controls. It also pins the trap — the cooker's state comes from
  `mode`, never from `BinaryState`, which answers `0` whatever the device is
  doing.

  And the UI half, now wired end to end. Tapping a matched Wi-Fi device whose
  spec declares controls opens a control screen instead of the details sheet:
  a toggle for the plug; for the Crock-Pot a cook-mode picker, an editable
  cook-time card and a cooked-time reading — the app's first `select` control
  on any transport. `SoapControlClient` is the transport (fetch `setup.xml`,
  resolve control URLs from the device's own service list because published
  paths move across firmware generations, POST with the exact SOAPACTION
  header, parse the reply by the spec's envelope rule, and tell a SOAP Fault
  — the device refusing — apart from the network failing). The FRB surface
  carries four calls: list a device's controls (narrowed to the model by the
  SSDP targets it answered, so a plug never grows the cooker's picker),
  render a command, render a state read, decode a reading.

  Every write that carries a `read_back` re-reads the state it depends on
  immediately before sending — not from the last refresh, because the
  cooker's own countdown moves between refreshes and sending a stale time
  rewinds it. And the read-back is mandatory, not best-effort: review on the
  spec side killed the `default: 0` that used to back each `source`
  parameter, so a send whose read-back failed now errors visibly instead of
  quietly clearing the timer (or, on a cook-time change, stopping a running
  cooker with a substituted `mode: 0`). The resolver counts a `source`
  parameter as fillable — the client knows where to fetch it — and the
  renderer enforces that it actually was. The widget test pins exactly that: picking Warm on a cooker
  with four hours on the clock sends `mode=50, time=240`, and turning off
  sends no values at all. An unrecognised mode renders as
  "Unrecognized state", never as the first option — which would read "off"
  while the thing is heating.

- **A file no test imports can no longer hide from the coverage number.**
  `flutter test --coverage` instruments only what a test reaches, so an
  unreferenced library is absent from the report rather than reported as zero —
  and therefore absent from the denominator, which means adding an entirely
  untested file to `lib/` moved coverage by nothing at all.
  `scripts/ci-coverage-audit.sh` compares the tracked `lib/` files against the
  report and fails on anything missing, in the `unit-tests` job and in
  `scripts/test.sh`. Two abstract-only files are allowlisted with their
  reasons, and the allowlist is checked in both directions.

  `lib/main.dart` was the file living in that gap — the app's own entrypoint,
  executed by nothing. `test/main_test.dart` now covers it, including the
  documented contract that a failed `RustLib.init` is logged loudly and does
  not stop the app.

- **`RealSpecCodec`'s untested half.** Four of its methods —
  `matchNetworkDevice`, `identifyStandardProfiles`, `encodeEntityValue`,
  `encodeImageFrame` — had never been executed, because every widget test
  drives the fake instead. They are thin pass-throughs to generated FFI
  functions, which is exactly the code that looks too boring to test and then
  transposes two adjacent int arguments. 57.9% to 100%.

- **The Rust crate's coverage is measured.** Roughly a third of the
  hand-written code in this project — the spec parser, the codec, the protocol
  dispatch, the mock simulator — was tested and never counted, so the reported
  figure was the Dart half only and a change that moved Rust coverage moved the
  number not at all. A `rust-coverage` job runs `cargo llvm-cov` and uploads
  under a `rust` flag, which Codecov merges with the two Dart reports. The
  first measurement: **95.6%** on hand-written code.
  `rust/src/frb_generated.rs` is ignored, on the argument already made for
  `lib/src/rust/**` — 1917 generated lines that `cargo test` covers 0.0% of,
  because the crate's own tests never cross the FFI boundary that file exists
  to implement. Left in, it reports the same crate as 72.0%.

  The job is deliberately separate from `rust` and gates nothing: that one is
  what the four native jobs wait on, and it keeps a plain `cargo test`.

- **The FFI tests rebuild the Rust core themselves.** Both ways of getting this
  wrong were silent: with no host build the suites `markTestSkipped` and the run
  is green with a quietly smaller test count, and with a *stale* one they do not
  even skip — they load the `.so` from before the edit, pass, and report on code
  that no longer exists. `test/helpers/host_rust_lib.dart` now reads cargo's own
  dep-info file (every source that went into the artifact, `include_str!`d
  vendor registries included) and runs `cargo build` when any of them is newer,
  so `flutter test` after editing `rust/src/` tests the edit. A warm target
  directory means no cargo run at all. `LIBERATED_BREAD_NO_RUST_BUILD=1` opts
  out; an explicit `LIBERATED_BREAD_RUST_LIB` is never rebuilt.

- **`scripts/ensure-rust-lib.sh`**, the one definition of "the host Rust library
  is built" — used by `scripts/test.sh`, the Claude Code session hook and CI's
  `unit-tests` job, which each had their own spelling of it. It asserts the
  artifact rather than trusting cargo's exit code: dropping `cdylib` from
  `rust/Cargo.toml`'s `crate-type`, or renaming the package, builds green while
  removing the one file every FFI-backed test opens by path.

- **CI now enforces the pins and lockfiles it documents.**
  `./scripts/ci-versions.sh --strict` runs in the gate job, so renaming a key in
  `ci.yml`'s `env:` block fails the pull request that does it instead of quietly
  sending every dev machine back to a hardcoded fallback. `cargo --locked` and
  `flutter pub get --enforce-lockfile` stop CI from silently resolving around a
  lockfile that was not updated. `scripts/ci-shellcheck.sh` additionally checks
  each script is executable and declares an interpreter — a 644 script fails
  with `Permission denied` inside whichever job invokes it, which for the
  emulator suite is forty minutes in.

- **`.github/dependabot.yml`** for the ten actions the workflows pin by major
  tag, plus the Rust crate; grouped into one pull request per ecosystem per
  week. Pub is deliberately excluded — `pubspec.lock` is pinned against a
  specific Flutter SDK, so those bumps follow a Flutter bump, by hand.

- **`workflow_dispatch` on `ci.yml`**, so a run can be started by hand on a
  branch with no pull request open — the only way to see whether a toolchain
  bump survives the four native jobs was previously to open one.

- **Every scan row says what kind of device it is.** The scan list already
  ranked results and badged them — "Ember Mug", "Likely supported", "Possibly
  Xiaomi" — but every row was drawn with the same Bluetooth glyph, so the list
  read as one shape repeated down the screen with the differences in small
  text. Rows now carry a device-type icon: light, display, sensor, motor,
  switch, lock, TV, printer, hub, vehicle, scale, and so on.

  The class comes from `device.category` in the spec catalogue, which
  `SpecIdentityDto` and `ScanMatch` now carry alongside the manufacturer, so
  adding a device or correcting its class stays a data-only refresh with no
  app change. That field is defined and populated upstream in protocol-specs;
  everything here reads it and degrades to the generic glyph where a spec
  states none, so the icons light up on the next `./scripts/update-specs.sh`
  rather than needing this and the catalogue to land together.

  The icon only ever comes from a matched spec — never from a heuristic over
  the advertised name — so a row whose icon is not the tab's generic glyph is
  one the catalogue actually placed. That is the same rule the badge already
  follows, and it is why "LEDBlue-A1B2C3" is left anonymous despite reading
  like a light: a guess drawn in the same glyph as a real match is a claim
  with its evidence stripped off, and `DeviceDescription` already says the
  true version of that.

  A category survives a tie when every tied match agrees on one, which is a
  lower bar than `namesAProduct` on purpose: a shared OUI cannot say which of
  a vendor's ten lights this is, and can still say "light". Where the tied
  matches disagree — a Xiaomi OUI covering a plant sensor and a body scale —
  the icon drops back to the generic one, the same way `label` drops back to
  "Possibly supported" when the manufacturers disagree.

  The connected-device screen now names its automatically-matched spec and
  device type as well. A user-*chosen* spec already had its own banner; an
  automatic match had nothing, so the typed controls simply appeared and the
  user was left to infer what the app had decided.

- **The device screen says who made the thing, and shows its address.** The
  IEEE and SIG registries have been vendored and searched for a while, but the
  BLE detail screen never read them: it showed a name, a status dot and a
  service count, and the MAC only by accident, when a device had no name and
  the title fell back to `Unknown (<id>)`. It now carries the address and what
  the registries make of it, and the Wi-Fi details sheet gained the `MAC` row
  its existing `Address block` row was silently drawing its conclusion from.

  The two sources stay separate rows rather than collapsing into one
  "manufacturer" line, because they answer different questions: a company ID
  is something the device put in its own advertisement, while an address block
  names whoever bought the block — frequently the radio module's vendor, which
  is why the Lutron Caséta bridge resolves to Texas Instruments. Labelling
  them apart ("Advertises as" / "Address block") is what makes showing the
  registry safe at all. Nothing new looks anything up: this is
  `describeWith` + `DeviceDescription`, already used by the scan list.

  On Apple platforms both rows are simply absent — CoreBluetooth substitutes a
  per-host UUID for the hardware address, so there is no address to show and no
  block to look up, and printing the UUID under "Address" would invite exactly
  the lookup that cannot work.
- **`scripts/update-specs.sh`** — refreshing the vendored specs is a script
  now, not a remembered `git subtree pull`. It takes a ref, and `--from` takes
  any remote including a local checkout, so a spec change can be pulled from
  the branch it is still being written on. Afterwards it asserts that every
  path `pubspec.yaml` bundles actually arrived: a pull that drops
  `registries/ieee-oui36.tsv` fails nothing at build time, it just makes the
  app quietly stop naming vendors.
- **Bottom ad banner on the scan screen** — a small dismissible house-ad bar
  pointing at the new liberatedbread.com/shop/ affiliate page (dead devices
  cheap, WeMos boards, liberation gear). Content comes from
  `https://liberatedbread.com/app/banner.json` fetched in the background, so
  the promotion can change — or be switched off — without an app-store
  release; a bundled fallback (and a cache of the last fetched config) renders
  from the first frame, so a slow or absent network never blocks anything.
  Dismissal is remembered per promotion id.
- **Wi-Fi device discovery, as a destination of its own.** Half the catalogue is
  hardware with no Bluetooth at all — bridges, plugs, printers — and a BLE scan
  could never see any of it. The new Wi-Fi tab asks over both mDNS/DNS-SD and
  SSDP, because the two do not overlap: modern local-first devices announce over
  mDNS only, while Wemo and pre-2020 Hue bridges are SSDP-only, so running one
  would silently miss half the devices. Discovery is by the generic DNS-SD
  service enumeration rather than a fixed list, so it finds hardware whose spec
  nobody has written yet. A host answering on both transports is merged into one
  row carrying what each said. Tapping one shows everything it advertised.

  Matching reuses the same `MatchConfidence` core as the BLE path, so a badge
  means the same thing on either tab: an mDNS service type or an SSDP search
  target is a vendor-specific identifier and rates Strong, while a default port
  is the network's equivalent of an OUI — port 80 says nothing about who is
  listening — and only ever ranks. A spec that declares nothing about the
  network can never match a host on it, so a BLE spec whose name prefix happens
  to prefix an mDNS instance name stays off this tab.

  Platform notes: iOS will not deliver mDNS answers for a service type absent
  from `NSBonjourServices`, and fails silently when one is missing, so the plist
  now declares them; Android needs `CHANGE_WIFI_MULTICAST_STATE` or the Wi-Fi
  driver filters multicast out to save power. A denied local-network permission
  looks exactly like an empty network from inside the app, so on Apple platforms
  that case gets its own guidance and a settings link rather than a "no devices
  found" dead end.
- **Saved devices are a top-level destination, not a footer.** They were a
  "History" section pinned below however many strangers' earbuds the last scan
  turned up. The app now has a bottom bar — Nearby, Saved, Wi-Fi — and saved
  devices get a pane with room for the address, the vendor the address block
  belongs to, and an empty state that says how devices get there.
- **The scan list leads with devices we can probably talk to.** A scan in any
  populated building returns mostly noise — earbuds, laptops, a neighbour's TV —
  and the previous list sorted purely by signal strength, so a supported device
  across the room sat below every anonymous radio on the desk. Advertised
  service UUIDs, manufacturer-data company IDs and the MAC OUI are now read at
  scan time alongside the local name, matched against the spec catalogue, and
  the results split into a **Likely supported** section above the rest, each row
  badged with what the catalogue thinks it is.

  The four signals are weighted rather than pooled, because they are not equally
  telling (`MatchConfidence` in `rust/src/api/device_api.rs` is the single source
  of that judgement, shared by the scan and post-connect matchers). A vendor
  service UUID is near proof; a name prefix or company ID is good evidence; a MAC
  OUI is a vendor, not a product, so an OUI-only match stays out of the promoted
  section and reads "Possibly Xiaomi" rather than naming a device. Apple
  platforms report a per-host CoreBluetooth UUID instead of an address, so the
  OUI signal is simply absent there and is never confused for one.

  Matching is keyed on a device's identity rather than its id, so the hundreds of
  advertisements a device emits during one scan cost a single match; only the
  identifying fields of each spec cross the FFI boundary, not the parsed
  catalogue. Demo mode's mock devices now advertise a different signal each, so
  every rung of the ladder is visible without hardware.
- **Find Device view** — a "Find device" button on the connected-device
  header opens a hot/cold locator: live RSSI polled once a second, a
  distance guess from the log-distance path-loss model (presented as a
  rough bucket, with the raw dBm readings, extremes and a sparkline shown
  alongside), and a getting-closer/farther trend. When the device can make
  itself noticeable, one-tap alert buttons appear — from the standard BLE
  Immediate Alert service (0x1802, key finders/fitness bands) or from
  spec-declared beep/blink commands (`find_me`, `blink_led`). Detection
  reads the matched spec, but the endpoints it resolves against are GATT, so
  this is BLE-only today: Wi-Fi specs would need their `http_endpoints` /
  `mqtt_topics` to cross the FFI (they currently don't) before the same
  buttons could light up for them.
- **Linux desktop target (x86-64)** — build and iterate without an emulator:
  `./scripts/run-linux.sh --mock`, committed `linux/` scaffold, a
  `verify_linux_bundle.sh` that checks the Rust library is bundled *and*
  reachable (`RUNPATH` contains `$ORIGIN/lib`), and a CI job that builds
  release without the mock define and runs the integration tests headlessly
  under Xvfb — the first integration coverage needing no emulator/simulator.
- **Structured logging** (`lib/core/log.dart`) — levelled, six fixed
  categories (`[ble]`, `[spec]`, `[ha]`, `[packs]`, `[app]`, `[ui]`),
  timestamps, an injectable sink for tests, and a warning floor in release
  builds; ~40 log points across the BLE lifecycle, HA forwarding, spec
  matching, and pack installs.
- **Enumerated command parameters** — spec `allowed` values + `labels` now
  cross the FFI boundary (`ParameterDto`) and render as a labelled dropdown
  instead of a free-range slider; mismatched labels are dropped rather than
  mispaired.
- **Platform config-audit tests** (`test/platform/`) — 35+ fast tests pinning
  the Android manifest, iOS/macOS plists, entitlements, application-identity
  consistency, and the permission_handler-iOS Podfile invariant, each failure
  message naming the user-visible breakage.
- **CI artifact verification** — `scripts/verify_apk.sh` (Rust `.so` per ABI,
  merged-manifest permissions, application id) and `scripts/verify_ios_app.sh`
  (usage-description keys, linked FRB symbols) run against every built
  artifact; Android additionally builds release/R8 with the real (non-mock)
  BLE path compiled in; iOS runs simulator integration tests; `ios/Podfile`
  is now committed.
- **Android release signing** via a gitignored `android/key.properties`,
  falling back to debug keys with a loud warning instead of silently
  producing an unpublishable APK.

- **Liberated Bread rebrand** — new Material 3 theme and palette
  (`LiberatedBreadApp` / `LiberatedBreadTheme`), regenerated platform icons, a
  `tool/branding/` pipeline (`brand.json` + `generate_icons.mjs`),
  `docs/BRANDING.md`, and `test/core/brand_test.dart` contrast checks so a
  palette change that breaks WCAG contrast fails CI.
- **E2E screenshot walkthrough** — `scripts/e2e-walkthrough.sh` +
  `scripts/e2e_shot_server.py` drive
  `integration_test/e2e_walkthrough_test.dart` through the whole app on the
  iOS Simulator, snapshotting each step; tagged `e2e` in `dart_test.yaml` and
  excluded from CI's emulator job via `--exclude-tags=e2e`.
- **Remote spec packs** — download a JSON-manifest pack of device specs at
  runtime (same-origin-only, size-capped, validated through the Rust codec
  before install): `SpecPackService`, `spec_pack_provider`, and
  `SpecPackSettingsScreen`, plus a `SettingsStore` abstraction with
  `PrefsSettingsStore` and new `http`/`path_provider`/`shared_preferences`
  dependencies.
- **Home Assistant companion mode** — register with HA's native `mobile_app`
  API and forward spec-decoded BLE readings as sensor entities: HA
  models/services/providers and `HaSettingsScreen`, `ha_url` +
  `ha_sensor_mapping` helpers, a `TailscaleSuggestionCard` with remote-access
  hints, and secure keychain/keystore token storage via
  `flutter_secure_storage` (`secure_settings_store.dart`).
- **Spec-driven typed control UI** — matched device specs render buttons,
  sliders, and decoded values instead of raw hex:
  `typed_characteristic_widget`, `typed_command_widget`,
  `decoded_value_widget`, backed by `device_spec_match_provider`,
  `spec_codec_provider`, and `real_spec_codec`; plus cargokit native-build
  wiring so `flutter build` compiles the Rust crate on every platform.
- `scripts/run-ios-device.sh`, `.github/workflows/ios-adhoc.yml`, and
  `docs/ios-from-linux.md` — build and run on a physical iPhone: locally from
  a Mac (`--list`/`--device`), or as an ad-hoc IPA built in CI for Linux-bound
  developers.
- `scripts/run-android.sh` and `scripts/run-ios.sh` — build, boot the
  emulator/simulator if needed, install, and run.
- **Platform scaffolds** — Android (`android/`) and iOS (`ios/`) folders are now
  committed. `flutter build apk` and `flutter build ios` work out of the box.
- **CI overhaul** — separate jobs for Flutter (analyze + test + format +
  Codecov), Rust (fmt + clippy + test), Android debug-APK smoke build, iOS
  simulator build on macOS, and Android emulator integration tests.
- **Test coverage** — reusable `FakeBleService` plus widget/screen tests for
  `ScanScreen`, `DeviceScreen`, `DeviceControlPanel`, `RawCharacteristicWidget`,
  a provider test for `deviceSpecsProvider`, and unit tests for `bytesToHex`,
  `normalizeUuid`, and `mapConnectionState`.
- **Integration tests** under `integration_test/` covering the mock scan →
  connect → discover flow and the error + retry path.
- `scripts/test.sh` — one-shot local CI mirror.
- `scripts/run-remote-mac.sh` — build and run on an iPhone from Linux via a
  remote Mac over SSH: rsyncs the tree, launches `flutter run` remotely, and
  auto-hot-reloads on every local save (docs/ios-from-linux.md Option C).
- `pubspec.lock` is now committed for reproducible app builds.
- `lib/core/hex.dart` — `bytesToHex` and `normalizeUuid` helpers (deduplicated
  from three call sites).
- **FRB wiring** — `flutter_rust_bridge` 2.9.0 bindings are generated and
  committed (`lib/src/rust/`, `rust/src/frb_generated.rs`). `RustLib.init()`
  runs at app startup; `MockBleService` now delegates read/write to
  `rust/src/api/mock_api.rs` with a Dart fallback when the native library
  isn't loaded. CI builds the host Rust lib before `flutter test` and checks
  the bindings are in sync with the Rust API (drift check).
- Lint additions in `analysis_options.yaml`: `cancel_subscriptions`,
  `close_sinks`, `unawaited_futures`.
- Standard Bluetooth profile controllers: Battery Service (0x180F) and
  Device Information Service (0x180A)
- Protocol error types module (`error.rs`) with `ProtocolError` and `SpecError`
- FFI API: `load_device_spec()`, `match_device_to_spec()` (returns
  `Vec<MatchResult>` with categorical match reasons), unified
  `encode_command()`/`decode_value()` that take optional `spec_yaml` and
  `service_uuid` (spec wins when both supplied), and
  `identify_standard_profiles()` for service-UUID discovery
- Protocol dispatcher (`protocol::dispatch::select_protocol`) routes
  encode/decode requests to either a YAML-driven `GenericProtocol` or a
  built-in standard profile, with content-hash spec caching
- Spec format gains `mock_default` per format field; the simulator
  consults it before the name-based heuristic
- Parse-time spec validation: rejects fixed-width fields with the wrong
  `length`, parameter `min`/`max` bounds outside the declared type,
  and inverted `min > max` bounds
- `#[serde(deny_unknown_fields)]` on the protocol-execution spec structs
  (`DeviceInfo`, `Service`, `Characteristic`, `Command`, `Parameter`,
  `FormatField`) catches typos in YAML at parse time; `DeviceSpec`,
  `Identification`, and `ParameterSet` instead sweep unrecognized keys into an
  `extensions` catch-all (see the Changed entry on spec tolerance)
- Mock simulator with smart default values per field type
- E2E architecture walkthrough documentation (`docs/WALKTHROUGH.md`)
- Build and test guide for Linux and macOS (`docs/BUILD_AND_TEST.md`)
- Expanded README with architecture diagram, setup instructions, and Rust core docs
- Initial app scaffold: project structure; the `IoTDevice` and
  `BleDiscoveredService` models; the `BleService` layer and device manager; the
  scan and device screens; and Android BLE manifest permissions plus
  iOS `Info.plist` usage descriptions

### Fixed

- **Real BLE scanning tore itself down as soon as the native scan started**
  (`startScan` returns at scan *start*), so real hardware showed "No devices
  found" while the scan ran unwatched. The scan now waits for the adapter to
  actually stop, coalesces result batches (stable `discoveredAt`, no
  re-delivery of the previous scan's devices), and reports rssi/name changes
  only.
- **iOS could never scan**: with no `ios/Podfile`, permission_handler's iOS
  Bluetooth strategy is compiled out and answers every request "permanently
  denied" — before CoreBluetooth was ever reached. iOS now lets CoreBluetooth
  prompt natively and maps the adapter's `unauthorized` state to the
  permission-denied error.
- **Android 5.0–11 BLE**: the manifest declared only the API 31+ permissions;
  the legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` pair (with `maxSdkVersion="30"`)
  is now declared, so scanning no longer throws `SecurityException` on the
  older half of the supported range.
- **macOS**: `keychain-access-groups` added to both entitlements files
  (sandboxed `flutter_secure_storage` failed with `errSecMissingEntitlement`,
  so the HA token could not be stored) plus the local-network usage string.
- **Rust core**: over-length fixed-width format fields no longer panic the
  mock simulator (writes fill only the low `fixed_byte_size` bytes); a 64 KiB
  parse-time cap stops spec-controlled multi-GB allocations; the dispatch
  spec cache is bounded and shares parsed specs via `Arc`; `bool` template
  parameters encode as a single 0/1 byte; typo'd `{parameter}` template
  references are rejected at parse time instead of failing on first write.
- `ref`-after-dispose guards in the HA and spec-pack settings screens; HA
  toggle/disconnect failures are surfaced instead of silently dropped; mock
  notify timers no longer outlive `dispose()`; `openAppSettings()` failures
  are caught.
- cargokit's Linux/Windows CMake exported a pre-rebrand
  `_bundled_libraries` variable, so the Rust cdylib would silently not be
  bundled into desktop builds; `rust_builder/android` carried the pre-rebrand
  namespace.
- `e2e-walkthrough.sh` could exit 0 with zero screenshots (no shot-server
  readiness check); the shot server could hang on `simctl` and accept a stale
  PNG as fresh; `session-start.sh` leaked temp files.
- CI now installs the Android NDK the build actually uses
  (`FLUTTER_NDK_VERSION` pinned to 23.1.7779620 — Flutter 3.24.5 hardcodes it;
  installing anything else just made cargokit download this one mid-build),
  and the emulator job's disk-cleanup `rm -rf` on SDK paths is guarded against
  an unset `ANDROID_SDK_ROOT`.
- `HaSensorForwarder` recovers dropped readings when a push to Home Assistant
  fails, instead of reporting phantom success.
- `MockBleService.subscribeCharacteristic` no longer leaks the periodic
  `Timer` when the subscriber cancels without disconnecting.
- `RealBleService` now caches discovered GATT services per device, eliminating
  a redundant round-trip on every read/write/subscribe. Cache is invalidated on
  disconnect.
- `deviceSpecsProvider` distinguishes "missing asset" (silent) from "malformed
  YAML" (logged), so real errors are no longer swallowed.
- UUID normalization now handles all-zero prefixes correctly (e.g. `000000f0`)
- Mutex lock recovery at FFI boundary (prevents panic on poisoned mutex)
- Overflow guard in codec field offset calculation
- Saturating cast for u64→i64 in DTO conversion

### Changed

- **`./scripts/run*.sh` keep the repo-managed Flutter SDK on CI's pin.** When
  the run scripts use the SDK they install at `~/.flutter-sdk` and CI's
  `FLUTTER_VERSION` (in `.github/workflows/ci.yml`, surfaced by
  `scripts/ci-versions.sh`) has moved ahead of what is on disk, a run would
  otherwise fail deep inside `flutter pub get` on pubspec's Dart SDK
  constraint. `run.sh`, `run-linux.sh`, `run-android.sh` and `run-ios.sh` now
  source a shared `scripts/flutter-ensure-version.sh` that upgrades that SDK in
  place before running, so a bump in `ci.yml` no longer needs a separate
  `./scripts/setup.sh`. It is deliberately narrow: only an SDK that actually
  lives under `FLUTTER_HOME` is ever replaced — a Flutter from Homebrew,
  Android Studio, the distro, or a checkout elsewhere is left alone and only
  warned about, exactly as `setup.sh` does. A failed download leaves the
  existing SDK intact and the run continues (offline degrades to "slightly
  stale", not "cannot run"). Set `LB_FLUTTER_AUTO_UPGRADE=0` to skip the check.

- **New mascot, and a palette re-derived from it.** The 2026 logo keeps the
  loaf and the arms but swaps the ground it flexes on from turquoise to blush
  pink, and outlines the mascot in navy rather than warm brown. Because
  `brand.json` is sampled from the artwork, the palette followed:
  `teal` → `blush` (`#2FB9BF` → `#EBA1C6`), `tealDark` → `blushDeep`,
  `breadOrange` `#E8963C` → `#EF900A`, `face` `#3A2410` → `#112545`. All 43
  platform icons, the Android adaptive-icon background and the web manifest
  colours were regenerated by `tool/branding/generate_icons.mjs`. Contrast
  held: `ink` on blush is 7.60:1 and on bread orange 6.30:1, both up from the
  old 6.1:1, and `brand_test.dart` still enforces the 4.5:1 floor.
  `app_icon_mascot.svg` is gone — the new artwork was supplied as raster, so
  the committed PNG is the master and a stale vector of the old logo would
  have silently won back if the PNG were ever removed.

- **The Android emulator job stopped hanging on a settling race.** It had hung
  for its full timeout with zero Dart output while the same suites passed on
  Linux and the iOS simulator, which reads as a graphics flake and is not one:
  diffing the failing run's logcat against a passing one shows
  `FlutterRenderer: Width is zero. 0,0` in *both*, while only the failing run
  recreates `MainActivity` for a configuration change four seconds after the
  Dart VM service came up — orphaning the isolate `flutter_tools` had attached
  to, which then waited forever. It happened while the launcher and Play
  Services were still ANR-ing their way through startup. The manifest already
  declares Flutter's own `configChanges` set, so the fix is to remove the
  churn: CI now boots `aosp_atd` (Google's CI image, no launcher or Play
  Services, and faster to boot), and the test run makes two attempts each
  bounded by `ANDROID_EMULATOR_ATTEMPT_TIMEOUT` — a bound rather than a bare
  retry, because the failure hangs instead of exiting, so the step timeout
  alone left nothing to retry with. A passing retry still warns and uploads
  both attempts' logcats. That logic is a real script,
  `scripts/ci-emulator-tests.sh`, rather than an inline `script:` block:
  `android-emulator-runner` splits that input on newlines and execs each line
  as its own `/usr/bin/sh -c`, so a function body or an `if`/`fi` cannot
  parse, nothing carries between lines, and the shell is dash. The workflow
  now passes one line and the retry runs under bash — where it can also be
  exercised against stub `flutter`/`adb` binaries locally.

- **CI's toolchain pins are declared once and read once, instead of being
  grepped out of the whole workflow.** `scripts/ci-versions.sh` used to hunt
  values out of step bodies: the highest `platforms;android-NN` anywhere in
  the file, the first `targets:` line containing `-android`, packages
  recovered from `apt-get install` and its line continuations, the emulator's
  settings found by scanning forward from a marker. Every one of those could
  be tripped by a **comment** — naming an API level in prose really did change
  what developer machines installed, twice, while this file was being edited.
  Now every pinned version lives in ci.yml's top-level `env:` block, each step
  interpolates it, and the parser reads that one block and nothing else, so
  prose and configuration can no longer be confused. Output is unchanged apart
  from a new `CI_CMAKE_VERSION`, and `scripts/setup.sh` plus the session hook
  now install the matching CMake so dev machines stop hitting the same
  mid-build install CI did. GitHub does not expose the `env` context to
  `strategy:`, so the emulator's `api-level` matrix is the one repeated
  literal — `test/platform/deployment_targets_test.dart` asserts it matches
  its env key.
- **Platform SDK floors raised to what the pinned Flutter actually supports,
  and locked together by a test.** Every platform declared its floor in more
  than one file and nothing cross-checked them, so they had drifted apart in
  every direction:
  - **iOS 12.0 → 13.0** across `ios/Runner.xcodeproj`, `AppFrameworkInfo.plist`
    and the commented `ios/Podfile` platform line; the Rust core podspec went
    **11.0 → 13.0**.
  - **macOS 10.14 → 10.15**, with the macOS podspec **10.11 → 10.15**.
  - **`rust_builder` Android `compileSdkVersion` 33 → 36** (matching the app's
    `flutter.compileSdkVersion`) and **`minSdkVersion` 19 → 24** (matching the
    app's). The stale 33 also made Gradle stop mid-build to download an SDK
    platform nothing else wanted — measured at 2.5s, so the reason to fix it
    is the three-release gap against the app, not the seconds.
  - **CI installs API 36** instead of 34, which no module compiled against,
    and pins `cmake;3.22.1` alongside it — Flutter's own Gradle plugin wires a
    `CMakeLists.txt` into `:app` for its Android 15 16 KB page-size support,
    so AGP was installing CMake mid-build on every run (1.2s). Both are about
    installing the build's inputs in one visible, retryable step rather than
    having Gradle pause to accept a licence and fetch over the network.
    The emulator stays on API 34; it is a separate axis.
  - `rust_builder` no longer declares its own AGP on the buildscript classpath.
    cargokit's template pinned 7.3.0 there, which could never take effect —
    `android/settings.gradle` resolves AGP 8.6.0 first and a parent-first
    classloader means the loaded class wins — so it only fetched a second,
    ancient AGP while presenting a version number that looked authoritative.

  13.0 and 10.15 are what Flutter 3.44.8 scaffolds for a new app, so this is
  catching up to a decision the toolchain already made rather than a new one;
  the practical effect is that iOS 12 and macOS 10.14 are no longer claimed.
  New `test/platform/deployment_targets_test.dart` asserts every file
  declaring a floor agrees and that none drops below the pinned Flutter's, so
  the next bump cannot move one file and leave five behind.
- **The ad-hoc IPA workflow no longer pins its own toolchain.** It had drifted
  to Flutter 3.24.5 while CI moved to 3.44.8, so the one artifact that gets
  installed on real hardware was built with an SDK nothing else tested.
  `ios-adhoc.yml` now sources `scripts/ci-versions.sh` — the parser dev
  environments already provision from — and feeds the Flutter version and the
  iOS Rust target list out of `ci.yml` into its setup steps, so the two cannot
  diverge again. Reading it after checkout means an ad-hoc build of an older
  ref uses that ref's pins. The target list also fixes real work the old pin
  caused: it carried only `aarch64-apple-ios`, so the no-secrets simulator
  fallback made cargokit install `aarch64-apple-ios-sim` mid-build instead of
  in the cached setup step.
- **The Android emulator job got its Gradle cache and stopped building ABIs it
  cannot run.** It never used `gradle/actions/setup-gradle` (the APK job always
  had it), so it rebuilt Gradle's dependency cache every run — the same
  `flutter build apk --debug` cost ~2m40s in one job and ~5m40s here. Its
  warm-up build now also passes `--target-platform android-x64`: the AVD is
  x86_64 and the test-phase build compiles exactly x86/x86_64, while the
  warm-up had been compiling the Rust crate four times, including two arm
  targets nothing in the job could load.
- **CI's device integration tests now run as one cycle per platform, and the
  iOS simulator boots while the build runs.** On a device, every file passed
  to `flutter test` is its own kernel-compile → native build → install →
  launch cycle (~2 minutes each on the 10x-billed macOS runner, even fully
  cached); the new `integration_test/ci_all_test.dart` bundles the mock-safe
  suites so the iOS and Android jobs pay that cycle once. It initialises the
  integration-test binding itself, before the groups: the binding registers its
  end-of-run `tearDownAll` in its constructor, so leaving that to the first
  imported suite would scope the "all tests finished" hook to that suite and
  fire it between the two.
  `test/platform/integration_aggregate_test.dart` asserts both directions — a
  mock-safe suite missing from the aggregate never runs on a device, and an
  e2e-tagged one added to it would run where its host-side screenshot server is
  unreachable. The linux-desktop job still runs each file in its own process,
  so per-file isolation coverage survives. The iOS job also starts `simctl boot`
  right after checkout and only waits for it after the build, turning ~65 serial
  seconds of boot wait into overlap. Together: ~10m10s → ~7m of macOS wall
  clock on a warm run, and the emulator job sheds a cycle too.

  The iOS job's warm-up build now compiles the **test** entrypoint
  (`--target=integration_test/ci_all_test.dart`) rather than `lib/main.dart`.
  It exists to move the app build outside `flutter test`'s hardcoded
  12-minute loading window, but it was building a different Dart entrypoint
  than the tests use — so the kernel differed, Xcode relinked, and a warm run
  paid 95.7s there plus another 64.1s inside the window for largely the same
  work. Both invocations also pass `--no-pub`, since the job already ran
  `flutter pub get`. The simulator boot moved to just before that build:
  ~2 minutes of build already covers a ~65s boot twice over, and starting it
  at checkout only left a booted simulator idling through the SDK restore and
  rustup, holding memory and cycles on a 3-core runner during the CPU-bound
  part of the job.
- **Dev environment setup now follows CI instead of re-pinning it.**
  `scripts/ci-versions.sh` reads the Flutter/NDK/Android API/build-tools/FRB
  pins, the rustup target lists, the Linux desktop apt packages and the
  emulator's API level, system image and device profile out of
  `.github/workflows/ci.yml`; `scripts/setup.sh` and the Claude Code session
  hook provision from those values (each has a fallback, and a parse miss
  warns). `scripts/setup.sh` also gained the Linux desktop toolchain install
  and now creates the `liberated_bread_test` AVD from CI's exact system image
  and device profile. Both paths now compare the *installed* Flutter against
  the pin rather than accepting any SDK that exists — the session hook
  replaces a stale one, and `setup.sh` says so without touching an SDK it
  didn't install — so a `FLUTTER_VERSION` bump actually reaches dev
  environments instead of surfacing later as a Dart SDK constraint failure.
- **Claude Code web sessions can build and run Android and Linux desktop.**
  `.claude/hooks/session-start.sh` grew two auto-detected tiers on top of the
  host toolchain: the Linux desktop dependencies (wherever apt is usable) and
  the Android SDK/NDK, emulator and AVD (when `/dev/kvm` and disk allow).
  Both skip with a logged reason rather than failing the session, and can be
  forced or suppressed with `LB_SETUP_LINUX_DESKTOP` / `LB_SETUP_ANDROID`.
- Spec parsing is now tolerant of real-world protocol-docs specs: `DeviceSpec`,
  `Identification`, and `ParameterSet` dropped `deny_unknown_fields` in favor
  of a flattened `extensions` catch-all, so WiFi specs and vendor extension
  blocks parse instead of being rejected (`rust/tests/spec_tolerance.rs`
  documents the intent with vendored real specs).
- `scripts/test.sh` now mirrors CI's FRB binding drift check locally (skipped
  with a warning when the pinned codegen isn't installed).
- Migrated from the archived `serde_yaml` crate to the maintained
  `serde_yaml_ng` fork (imported under the same name via a Cargo rename).
- `MockBleService` deduplicates its two mock devices' service definitions into
  shared `_controlService` / `_batteryService` constants.
- `DeviceScreen` extracts a file-private `_CenteredProgress` widget used by the
  connecting/discovering states.
