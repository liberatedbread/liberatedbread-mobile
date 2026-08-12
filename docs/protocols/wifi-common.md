# Common WiFi Patterns

## Getting on the network first

Everything below assumes the device already has WiFi credentials. Handing them
over is its own protocol problem — usually a temporary access point hosted by
the device, sometimes a BLE side-channel, occasionally nothing but the vendor
cloud. See [Initial Device Setup](device-setup.md) for the onboarding models,
the SoftAP flow, factory reset procedures, and how to move a device to a new
network.

Two practical notes that shape everything else:

- Nearly every device documented here has a **2.4 GHz-only** radio. A
  band-steering router advertising one SSID on both bands is the most common
  cause of an onboarding failure, and it usually presents as a wrong-passphrase
  error.
- A device that cannot be re-onboarded locally is not rescued, however well its
  control protocol is documented.

## Local HTTP API

Many WiFi IoT devices run a local HTTP server.

### Discovery
- **mDNS/Bonjour**: `_http._tcp` or custom service type
- **SSDP/UPnP**: Less common in newer devices, but the basis of Wemo and Roku

Never treat an IP address as device identity — it is a connection detail that
changes with every DHCP lease. Match on serial, MAC, UDN or a TXT record. See
[WiFi Discovery](../devices/wifi-discovery.md).

### API Patterns

Most local APIs use REST-ish JSON:

```http
GET /api/status
POST /api/control {"command": "set_brightness", "value": 50}
```

## Cloud API Relay

When the cloud server dies, control dies too. General replacement strategy:
1. Capture cloud communication
2. Set up local server mimicking cloud API
3. Redirect device via DNS override or firmware mod
