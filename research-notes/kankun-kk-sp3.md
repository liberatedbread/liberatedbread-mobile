# Kankun KK-SP3 "Small K" Wi-Fi Smart Plug — Research Notes

## What it is
The Kankun KK-SP3 (also "Small K", "Huafeng WiFi Plug") — a ~$20 AliExpress
Wi-Fi socket (~2014) that became famous precisely because it is a tiny
OpenWrt box with the doors open. Vendor app/cloud (Kankan / smallk) are long
dead, which is irrelevant: the device is controlled over plain LAN SSH/HTTP.

## Local protocol — confirmed, trivially
Documented since [Hackaday, 2014-11-13](https://hackaday.com/2014/11/13/hacking-a-20-wifi-smart-plug/)
and many follow-ups ([anites.com teardown](http://www.anites.com/2015/01/hacking-kankun-smart-wifi-plug.html),
[donbowman.ca 2018](https://blog.donbowman.ca/2018/01/30/more-hacking-to-secure-the-gadget-army-the-kankun-sp3/),
[yurt-page/Kankun_KK-SP3](https://github.com/yurt-page/Kankun_KK-SP3) wiki-repo):

- **SSH**: `ssh root@<plug-ip>`, password `p9z34c` (BusyBox dropbear,
  enabled by default). The relay is a GPIO — toggle directly, e.g. via
  `/sys/class/gpio` or the stock `relay` script, or install anything else.
- **HTTP**: the community CGI (`relay.cgi`) gives
  `http://<plug>/cgi-bin/relay.cgi?state=1|0` (and JSON variants
  `?jsoncallback=...&state=...`); uhttpd can be enabled for a cleaner API.
- **Firmware**: stock image is OpenWrt-era; full OpenWrt upgrade possible
  (siemieniak.net 2020 guide: `cat /dev/mtd5` backup first). Flashing is
  optional — stock firmware is already fully local.

## Cloud dependency: none, ever
No account exists in the loop. The plug boots its own AP for provisioning;
join it to Wi-Fi via the serial/SSH/web path. The dead vendor cloud was only
used by the original phone app.

## Why it's in this repo
It is the cleanest possible "dead brand, local rescue" story: the rescue is
complete because the device ships as a general-purpose Linux computer with
known root credentials.

## APK
Not applicable/not fetched — the vendor app is unnecessary; control is SSH/HTTP.

## Safety
LOW-MEDIUM. Mains relay with no enclosure interlock; default root password is
public — changing it (or LAN-segmenting) is mandatory, and mains-voltage
caution applies when reflashing near exposed pads (power the unit from USB
serial adapter only when the case is open).
