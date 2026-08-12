# Hue TLS test fixtures

Throwaway self-signed certificates for `hub_http_client_tls_test.dart`, which
proves the trust-on-first-use pinning against a real loopback TLS server —
`MockClient` never touches `dart:io`, so the `badCertificateCallback` path
(the entire trust decision on a Hue bridge) is untestable without these.

| pair | subject CN | plays |
|---|---|---|
| `bridge.*` | `001788fffeaabbcc` | the bridge itself: right CN, gets pinned |
| `impostor.*` | `001788fffeaabbcc` | a different device wearing the right CN — caught by the pin, not the CN |
| `wrongcn.*` | `deadbeefdeadbeef` | a device that is not the bridge at all — caught by the CN on first contact |

The private keys are committed **on purpose**: they secure nothing, exist
only so the test server can present the certificates, identify no real
device (the CN is the spec's own documentation-example bridgeid), and
regenerating them per-run would trade a deterministic fixture for openssl as
a test dependency. Do not reuse them for anything that is not this test.

Validity is ~100 years (to 2126) so the fixture does not rot. Regenerate
with:

```sh
openssl req -x509 -newkey rsa:2048 -keyout bridge.key -out bridge.crt \
  -days 36500 -nodes -subj "/CN=001788fffeaabbcc"
```

(same for `impostor`; `wrongcn` uses `/CN=deadbeefdeadbeef`).
