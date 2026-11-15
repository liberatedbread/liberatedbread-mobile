# TP-Link scheduling — Kasa, Tapo and Deco

Research consolidated 2026-11-07 from current released libraries, app
analysis and vendor documentation. No device was contacted and no schedule
was created, edited or executed.

## Programming is not execution

Single-device clock rules, countdowns and Away Mode are stored on the device
and normally run without the phone. Creating or editing them still requires
the vendor app or an authenticated local client. Multi-device Smart Actions
are a different mechanism: TP-Link explicitly says they require Internet.

| Mechanism | Meaning |
|---|---|
| Schedule | On/off at clock or solar time, weekly or next occurrence |
| Timer / countdown | One action after a duration; Tapo replaces its armed timer when set again |
| Auto-Off Timer | Off after a duration every time the plug turns on; not the same as countdown |
| Away Mode | Random on/off behavior in a time window; legacy Kasa uses `anti_theft` |
| Automation / Smart Actions | Multiple devices/actions; cloud-dependent |
| Deco schedules | Wi-Fi, LED, eco/power and IoT tasks on the authenticated controller |

Read device info, time/timezone, existing rules and capacity first. Create one
harmless rule on an owner-controlled noncritical load, read back its assigned
ID, and scope all later edits/deletes to it. Enable the rule and overall
service separately. Verify WAN-off behavior and DST/solar handling before
relying on it; never factory-reset merely to test offline execution.

## Tapo plugs

The released Python **`tapo` 0.12.2** package now contains the schedule API;
older local notes calling it unreleased are stale. Its `ScheduleRule` builders
cover `clock_once`, `clock_weekly`, `sunrise_once/weekly` and
`sunset_once/weekly`. `clock_once` means next occurrence of a wall-clock time,
not an arbitrary calendar-date scheduler.

Methods include add/edit/get/remove schedule rules, countdown rules and
capacity queries. Convenience wrappers `set_timer` and `clear_timer` use
countdown-rule calls; `get_max_schedule_rules` reads
`schedule_rule_max_count`, not a new wire method. A P110 is documented upstream
as holding 32 rules, not a universal limit. Named errors include full `-1802`,
conflict `-1803` and index `-1805`.

Wire fields:

- `s_min`: minutes after midnight;
- `s_type`: `normal`, `sunrise`, `sunset`;
- `time_offset`: signed solar minutes (library accepts ±360; a P110 rejected
  values beyond ±6 hours, so check the model);
- `week_day`: bit 0 Sunday through bit 6 Saturday;
- `mode`: `once` or `repeat`;
- `desired_states.on`: target state; older firmware can use `s_action`;
- `id`: assigned by device, omitted on add and required on edit;
- placeholder `year/month/day`: `1970-01-01` in the library's P110 builder.

Do not infer a general calendar-date API from those placeholder fields.
Negative solar offsets fire before the event. Countdown `set_timer` accepts 1
second through 24 hours and clears/replaces the old armed timer.

## Legacy Kasa

Local modules are `schedule`, `count_down`, `anti_theft` and `time`. They
support rule get/add/edit/delete, `get_next_action`, `set_overall_enable`,
countdowns, randomized away mode and clock/timezone operations. The current
`kasa` CLI uses `kasa command`; `raw-command` is deprecated. Bulbs can use the
full `smartlife.iot.common.schedule` module rather than the short plug name.

A daily off-at-23:30 rule uses `smin: 1410`, `sact: 0`, `stime_opt: 0`,
`repeat: 1`, seven `wday` flags set, and unused end fields disabled. Send no
`id` on add. An edit sends the complete rule including its existing ID, not a
partial flag patch. A five-minute off countdown uses `delay: 300`, `act: 0`.

Bulb rules can include `s_light` (state, mode, color, temperature, brightness
and transition); dimmer-switch rules can include `s_dimmer`. These are
model-specific and do not belong on a plain relay plug. Use an app-created
lighting rule as the template.

Timezone behavior differs by ecosystem. Legacy Kasa exposes time/timezone
methods on capable models, so use those instead of resetting. Tapo's current
FAQ generally requires reset/reconfiguration to change a learned timezone,
except specific local/Bluetooth year-mismatch handling. Do not apply either
statement to the other ecosystem.

## Deco

All writes require the authenticated controller protocol. Do not apply the
plug rule schema to a router.

- `/admin/wireless?form=wifi_schedule`: Wi-Fi off time and band enable;
  affects host, guest and IoT networks and is absent on some models.
- `/admin/eco_mode?form=eco_mode`: power mode and schedule windows; EU support
  note, mixed-model networks can hide it, v1/v2 schemas differ.
- `/admin/device?form=led`: LED night mode; does not disable Wi-Fi.
- `/admin/iot_automation?form=iotautomation`: tasks, triggers and action lists.
- `/admin/iot_automation?form=iotoneclick`: on-demand scenes, not themselves
  clock schedules.
- `/admin/camera_security?form=camera_security_blocked_period`: blocks network
  access, not camera recording.

Read an app-created task before writing. `task_mode`, `from_time`, `to_time`,
`repeat_time`, `is_enable`, `trigger_list` and `action_list` are recovered
fields, not a universal encoding for every action. Controller-local
persistence does not prove end-to-end offline execution for a cloud-linked
target. Eco, LED and Wi-Fi schedulers can share storage, so read back after
every change.

## Evidence still needed

Per-model capacities and solar limits, arbitrary-date behavior, actual offline
firing after programming, DST transitions, and Deco action behavior when the
target is cloud-linked. Upstream hardware observations remain attributed to
their authors; they were not reproduced in this pass.
