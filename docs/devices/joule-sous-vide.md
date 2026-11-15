# ChefSteps Joule Sous Vide

> **Status**: Spec Available (untested)
> **Protocol**: BLE GATT; optional vendor-cloud Wi-Fi
> **Manufacturer**: Breville, formerly ChefSteps (active)

## Safety

Joule is an 1100 W immersion heater and the protocol can start a cook at up to
98 °C at sea level. Use it only with the vessel, water level and food prepared
as the manual requires, with someone able to stop it. Keep stop-cooking one
command away in any client. Read the device's limits instead of assuming the
98 °C ceiling applies to every unit. On UL-listed hardware, a cook above
85 °C additionally requires a physical top-button press.

## Overview

This spec covers the original CS10001 stainless and CS20001 white Joule, not
the later Joule Turbo. It includes the app-layer key exchange, request and
response envelopes, live-feed messages, temperature and timer commands,
Wi-Fi provisioning, firmware references and safety limits:
`device-specs/devices/joule-sous-vide.yaml`.

The BLE path can run locally without the vendor cloud. Wi-Fi is for the
vendor app's remote/cloud functions, not a prerequisite for local BLE
control. Nothing here has been run against hardware by this project.

## Pairing and local setup

Do not pair from the phone's ordinary Bluetooth settings. Joule uses an
application-layer credential instead:

1. Plug in Joule and connect to the advertiser with service
   `700b4321-9836-4383-a2b2-31a9098d1473` (or company ID `0x0159`).
2. Subscribe to `700b4325-9836-4383-a2b2-31a9098d1473` and wait about
   500 ms.
3. Send `start_key_exchange` to
   `700b4322-9836-4383-a2b2-31a9098d1473`.
4. While the LED blinks white, press the button on top of Joule. The vendor
   flow allows about 35 seconds for this.
5. On the doorbell notification, read the reply from
   `700b4323-9836-4383-a2b2-31a9098d1473` and store the returned secret key
   as a credential, never in public notes or logs.
6. Present that key with `submit_key` on this and later connections. Only
   then send identification, limits and live-feed requests.

The key is per device and is not a Bluetooth PIN. A factory reset invalidates
it.

## Factory reset and rebinding

The vendor documents this procedure; it has not been tried here:

1. Unplug Joule and reconnect power.
2. Immediately hold the top button for at least 15 seconds (older vendor text
   says 10) until the LED blinks yellow.
3. Wait for the reset to finish and the LED to return to steady white.

Reset removes the name, Wi-Fi settings and authentication/ownership data.
Pair again to obtain a new key.

To change routers without resetting, authorize over BLE, send
`disconnect_wifi`, then provision the replacement network with
`connect-Wi-Fi`. Newer firmware can retain multiple Wi-Fi profiles. Only the
owning vendor account can configure Wi-Fi through the vendor app.

## Protocol summary

BLE requests use a small envelope followed by a length-delimited protobuf
body; replies are correlated by handle through the read/doorbell pair. The
YAML declares the envelope, oneof choices, fixed-width and varint fields,
floating-point temperature representation, scaling, limits and worked
vectors. Do not send a numeric Celsius value as an integer: temperature
setpoints use their IEEE 754 binary32 bit pattern in little-endian order.

## References

- [Joule CS10001 / CS20001 instruction book](https://www.breville.com/content/dam/breville/us/assets/miscellaneous/instruction-manual/sous-vide/CS10001-instruction-manual.pdf)
- [ChefSteps: factory reset](https://support.chefsteps.com/hc/en-us/articles/222979667-What-is-a-factory-reset-and-how-do-I-perform-one)
- [ChefSteps: LED colours and patterns](https://support.chefsteps.com/hc/en-us/articles/223021708-Why-is-the-LED-on-my-Joule-blinking-and-what-does-the-light-color-mean)
- [ChefSteps: Bluetooth-only pairing](https://support.chefsteps.com/hc/en-us/articles/36606559991319-Pairing-ChefSteps-Joule-to-the-Breville-app-using-Bluetooth-only)
- [ChefSteps: temperature limits](https://support.chefsteps.com/hc/en-us/articles/214790827-What-is-the-minimum-maximum-temperatures-that-can-be-set-for-Joule)
