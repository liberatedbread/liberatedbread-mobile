# Staples Connect Hub — Research Notes (REJECTED)

## What it is
Retail smart-home hub (D-Link-built hardware, Zonoff software platform),
sold 2013–2016 with Z-Wave/Zigbee/Lutron support.

## Timeline (verified)
- Staples exited 2016-06, handed support to Z-Wave Products Inc + Zonoff
  ([Zatz Not Funny 2016-06-06](https://zatznotfunny.com/2016-06/staples-pulls-plug-smart-home/),
  [Retail Dive 2016-08-04](https://www.retaildive.com/news/staples-replacing-connect-with-third-party-smart-home-system/423867/)).
- Service effectively dead by 2018-02 ([SlashGear 2018-02-26](https://www.slashgear.com/staples-connect-hub-is-dead-as-iot-graveyard-grows-26521126/)).

## Verdict: dud
The hub cached automations locally, so schedules survived internet outages
([CNET review 2015-03-06](https://www.cnet.com/reviews/staples-connect-hub-d-link-edition-review/)),
but all configuration and app control went through the Zonoff cloud. No
local API was ever documented or reverse-engineered; with the service dead
there is no known way to provision or control the hub. Cloud-dependence with
no documented local path — rejected.

## Residual value
Paired Z-Wave/Zigbee *devices* are standard slaves and can be excluded and
re-paired to any modern hub; the hub itself is e-waste.
