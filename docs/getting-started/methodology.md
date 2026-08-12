# Reverse Engineering Methodology

A systematic approach to figuring out how your abandoned IoT device communicates.

## Step 1: Open Source Intelligence (OSINT)

Before touching any tools:

- **FCC filings** -- Search for radio details and internal photos
- **Teardowns** -- Check iFixit, YouTube, and forums
- **App store** -- Download the (possibly defunct) official app
- **Forums** -- Reddit, Home Assistant community, device-specific forums
- **GitHub** -- Someone may have already started RE

## Step 2: Traffic Capture

### For BLE Devices
1. Install nRF Connect on your phone
2. Scan and identify your device
3. Browse GATT services and characteristics
4. Enable Android HCI snoop log
5. Use the original app while capturing
6. Analyze the capture in Wireshark

### For WiFi Devices
1. Set up mitmproxy or Charles Proxy
2. Configure the device to use your proxy
3. Perform actions with the original app
4. Record all API calls and responses

## Step 3: Protocol Analysis

- Identify command structure (headers, opcodes, payload, checksums)
- Map actions to protocol messages
- Test hypotheses by replaying/modifying messages

## Step 4: Documentation

Use our [device template](../devices/_template.md) to write up your findings.
Even partial documentation is valuable.
