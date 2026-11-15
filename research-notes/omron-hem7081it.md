# Omron Continua BT Classic Models (HEM-7081-IT / HBF-206IT) — Research Notes

## Product & Company Status
- **Products**: Omron HEM-7081-IT upper-arm BP monitor (export name **708-BT**, HEM-7081-ITE per [dabl index](http://www.dableducational.org/sphygmomanometers/p_devices_2_sbpm_ua.html)) and HBF-206IT / BF206-BT body-composition monitor — Omron's Continua-certified Bluetooth Classic line, announced [2010-02-17 (Omron press release, Japanese)](https://www.omron.com/jp/ja/news/2010/02/h0217.html).
- **Transport**: Bluetooth Classic, **SPP and HDP** (both listed for 708-BT and BF206-BT in the [Theseus thesis device table](https://www.theseus.fi/bitstream/10024/109619/1/Hannula_Kari.pdf)), IEEE 11073 data protocol (Continua).
- **Status**: Long discontinued. Omron Healthcare is alive; the current connected line is BLE with the OMRON connect app. Community tooling ([userx14/omblepy](https://github.com/userx14/omblepy), [eigger/hass-omron](https://github.com/eigger/hass-omron)) covers **BLE models only** — the classic -IT models are a separate, undocumented-by-community gap.
- **Cloud dependency**: **None** in the device data path. (Modern OMRON connect cloud does not apply to these models.)

## Protocol Facts
- HDP path: identical standards story to the A&D Continua devices — IEEE 11073-20601 over Bluetooth HDP/L2CAP, BP specialization 11073-10407, body-composition 11073-10416.
- SPP path: the Theseus table lists SPP support; a [Stack Overflow thread](https://stackoverflow.com/questions/15591637/parsing-raw-data-received-from-bluetooth-hdp-device) shows the 708-BT streaming raw HDP/11073 data to a plain host. Whether the SPP stream is raw 11073 APDUs or an Omron framing is **unconfirmed** — needs capture.
- Agent-initiated connection model (device pushes after measurement), like other Continua agents.

## APK Provenance
- **Not fetched.** Era companion software was Omron's PC health-management suite and the (now-delisted) Omron Wellness app; package id unverified. Nothing blocks RE — standards path is public.

## Local Feasibility Verdict
**Confirmed (transport + standards), hypothesis (SPP framing).** HDP/11073 local capture is guaranteed by Continua certification; open managers (Antidote on BlueZ) should interoperate. SPP byte-level framing TBD.

## Safety
- Clinically validated BP monitor — MEDIUM safety class for automation built on readings.

## Open Questions
- Is the SPP stream raw 11073 APDUs or Omron-proprietary framing? (HCI/SPP capture needed.)
- HBF-206IT body-composition data point coverage (11073-10416 metrics exposed).
- Pairing/discoverability dance vs the A&D agents.
