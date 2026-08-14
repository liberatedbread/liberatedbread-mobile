# iRobot Create 3 — Research Notes

## What it is
iRobot's education/developer robot (2022), built on the Roomba i3 platform
without vacuum hardware: LIDAR-less mobile base with optical flow, IR cliff
and wheel sensors, IMU, buttons/light ring, USB-C host port, cargo bay.
Sold by iRobot Education (~$300). It is the rare case where the local API
is vendor-documented and cloud-free by design.

## Local interfaces (all documented at iroboteducation.github.io/create3_docs)
- **ROS 2 over Wi-Fi**: the robot runs a ROS 2 graph (DDS; Fast-DDS or
  CycloneDDS selectable). Any LAN machine with matching ROS 2 distro +
  domain ID can subscribe to sensors and publish `cmd_vel`. Custom
  interfaces in `irobot_create_msgs` (dock/undock actions, drive
  arc/straight, LED control, audio).
- **Built-in webserver**: configuration UI (ROS 2 domain, RMW, namespace),
  firmware update upload, logs — served on the robot's IP and on the
  USB-C connection.
- **USB-C wired Ethernet**: RNDIS/CDC-ECM; robot is at 192.168.186.2 — a
  fully network-local path that works with zero Wi-Fi provisioning.
- Bluetooth LE exists only for the (optional) setup app; not needed.

## What needs cloud
Nothing. No account exists in the Create 3 workflow; firmware images are
public downloads flashed via the local webserver. Company status note:
iRobot exited Chapter 11 under Picea ownership 2026-01-23; Create 3 docs
remain hosted (iroboteducation.github.io) as of 2026-08-07 — mirror the
docs/firmware if building long-term infrastructure.

## APK
None needed — the setup app is optional; everything works from the
webserver and ROS 2.

## Open questions
1. HTTP endpoints of the webserver beyond the documented pages are thinly
   documented — a short probe of 192.168.186.2 would fill out a REST spec.
2. Post-acquisition firmware hosting continuity (Picea era).
