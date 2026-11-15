# Lutron controllers and scheduling — Research Notes

Consolidated 2026-11-07 from public integration documentation, current client
implementations and static app analysis. No controller was contacted, paired,
reset, scanned or changed.

## Select the protocol before the client

| Controller | Local integration | Important boundary |
|---|---|---|
| Caséta Smart Bridge non-Pro | **LEAP only** | CSR + physical button → client certificate/CA; no LIP Telnet |
| Caséta Smart Bridge PRO | **LEAP and LIP** | LEAP and project/integration IDs need not match |
| RA2 Select main repeater | **LEAP and LIP** | Same split as Caséta PRO; occupancy and device coverage vary |
| RadioRA 2 main repeater | **LIP** | Integration login and project XML; not the Caséta client |
| RadioRA 3 processor | **LEAP only** | Area-based discovery and button-based scenes |
| HomeWorks QS | **LIP** | Not QSX; use the documented LIP integration |
| HomeWorks QSX (HQP7) | **LEAP** | Area-based discovery; QSX confirms LongHold events |
| Vive | Official TLS REST API, plus LEAP on newer software | Official schema requires Lutron approval; do not substitute Caséta |
| Quantum / QS Standalone / myRoom Plus / Athena | LIP variants | Product-specific integration access and capabilities |

The older RadioRA 2 app additionally attempts secure LIP on 8081 and LEAP on
8090, with MQTT remote access. Those app-specific paths do not replace the
standard LIP Telnet 23 or mainstream LEAP 8081 assignments. Confirm the actual
processor rather than scanning broadly or selecting by app name.

## LEAP transport and pairing

LEAP is newline-delimited JSON over mutually authenticated TLS, normally TCP
8081. It is not an ordinary HTTP request or a required WebSocket handshake.
`CommuniqueType` names the operation, `Header.ClientTag` correlates replies,
`Header.Url` selects the resource, and `Header.Paging` handles large reads.
Ping `/server/1/status/ping`; reconnects must refresh state and re-subscribe.

Discovery normally uses `_lutron._tcp.local.` with `MACADDR`, `CODEVER`,
`SYSTYPE` and `SERNUM`. Its SRV port may be SSH 22, not LEAP. `_leap._tcp` on
8081 and `_lap._tcp` on 8083 also exist. Older RadioRA 2 discovery uses
multicast 224.0.37.42 UDP 2647 with `<LUTRON=1>`/`<LUTRON=2>`; `TELPORT` is
hexadecimal.

Pairing is CSR-based, not a password:

1. Generate a private key and CSR on the client.
2. Open the TLS pairing channel on 8083 using the initial LAP credentials.
3. Wait for `PhysicalAccess` while the bridge button is held.
4. Execute `/pair` with `CommandType: CSR`, the PEM CSR, display name, device
   UID and role.
5. Store the returned client certificate and root CA, then verify LEAP on 8081.

Never publish generated private keys, client certificates, bridge CAs, LAP
credentials, embedded SSH keys, owner integration logins or project XML.
RA3/QSX can fall back to the Lutron root CA during pairing. A network reset is
not a shortcut around physical pairing.

## LEAP resources and commands

Read configuration dynamically from `/device`, `/zone`, `/area`, `/button`,
`/occupancygroup` and `/virtualbutton`. Caséta is primarily device/zone based;
RA3/QSX uses areas and associated zones. Keep separate LEAP and LIP ID maps.

Commands target `/zone/{id}/commandprocessor` inside `Body.Command`. Current
app commands include `GoToDimmedLevel`, `GoToSwitchedLevel`, shade/tilt
actions, Raise/Lower/Stop, `GoToFanSpeed` and scene/button actions. Third-party
`GoToLevel` is a compatibility command, not the current vendor enum definition;
no generic `SetLevel` was found.

Keypad subscriptions can carry press/release/multi-tap on supported hardware;
`LongHold` is currently confirmed for QSX, not Caséta or RA3. RA3/QSX scenes
are activated through buttons. `OpenCloseStop` cover zones can have unknown
position and no direction/level in notifications; do not invent one.

## Timeclock scheduling

Events persist on the controller and run without the phone. Useful LEAP routes:

- read `/timeclock`, `/timeclock/status`, and per-clock/event collections;
- create with `CreateRequest /timeclock/{id}/timeclockevent`;
- update with `UpdateRequest /timeclockevent/{eventId}`;
- delete with the corresponding `DeleteRequest`;
- enable/disable through the existing event's status, not deletion;
- test through the event's command processor with `TestThisTimeclockEvent`.

The event model carries `Parent`, `Name`, `ProgrammingModel`, `ScheduleType`
(`DayOfWeek`, `ByDate`, `Daily` or `None`), begin/end dates, weekly booleans,
`TimeOfDay`, optional solar event/offset and recurrence/exception dates. Use
`ByDate` for a specific date. Read back the assigned event href and scope
later edits to it. Solar offset is normally ±4 hours, or ±12 only when the
feature flag allows it. Preserve the controller timezone.

Create an app event first, read it, then make the smallest necessary change:
enable/disable, execute or update. Validate read-back, WAN-off firing and DST
behavior before relying on a third-party event.

## LIP essentials

Public Lutron Integration Protocol guide **040249 revision AH** defines
comma-separated ASCII terminated by CRLF: `#` control, `?` query, `~` monitor.
Integration IDs come from the project integration report, not a universal
model table. `#OUTPUT` drives outputs, `#DEVICE` drives keypad/button inputs,
`#TIMECLOCK` handles scheduling, and `#MONITORING` selects unsolicited events.

Useful timeclock actions are mode 1, sunrise 2, sunset 3, day schedule 4,
execute event 5 (first index 1), and enable/disable event 6 (1 enable, 2
disable). App-side tweak commands prove authoring exists but are not a stable
public third-party API; use the app/Designer for full authoring. The public
guide gives 100 ms minimum control-command spacing and 1500 ms for queries,
not a universal maximum rate.

## Reset, radios and firmware

A 20-second Smart Hub rear-button hold is a **network reset**, not a factory
wipe: paired devices, scenes and schedules survive. A 40-second hold is a
HomeKit reset. External integration credentials may need reissuance.

Clear Connect Type A uses 431–437 MHz in North America and is not Zigbee,
Z-Wave or Wi-Fi. RA3 also uses Clear Connect Type X at 2.4 GHz for compatible
newer devices, with different mesh/spacing rules. Pico-to-dimmer pairing works
without a bridge for manual control.

Seven official Caséta packages through 26.00.13f000 are retained in the
research store. Their `firmware.tar.enc` payloads are encrypted with
per-package keys, and unwrapping requires the processor's private key; no
 decrypted rootfs was obtained. The 26.00.14/15 paths returned 404 when
checked. Do not install a package for research.

## Remaining hardware checks

- Actual service/port set per processor, especially LIP 23, secure LIP 8081
  and app-specific LEAP 8090.
- Third-party timeclock read-back, WAN-off execution and DST/solar behavior.
- RA3/QSX event coverage for each keypad, shade and OpenCloseStop zone.
- Vive's approved API schema and version-specific LEAP equivalence.
- Owner-authorized private-key/rootfs access for firmware analysis.
