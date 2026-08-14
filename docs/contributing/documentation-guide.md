# Documentation Guide

## Using the Device Template

Copy `docs/devices/_template.md` and fill in each section.

### Tips

- Be specific about byte offsets and lengths
- Use hex notation: `0x01`, `0xFF`
- Include both request and response formats
- Document error responses too
- Screenshots of nRF Connect are very helpful

### Don't skip the setup section

Control protocols get documented; onboarding usually does not, and it is the
half that strands a device when a router is replaced or a cloud is retired.
Record how the device is provisioned, how it is factory reset, and whether it
can be moved to a new network without one — plus an honest confidence level.
"The onboarding exchange has not been captured" is useful; silence is
indistinguishable from "there is nothing to document". See
[Initial Device Setup](../protocols/device-setup.md) for the patterns, and
[Reading a Device Spec](../api/spec-format.md) for the YAML fields.

If the device onboards through a vendor cloud that still exists, capturing that
exchange is the highest-value thing you can do, because it is the one capture
you cannot go back for.

## Building Docs Locally

```bash
pip install -r requirements.txt
mkdocs serve
```

Preview at http://localhost:8000
