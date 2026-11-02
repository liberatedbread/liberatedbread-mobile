# Sleep Number / SleepIQ — Research Notes

Checked 2026-10-31. Static analysis of the recovered SleepIQ 5.4.11 app,
cross-checked against the community `ha-adjustable-bed` implementations. No
bed or packet capture was used.

## Two distinct protocols

| Family | Discovery service | Typical scope |
|---|---|---|
| Fuzion | `09d23fae-90e6-44c2-95b6-0b3d0f1abf25` | Climate 360 and related FlexFit generations |
| MCR | `ffffd1fd-388d-938b-344a-939d1f6efee0` | Older pump/foundation controllers |

Detect by advertised/discovered services and capabilities, not model-name
guesses. Existing BLE sessions can control firmness, base, lights and climate
without SleepIQ cloud. Wi-Fi provisioning, accounts, reports and file transfer
are separate paths.

## Fuzion

Auth value `8d4675a5-b5fa-42b2-b587-0ee71c46b709`, transfer information
`e8d06e2a-c987-48f8-93a8-4d18d56b4337`, bulk transfer
`0ec9a5a3-8ac3-4582-92f3-1666421f323d`, and command notification channel
`421e00f3-ae76-4c49-ab6e-39e4df4a5333`.

Initialization order is **bond if needed → read Auth → then notification
setup**. Auth must be a 16-byte session UUID; zero/one sentinels, short values
and ATT authentication failures are not successful sessions. A CCCD write is
not authentication. Bonds are host/adapter-specific.

Text commands use a `fUzIoN` frame with little-endian length and CRC32;
commands have a trailing space when argument-less. Responses can fragment and
must be length/CRC checked before parsing. Useful families include capability
and configuration queries, firmness, actuator targets/positions/motion,
global halt, presets, warming, lighting and climate. Do not expose factory
reset, manufacturing stress tests or cloud diagnostic export.

## MCR

Notify `ffffd1fd-388d-938b-344a-939d1f6efee1`; write
`ffffd1fd-388d-938b-344a-939d1f6efee2`. A client persists a random nonzero
64-bit id and starts with zero header addresses. The bind reply supplies the
16-bit peer/client addresses used later; do not derive them from the Bluetooth
MAC. Weighted integrity, response correlation, fragmentation and separate
pump/foundation layouts are required. Wire-side numbering is right = 0,
left = 1; position values are percentages, not degrees. Capability responses
determine actual chambers and actuators.

## Movement safety and next evidence

Serialize commands and perform the protocol's stop/release cleanup on
cancellation, replacement and failure. Fuzion halt is global, not side
specific. Do not bypass homing, obstruction or actuator faults. Command
acknowledgement is not physical arrival. Keep a person present for motion
tests; no app's pinch/entrapment protections are assumed.

First run one read-only session per family, then a small command vector and
stop/cancel verification before any motion UI. The acquired app and the
community frozen report have different SHA-256 values for the same displayed
version; keep those evidence sources distinct rather than assuming identical
artifacts.
