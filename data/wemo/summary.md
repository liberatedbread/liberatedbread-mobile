# Wemo APK Static Analysis Summary

**APK**: `com.belkin.wemoandroid.apk`
**Source**: APKpure (fetched via apkeep)
**Status**: Downloaded and decoded (apktool)

## APK Overview

- **Package**: `com.belkin.wemoandroid`
- **Architecture**: Hybrid web/native — WebView-based widget system with JavaScript bridges to native Android code
- **Key directories**: `smali/`, `kotlin/`, `assets/www/widgets/`, `assets/www/js/`
- **Widget count**: 32 widget directories under `assets/www/widgets/`

## Device Type Discovery

The APK's widget mock data (`widgets/*/mocks/device.json`) reveals 16+ distinct Wemo device types, each with a unique UPnP `deviceType` URN:

### Core Smart Plugs & Switches
| Widget Dir | deviceType URN | friendlyName | Notes |
|---|---|---|---|
| `wemo_mini` | `urn:Belkin:device:socket:1` | WeMo Switch | Mini Smart Plug (F7C063) — uses socket:1 URN in mock |
| `wemo_socket` | `urn:Belkin:device:socket:1` | WeMo Switch | Generic socket |
| `wemo_smart_plug` | `urn:Belkin:device:socket:1` | WeMo Smart Plug | Smart Plug V2 (WSP080) |
| `bundlemanager` | `urn:Belkin:device:controllee:1` | WeMo ec3 | Bundle device — uses controllee:1 |

### Specialty Electrical
| Widget Dir | deviceType URN | friendlyName | Notes |
|---|---|---|---|
| `wemo_outdoorplug` | `urn:Belkin:device:outdoor:1` | Wemo Outdoor Plug | Dual-outlet outdoor plug |
| `wemo_insight` | *(no mock file)* | — | Energy monitoring — separate widget but no mock data |

### Lighting
| Widget Dir | deviceType URN | friendlyName | Notes |
|---|---|---|---|
| `wemo_lightswitch` | `urn:Belkin:device:Lightswitch:1` | WeMo Light Switch | 1st generation |
| `wemo_lightswitch_2gen` | `urn:Belkin:device:Lightswitch:1` | WeMo Light Switch | 2nd generation |
| `wemo_lightswitch3way` | `urn:Belkin:device:Lightswitch:1` | WeMo Light Switch | 3-way version |
| `wemo_dimmer` | `urn:Belkin:device:socket:1` | WeMo Switch | Dimmer — mock uses socket:1 URN; real devices may use dimmer:1 |
| `wemo_dimmer_v2` | `urn:Belkin:device:socket:1` | WeMo Switch | Dimmer V2 — same socket:1 mock pattern |
| `wemo_lighting` | `urn:Belkin:device:bridge:1` | Bulb 01 | Wemo Bridge — controls Link smart bulbs |
| `wemo_dimmer_calibration` | *(no mock)* | — | Dimmer calibration widget |

### Sensors & Maker
| Widget Dir | deviceType URN | friendlyName | Notes |
|---|---|---|---|
| `wemo_maker` | `urn:Belkin:device:Maker:1` | WeMo Motion | Maker — relay/sensor I/O device |
| `wemo_sensor` | `urn:Belkin:device:motion:1` | WeMo Motion | Motion sensor |

### Kitchen Appliances
| Widget Dir | deviceType URN | friendlyName | Notes |
|---|---|---|---|
| `wemo_coffeemaker` | `urn:Belkin:device:coffeemaker:1` | Mr. Coffee® Brewer | Mr. Coffee Smart WeMo Coffeemaker |
| `wemo_crockpot` | `urn:Belkin:device:crockpot:1` | Crock-Pot® Slow Cooker | Crock-Pot Smart Slow Cooker |

### Environmental Appliances
| Widget Dir | deviceType URN | friendlyName | Notes |
|---|---|---|---|
| `wemo_heatera` | `urn:Belkin:device:heater:1` | Holmes® Heater | Holmes Smart Heater |
| `wemo_airpurifier` | `urn:Belkin:device:purifier:1` | Holmes® Air Purifier | Holmes Smart Air Purifier |
| `wemo_humidifier` | `urn:Belkin:device:humidifier:1` | Holmes® Humidifier | Holmes Smart Humidifier |
| `wemo_humidifierb` | `urn:Belkin:device:humidifierb:1` | Holmes® Humidifier | Humidifier variant B |

### Infrastructure Widgets (no mock device data)
| Widget Dir | Purpose |
|---|---|
| `wemo_setup` | WiFi provisioning / device setup flow |
| `wemo_setup_slides` | Setup wizard slide content |
| `wemo_devices` | Device list/dashboard |
| `wemo_group` | Device grouping (multi-plug control) |
| `wemo_account_settings` | Account/settings UI |
| `wemo_auth` | Authentication flow |
| `wemo_partners` | Partner device integrations |
| `bundlemanager` | Multi-device bundle management |

## Key Observations

1. **Dimmer mock ambiguity**: Both `wemo_dimmer` and `wemo_dimmer_v2` mocks use `urn:Belkin:device:socket:1` — not `dimmer:1`. This is likely because the mock templates reuse the socket's device.json for development purposes. The pywemo library references `urn:Belkin:device:dimmer:1` for real dimmer hardware. The dimmer widgets have separate HTML/JS for dimmer-specific UI (brightness slider, calibration).

2. **controllee:1 vs. socket:1**: The `bundlemanager` widget uses `controllee:1` while `wemo_mini` uses `socket:1`, suggesting the Mini plug identifies as both depending on firmware revision or firmware mode.

3. **All share SSDP + SOAP**: Despite the URN differences, every device type shares the same UPnP discovery and SOAP 1.1 control architecture. The `basicevent` service (on/off) is universal.

4. **Device-specific services**: Insight (energy), Dimmer (brightness), Maker (sensor I/O), and environmental devices have additional SOAP services beyond `basicevent`, `metainfo`, and `timesync`.

## Cloud Endpoints (reference only)

The APK references these cloud endpoints — documented for avoidance (local control does not use them):

| Endpoint | Port | Purpose |
|---|---|---|
| `api.xwemo.com` | 8443 | Wemo cloud API |
| `appapis.xwemo.com` | 8443 | App cloud API |
| `productionwemoandroidpn.firebaseio.com` | 443 | Firebase push notifications |
| AWS IoT endpoint (varies) | 8883 | MQTT cloud bridge |

## Analysis To-Do

- [x] Catalog device types from widget mocks
- [x] Map deviceType URNs to widget directories
- [ ] Search smali for SOAP service URNs and action names
- [ ] Extract WiFi provisioning flow (GetApList, ConnectHomeNetwork) from smali
- [ ] Map widget JavaScript to SOAP action dispatch for device-specific features
- [ ] Extract APK version code from AndroidManifest.xml
- [ ] Record APK hashes (SHA-256)
