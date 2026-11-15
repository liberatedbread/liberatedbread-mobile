# Blocking Vendor Updates and the Cloud

The most likely way a working local protocol disappears is a firmware update.
TP-Link closed port 9999 on HS100 hardware v4 with firmware 1.1.0; LG ships
firmware that closes the exploits webOS homebrew depends on; iRobot's 2025
models have no local broker at all. A device that cannot reach its vendor
keeps the protocol it shipped with.

This page covers the **DNS half** of keeping a device away from its vendor:
which names to block, which to redirect, which to leave alone, and the lists
this repository generates from its specs so you do not have to work that out
per device. The **firewall half** — the rule that actually stops a device
routing out, on UniFi, MikroTik, OPNsense, OpenWrt, Firewalla and consumer
routers — is the shared how-to at
[liberatedbread.com/firewall](https://liberatedbread.com/firewall/).

!!! warning "Firewall first. A DNS list is the second layer."
    A device that ignores the resolver your router hands out, hardcodes one,
    or connects to a literal address walks straight past any DNS list. Block
    the device's WAN access with a firewall rule; add a list to catch what a
    rule scoped to one device misses (another device on the same firmware, a
    guest network, the day the rule gets deleted). Every generated list says
    this in its header, because it is the thing people skip.

## What the lists are built from

Each spec's `cloud.egress` block records, per name the device reaches out to:

- **who** opens the connection — the `device`, or only the vendor's `app`;
- **what for** — `device_cloud`, `firmware_check`, `firmware_download`,
  `time`, `telemetry`, `advertising`, `content` and so on;
- **what blocking it costs** — `when_blocked.impact` (`none`, `degraded`,
  `breaks`, `unknown`), with the effect and any known workaround spelled out;
- **how sure we are** — `verification`, and the `basis` for anything this
  project has not observed itself.

The field reference is in
[Reading a Device Spec](api/spec-format.md#cloudegress-what-it-phones-and-what-blocking-it-costs).
The generator applies three rules that are the whole point of recording the
facts rather than a list of names:

1. **App hosts are never listed.** Blocking the vendor app's sign-in host at
   the router breaks the app for every phone in the house and does nothing to
   the device.
2. **Time is redirected, never blocked.** A device that loses its clock loses
   its schedules, so no entry carrying the `time` role is ever blocked,
   whatever else it serves. NTP names go to a LAN NTP server when you name one;
   any other clock (a webOS TV reads its time from the same HTTPS API as its
   Content Store) is left alone.
3. **Anything whose spec says blocking `breaks` the device is left out**, and
   named in the list's header with the reason — even in a combined list where
   another spec calls the same name safe. The comparison is DNS containment,
   not spelling: a rule that takes a parent and its subdomains is dropped when
   a clock or store some spec needs lives under it, and the header says which
   name it would have covered. Some public smart-TV blocklists have carried
   LG's `lgtvsdp.com`; it is where the TV's clock comes from. A device whose
   every entry is one of these still gets a list, with no rules: its header
   is the part that matters.

## The published lists

The docs build publishes every list next to the [JSON API](api/index.md):

| Path | What |
|------|------|
| `/api/v1/blocklists/<profile>.<format>` | Every device with egress data |
| `/api/v1/blocklists/devices/<id>/<profile>.<format>` | One device — prefer these: block what you own |
| `/api/v1/blocklists/index.json` | Every egress entry, which files exist, and which specs have no egress data yet |

Two profiles:

| Profile | Blocks | For |
|---------|--------|-----|
| `updates` | Only names with a `firmware_check` or `firmware_download` role | Stopping the update while the vendor app usually keeps working away from home (where a device's update offer rides its main cloud link, that link is listed too). Weakest: it stops the update hosts the specs *name*, and vendors move update traffic without notice. |
| `cloud` | Every name the device itself contacts, except time | Cutting the device off. The DNS companion to the firewall rule. |

Formats, by what you run:

| You run | File | Notes |
|---------|------|-------|
| Pi-hole | `<profile>.pihole.txt` | Add as an adlist. Names that take their subdomains use adblock syntax, which needs FTL 5.22+ or v6. |
| AdGuard Home | `<profile>.adguard.txt` | Add as a blocklist by URL, or paste into custom rules. |
| OpenWrt, or anything on dnsmasq | `<profile>.dnsmasq.conf` | Drop into dnsmasq's conf-dir. |
| OPNsense, pfSense, or Unbound | `<profile>.unbound.conf` | Paste under `server:` in the custom options. |
| MikroTik RouterOS 7.5+ | `<profile>.routeros.rsc` | `/import`. Re-importing a list replaces its previous import; lists for different devices coexist. |
| BIND, PowerDNS Recursor, Knot, Unbound `rpz:` | `<profile>.rpz.zone` | A response-policy zone. |
| Anything else | `<profile>.hosts.txt` | Exact names only — a hosts file cannot express subdomains. |

The published lists answer blocked names with NXDOMAIN or a null address (on
Pi-hole and AdGuard Home, whatever your blocking mode returns) and
**do not redirect time**, because they cannot know your LAN's NTP server; the
time names are listed in each header instead. For a redirect, generate your
own.

## Generating your own

Any checkout of this repository can render one list, for your devices, with
your addresses:

```bash
pip install -r requirements.txt

# Kasa plugs: stop updates, redirect their NTP lookups to the router's NTP server
python scripts/generate_blocklists.py --format dnsmasq --profile updates \
    --device tplink-kasa-smart-plug --time-server 192.168.1.53

# Two devices, cut off entirely, as an AdGuard Home list
python scripts/generate_blocklists.py --format adguard --profile cloud \
    --device tplink-kasa-smart-plug --device lg-webos

# Which specs record a cloud but have no egress data yet (the contribution queue)
python scripts/generate_blocklists.py --coverage
```

## "Can I point these names at Home Assistant instead?"

Usually it gains you nothing. Resolving a vendor name to a LAN machine only
helps if something on that machine answers the connection the way the device
expects, and nothing on a Home Assistant box speaks TP-Link's or LG's cloud
protocol. A device that connects over TLS gets a refused or failed connection
— the same outcome as a sinkhole, plus noise in the logs of whatever happens
to listen on that port.

There are two cases where pointing names at a local machine does something:

- **Time.** Point NTP names at an NTP server on your LAN — most routers run
  one (OpenWrt, RouterOS, OPNsense and pfSense all can), as does `chrony` on
  any always-on machine, including the one running Home Assistant. That is
  what `--time-server` writes. Kasa devices are not known to honour the NTP
  server DHCP offers, so the DNS redirect is what reaches them.
- **A device that misbehaves when refused.** Some 2023 Kasa builds drop and
  rejoin Wi-Fi every ten minutes when they cannot reach their cloud. A Home
  Assistant community member reported that resolving the cloud names to a
  local web server that *accepts* the TCP connection settled them, where a
  refusal did not. `--sinkhole <address>` writes that redirect for every
  blocked name. The port the device dials shows up in the firewall log
  (older units used 50443); a bare TCP listener such as `socat` should
  behave like the web server in that report, but has not been tested here.
  Unbinding the device before you block it (below) is the better fix.

## TP-Link Kasa, worked through

The Kasa plugs, switches and bulbs in
[the Kasa spec](devices/tplink-kasa.md) are the clearest case for this
page: the local protocol needs no cloud, the firmware image comes from its own
plain-HTTP host (`download.tplinkcloud.com`), and the device will tell you
which cloud name it uses.

1. **Ask the device which cloud it talks to.** The name has changed between
   firmware generations (`devs.tplinkcloud.com` on 2016-era units,
   `n-devs.tplinkcloud.com` since, with regional forms). The `get_cloud_info`
   command reads it back (bulbs: `get_cloud_info_bulb`), with softScheck's
   client:

    ```bash
    ./tplink_smartplug.py -t 192.168.1.50 -j '{"cnCloud":{"get_info":null}}'
    ```

    `server` is the name to block; `cld_connection` is `1` while the link is
    up. The reply also carries the bound account's e-mail address — do not
    paste it anywhere public.

2. **Unbind it while it is still online**, unless you want the Kasa app to
   keep working away from home. Unbinding needs the cloud reachable (a
   blocked device answers `err_code -24`, "no reply from server"). It stopped
   the reconnect loop above for one owner, though an HS220 on 1.0.10 kept
   looping until TP-Link's fixed build. The request is in the spec's
   `protocol_details.tplink_smarthome_protocol.cloud_module`.

3. **Keep the clock.** Schedules, timers and away mode run on the device's
   clock, and it has no battery backup. Redirect its NTP names
   (`pool.ntp.org` and its subdomains, `time.nist.gov`) with
   `--time-server`, or set the clock over the local protocol
   (`time.set_timezone`; python-kasa's `kasa --host <ip> time sync`).

4. **Block.** Firewall the device's WAN access, then apply the Kasa list —
   `updates` if you still want off-LAN control through the app, `cloud`
   otherwise.

5. **Check from the device's side.** Read `get_cloud_info` again:
   `cld_connection` should be `0`.

## LG webOS: what not to block

The [LG webOS spec](devices/lg-webos.md) is the case for recording costs
rather than names. The firmware update names are safe to block — they include
the four the webOS Homebrew Channel's own "Block system updates" option points
at localhost — and so are LG's ad and telemetry names. But the TV's clock comes
from the Service Delivery Platform (`<country>.lgtvsdp.com`, and the newer
`nextlgsdp.com`), not from NTP: block those and the clock resets after a cold
boot, apps fail their certificate checks, and the Content Store goes with
them. The generated lists leave them out and say why. Turn off the TV's own
automatic updates too, and prefer the router over the Homebrew Channel's
hosts-file block: one tester reports the TV's boot-time update check runs
before that block applies.

## iRobot Roomba: no list, on purpose

Every hostname published for the Roomba belongs to the account route to the
robot's local password — the vendor app's, or a password tool's — not to the
robot. The [spec](devices/irobot-roomba.md) records them as `app` hosts, so
the generated lists carry nothing for it: a list built from those names would
break the password route and leave the robot untouched. The robot's own
connection is to an AWS IoT endpoint no public source names. Firewall it by
address, which needs no hostname — the
[Roomba worked example](https://liberatedbread.com/firewall/) walks through it.

## After the vendor is gone

A shut-down service is not a reason to drop the block. A device that still
calls a name its vendor lets lapse will call whoever registers that name next.
The June oven's update names are still in its list after the service retired
on 2026-09-22 for that reason. Keep the list.

## Adding a device's hosts

Egress data is a spec field like any other: add a `cloud.egress` entry per
name, with `contacted_by`, `roles`, `when_blocked` and `verification` (and
`basis`, unless you watched the device do it yourself). The field reference
is in [Reading a Device Spec](api/spec-format.md#cloudegress-what-it-phones-and-what-blocking-it-costs),
and `python scripts/generate_blocklists.py --coverage` lists the specs that
already record a vendor cloud but no egress data — the natural place to
start. A capture of the device's own DNS lookups at the router is worth more
than any list found online: it is the difference between `reported` and
`confirmed`.
