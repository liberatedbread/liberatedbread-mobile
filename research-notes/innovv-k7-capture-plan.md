# INNOVV K7 — Hardware Capture Plan

Purpose: establish, against real hardware, what the INNOVV K7's local Wi-Fi
surface actually is, so `device-specs/devices/innovv-k7-dashcam.yaml` can be
written from captured bytes rather than from family resemblance. Each capture
below is mapped to the question it answers.

Nothing about the K7's API is confirmed today. What we have is circumstantial:
INNOVV's earlier cams are Novatek-based (the K2 is an NT96663), INNOVV support
threads tell K-series owners to browse `http://192.168.1.254` for the SD card,
and INNOVV cams have historically taken `?custom=1&cmd=NNNN` CGI. The K7 is a
2024 dual-2K unit with 5.8 GHz Wi-Fi and may well be a different SoC. **Section
1 is the go/no-go**: it decides whether the rest of this document applies or
whether we fall back to section 6.

## 0. Facts to record before touching anything

- K7 firmware version (INNOVV app → settings, or the on-camera menu). Every
  finding below is only true for the firmware it was captured on.
- The camera's AP **SSID exactly as broadcast** (expected `INNOVV*` or
  `K7*` — record the real string, including case and any MAC-derived suffix)
  and its passphrase.
- Whether the AP is 2.4 GHz, 5.8 GHz, or both, and whether the band is
  switchable. Some phones will not join a 5.8 GHz-only AP in some regions.
- The address the phone gets from the camera's DHCP, and the **gateway** —
  this is what the spec's `gateway_ip` records. `192.168.1.254` is the
  expectation, not a given.
- Whether the K7 also supports station mode (joining your home Wi-Fi). If it
  does, everything below should be re-checked on the home LAN, where the
  routing problem in section 7 disappears.

Do all captures from a laptop joined to the camera's AP, not from the phone:
`curl` output is the deliverable, and a laptop will not silently move the
request to cellular the way a phone does (section 7).

## 1. Is it Novatek at all? (go/no-go, 10 min)

Join the camera's AP, then:

```bash
CAM=192.168.1.254          # or whatever gateway section 0 recorded

curl -sv "http://$CAM/"                          # root: directory listing? UI?
curl -si "http://$CAM/?custom=1&cmd=3016"        # ping
curl -si "http://$CAM/?custom=1&cmd=3014"        # command status
```

Record full headers and bodies for all three, including the `Server:` header —
the server string is often the clearest SoC fingerprint.

Answers:

- **Is the CGI there?** A Novatek-family cam answers `cmd=3016` with a small
  XML/text body carrying `<Status>0</Status>` or `st=0`. A 404, an empty
  200, or an HTML error page means the CGI is not this shape.
- **What serves the root?** A plain Apache/boa-style autoindex of the SD card,
  a vendor web UI, or nothing at all. If it is an autoindex, capture it — an
  autoindex alone is enough to build offload on, even with no CGI.
- **Port sweep** while you are here: `nmap -Pn -p- $CAM` (or
  `for p in 80 81 554 8080 8192 3333; do nc -zvw2 $CAM $p; done`). Record every
  open port. 554 means RTSP, 8192 is the classic Novatek stream port, 3333 is
  the Novatek status socket.

**If none of the CGI probes answer, stop here and go to section 6.** The rest
of this plan assumes the family API exists.

## 2. The file list (the capture that matters most)

This is the one the whole offload feature is built on.

```bash
curl -s "http://$CAM/?custom=1&cmd=3015" -o k7-filelist.xml
```

If that returns an error or an empty list, the camera is probably in recording
mode and must be moved to playback mode first. Try, recording what each does:

```bash
curl -si "http://$CAM/?custom=1&cmd=3001&par=0"   # mode: movie
curl -si "http://$CAM/?custom=1&cmd=3001&par=2"   # mode: playback
curl -si "http://$CAM/?custom=1&cmd=2001&par=0"   # stop recording
curl -si "http://$CAM/?custom=1&cmd=3037"         # current mode status
```

Then re-run `cmd=3015`.

Answers, all of which become parser requirements:

- **The exact XML schema.** Element names, nesting, and whether it is one flat
  `<ALLFile>` or split by folder. File this verbatim; it becomes the parser's
  test fixture.
- **The path format** (`A:\NOVATEK\MOVIE\FILE.MP4` or otherwise) and therefore
  the drive-letter-and-backslash → URL-path mapping the parser must do.
- **Per-file metadata available**: size, timestamp, duration, and — critically
  for a dual-channel cam — **how front and rear are distinguished**. Separate
  folders? A filename suffix? A field? If nothing distinguishes them, the UI
  cannot offer a front/rear filter and we need to know that now.
- **How locked / emergency / parking clips are marked.** These are the clips
  an owner most wants off the camera, so the filter matters.
- **Whether the list is complete or paginated.** Fill the card and re-run: a
  512 GB card of 1-minute clips is tens of thousands of entries. If there is a
  cap or a truncation, find it — get the count from the list and compare
  against the true file count read off the SD card in a reader.
- **How long the request takes** on a full card. If it is 30+ seconds, the UI
  needs a progress state rather than a spinner.

Also capture the sibling commands and note which exist:

```bash
curl -si "http://$CAM/?custom=1&cmd=3021"    # save settings to flash
curl -si "http://$CAM/?custom=1&cmd=3029"    # show SSID/password
curl -si "http://$CAM/?custom=1&cmd=2016"    # current recording time
```

## 3. Fetching a file — the semantics offload depends on

Pick one small clip from the list, convert its path to a URL, and:

```bash
F=/NOVATEK/MOVIE/FILE.MP4     # from the section-2 path mapping

curl -sI "http://$CAM$F"                                  # headers only
curl -s  -r 0-1023 -D - "http://$CAM$F" -o /dev/null      # range request
curl -s -w '%{size_download} bytes in %{time_total}s (%{speed_download} B/s)\n' \
     "http://$CAM$F" -o /tmp/clip.mp4                     # throughput
```

Answers:

- **`Accept-Ranges` and whether a `Range` request actually returns `206`** with
  the right slice. This is a design fork, not a detail: with ranges we build
  resumable downloads that survive the phone sleeping or the rider walking out
  of Wi-Fi range; without them, every interruption restarts the file, and the
  UI has to be honest about that.
- **`Content-Length` correctness** — needed for progress. Check it against the
  size the file list reported and against the file on the SD card.
- **Real throughput.** Time a full clip. This sets expectations for the whole
  feature and decides whether "download all" is a reasonable button. If it is
  ~2 MB/s, a 1-minute 2K clip is tolerable; if it is 500 KB/s, the UI should
  say so up front rather than appear hung.
- **Concurrency.** Run two `curl`s at once and compare aggregate throughput to
  one. Most dashcam APs get *slower*; if so, the download queue stays serial.
- **Does fetching a file while the camera is recording work**, and does it
  drop frames on the recording? If it does, offload must stop recording first
  and say why.
- **Byte-for-byte integrity**: `sha256sum` the downloaded clip and the same
  file read from the SD card in a reader. They must match.

Thumbnails, for the browse UI:

```bash
curl -si "http://$CAM/?custom=1&cmd=4001&par=A:\\NOVATEK\\MOVIE\\FILE.MP4"
curl -si "http://$CAM/?custom=1&cmd=4002&par=A:\\NOVATEK\\MOVIE\\FILE.MP4"
```

Record the exact `par` quoting/escaping that works (this is the fiddliest part
of the family API), the image format returned, and its size.

## 4. Live preview and playback (in scope for v1)

```bash
ffprobe -v verbose "rtsp://$CAM/live"       # try /live, /ch0, /0, /video
ffprobe -v verbose "http://$CAM:8192"
```

Answers:

- **Which stream URL works**, its container/codec, resolution and latency.
- **Whether the front and rear channels are separately addressable**, and how.
- Whether starting a preview requires a CGI mode change first, and whether a
  preview stream blocks file downloads (they often share bandwidth badly).
- Whether an already-recorded clip plays over plain HTTP with seeking — i.e.
  whether in-app playback can just be a ranged HTTP fetch (section 3) or needs
  full download first.

## 5. Session behaviour

- **Heartbeat**: leave the AP joined and idle for 5 minutes, then re-run
  `cmd=3015` without any intervening request. If it fails, the camera expects
  a periodic `cmd=3016` — find the timeout by bisecting (1, 2, 5, 10 min) and
  record it. This determines whether the app must run a keepalive timer.
- **Single client?** Join with a second device and run a file list on both.
  Many of these cams serve one client at a time; if so, the app must tell the
  user to close the INNOVV app.
- **Does the camera drop the AP** when it starts recording, or after an idle
  period? Time it.

## 6. Fallback — capture the INNOVV app (only if section 1 said no)

If the CGI is not there, the protocol has to come from the vendor app.

1. Android phone, INNOVV app installed, joined to the camera AP.
2. `mitmproxy` in transparent mode on a laptop sharing the connection, or
   `PCAPdroid` on-device (no root needed, and it captures the AP-side traffic
   the camera serves).
3. Exercise, in one clean session: open the app, let the file list load, open
   a thumbnail, play a clip in-app, download one clip, change one setting,
   start/stop recording.
4. Export the flow.

If traffic is TLS-pinned (unlikely on a device-local AP, but check), fall back
to static analysis: `apktool d`/`jadx` the APK and grep the string table for
`192.168`, `custom=1`, `cmd=`, `.cgi`, `rtsp://`.

The deliverable is identical either way: request/response pairs for list,
fetch, thumbnail, and control.

## 7. Phone-side gotcha to confirm (affects the app, not the spec)

Once the laptop captures are done, repeat *one* file fetch from an Android
phone joined to the camera AP, with mobile data ON. Android deprioritises a
Wi-Fi network with no internet, and an app that does not bind its socket to
that network will send the request out over cellular, where it dies. Confirm
whether this happens on your phone — it determines whether the app needs a
`bindProcessToNetwork` platform channel, and it is much cheaper to know now
than to debug as "downloads mysteriously fail on Android".

Also note whether the phone shows the "this network has no internet, stay
connected?" prompt, and what happens if the user misses it.

## 8. What to file back

For each capture: the raw file (XML body, response headers, pcap/flow export,
`ffprobe` output), plus camera firmware version, AP SSID and band, laptop OS
and `curl` version, and which section number produced it. Anything confirmed
against hardware this way lands in the spec with `testing.status: verified`;
anything still inferred from the Novatek family stays marked as inferred, with
the reason.

Negative results are results — "cmd=4001 returns 404 on this firmware" is
worth exactly as much here as a working thumbnail, and saves the app from
offering a control that can only fail.
