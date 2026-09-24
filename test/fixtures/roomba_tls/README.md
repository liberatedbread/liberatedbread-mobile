# Roomba TLS test fixtures

Throwaway self-signed certificates for `roomba_tls_pinning_test.dart`, which
proves the trust-on-first-use pinning the vendored spec asks for
(`irobot-roomba.yaml` → `tls.certificate: "self-signed; validate by pinning on
first sight"`) against a real loopback TLS server. The robot's `onBadCertificate`
callback fires on every connection — no public chain exists — and IS the whole
verification, so an in-memory socket fake can never exercise it.

| pair | subject CN | plays |
|---|---|---|
| `robot.*` | `iRobot-ABC123` | the robot itself: pinned on first sight |
| `impostor.*` | `iRobot-ABC123` | a different key at the robot's address — caught by the pin |

The private keys are committed **on purpose**: they secure nothing, exist
only so the test server can present the certificates, identify no real
device (the CN is a made-up BLID), and regenerating them per-run would trade
a deterministic fixture for openssl as a test dependency. Do not reuse them
for anything that is not this test.

Validity is ~100 years (to 2126) so the fixture does not rot. Regenerate
with:

```sh
openssl req -x509 -newkey rsa:2048 -keyout robot.key -out robot.crt \
  -days 36500 -nodes -subj "/CN=iRobot-ABC123"
```

(same for `impostor`).
