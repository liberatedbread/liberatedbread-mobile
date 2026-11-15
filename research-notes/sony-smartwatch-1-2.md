# Sony SmartWatch 1 (MN2) & SmartWatch 2 (SW2) — Research Notes

Sony's pre-WearOS smartwatches. Manufacturer alive, product line abandoned
(2014), but the whole stack runs locally: Smart Connect host app + extensions,
no account, no cloud.

## Device / Company Status
- **Products**: SmartWatch MN2 (2012, LiveView successor) and SmartWatch 2 SW2
  (2013, 1.6" 220x176 transflective LCD, NFC tap-pairing). SmartWatch 3 (2014)
  switched to Android Wear — out of scope here.
- **Vendor alive**: Sony Group still exists; Sony Mobile even still hosts SW2
  support pages with direct APK downloads
  ([sony.com SW2 software page](https://www.sony.com/electronics/support/other-products-xperia-smart-devices/sw2/software/00279756) — fetched 2026-08-07).
  The SmartWatch line itself is discontinued; Smart Connect is legacy.

## Local Feasibility: CONFIRMED (local stack; no community watch-protocol RE)
- **Transport**: Bluetooth Classic 3.0; phone-side connection via Sony's
  SmartExtensions framework (host app owns the RFCOMM/SPP link to the watch).
- **No cloud**: Smart Connect + watch extensions run entirely on-device. No
  Sony account is involved in pairing, notifications, or running watch apps.
- **Extension SDK was free**: Sony's Add-on SDK (Smart Extension APIs:
  ControlExtension, Notification API, etc.) let third parties write watch apps
  that run locally through Smart Connect; many GitHub samples exist (2013-2015
  era). Watch apps are Android-side code — no watch flashing needed.
- **SW1 community toolchain**: underverk/SmartWatch_Toolchain — open-source
  "Arduino-style" toolchain that compiles native code for the original
  SmartWatch MN2 hardware.
- **Gap**: the low-level watch<->host wire protocol was never fully published;
  nobody has shipped a Gadgetbridge-style replacement host. Driving the watch
  today = install Smart Connect + SW2 host + your extension, all local APKs.

## APK Provenance
- **Packages**: `com.sonymobile.smartconnect` (Smart Connect),
  `com.sonyericsson.extras.smartwatch2` (SW2 host app)
- **Fetchable via apkeep/APKPure: NO** (zero versions listed for both).
- **Official mirror**: Sony still serves SW2-family APKs from its own support
  site (link above) — unusual but handy; otherwise APKCombo-type mirrors.
  Record exact sha256 when archiving.

## Open Questions
- Wire protocol between Smart Connect and SW2 is undocumented — an HCI snoop +
  Smart Connect static pass would enable a Gadgetbridge-style open host
  (greenfield RE opportunity, moderate difficulty).
- Confirm which Android versions the last Smart Connect build still runs on.

## Sources
- sony.com/electronics/support/other-products-xperia-smart-devices/sw2/software/00279756 (official APK hosting, live 2026-08)
- developer.arm.com/community/... "Sony SmartWatch 2 Apps Development" (2013, Smart Connect + Add-on SDK workflow)
- github.com/underverk/SmartWatch_Toolchain (SW1 native toolchain)
- Stack Overflow/XDA SmartWatch 2 extension development threads (2013-2014)
