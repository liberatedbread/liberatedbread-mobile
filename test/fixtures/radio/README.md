<!-- Copyright 2026 Pigs Can Fly Labs LLC
     SPDX-License-Identifier: Apache-2.0 -->

# Radio source fixtures

Synthetic responses in the shape the real services answer with. Written by
hand rather than captured, so no third party's directory data is vendored
here — the point of a fixture is the shape, and the shape is what these pin.

The shapes were confirmed against the live services on 2026-08-28:

- **myGMRS** (`https://api.mygmrs.com/repeaters?state=XX`, anonymous):
  `{"success": true, "info": {"total": N}, "items": [...]}`. Each item carries
  `Frequency` as a **string in MHz**, numeric `Latitude`/`Longitude`, and
  `Name`, `Location`, `Type`, `Owner`, `Status`. There is **no tone field of
  any kind**, which is why every listing the client builds says the tone is
  unpublished.
- **RepeaterBook** (`https://www.repeaterbook.com/api/export.php?state_id=NN`):
  refuses without an `X-RB-App-Token` header. Confirmed error bodies:
  - no header, or a header it does not know →
    `{"ok": false, "error_code": "auth_missing", "message": "Authorization required."}`
  - a header whose value is not token-shaped →
    `auth_invalid` / `"Invalid token header format."`
  - a value with the user-token prefix but the wrong shape →
    `auth_invalid` / `"Invalid user app token format."`

  The **success** shape could not be confirmed — it needs a token, which is
  requested from a logged-in RepeaterBook account. `repeaterbook_ct.json` is
  therefore written from their published column names, and the client's parser
  is deliberately tolerant of which wrapper key the rows arrive under and of
  the spelling of each column. When someone runs this against a real token,
  check the fixture against what actually comes back.
