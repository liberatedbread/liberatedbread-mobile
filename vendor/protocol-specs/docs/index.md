# Liberated Bread Protocol Documentation

> Own your devices, don't let them own you.

Welcome to the Liberated Bread protocol documentation -- where we figure out how your IoT
devices actually work so they can keep working after the manufacturer has moved on.

## The Mission

IoT companies come and go, but your hardware shouldn't have to go with them. This
documentation project is dedicated to reverse engineering the communication protocols
of abandoned IoT devices so the community can build open replacements for proprietary
apps and cloud services.

!!! warning "Use caution, especially for anything safety-critical"
    These documents are reverse-engineered from the outside, mostly unverified
    on hardware, and maintained in spare time. Use them to keep your own
    gadgets useful, and treat every value and command they describe with care:
    check against the device's own display and manual where you can. Where
    being wrong could hurt someone, do not rely on them at all. A glucose
    reading that reaches you through one of these specs is fine for seeing
    which breakfast spikes you and unfit for deciding an insulin dose; the
    same holds for blood-pressure and SpO2 readings (a personal log, not a
    clinical one), gas alarms (the buzzer is the safety device, not a
    notification), motorised doors and anything on wheels. Specs for such
    devices carry a `safety_advisory` that says so again where a client will
    show it.

## Getting Started

New to IoT reverse engineering? Start with our [methodology guide](getting-started/methodology.md)
and check out the [recommended tools](getting-started/tools.md).

## Device Registry

Browse our [device registry](devices/index.md) to see what's been documented so far.

Already running Home Assistant or another local controller? The
[keeping devices alive](keeping-devices-alive.md) guide maps every documented
device family to its realistic keep-alive path — local API, cloud redirection,
replacement firmware, or BLE — with an honest list of the dead ends.

## Contributing

Found an abandoned device? Check our [contribution guide](contributing/index.md)
and use the [device documentation template](devices/_template.md) to get started.

Every device saved from the e-waste pile is a small victory.
