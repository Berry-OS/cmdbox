These certificates and private keys are PUBLIC regression-test fixtures.
Use them only with the loopback server in ../wget_compat.py.
They are never installed as trust anchors or used by cmdbox at runtime.

Regenerate with `python3 tests/generate_tls_fixtures.py` (cryptography required
only for regeneration). Normal builds and tests use Python's standard ssl module.
Valid fixtures cover 2024-12-30 through 2124; expired.pem expired in 2024.

Tests cover TLS 1.2/1.3 with RSA/ECDSA, DNS/IP SAN matching, untrusted roots,
expiration, EKU, unknown critical extensions, unsupported constraints, non-CA
issuers and path length constraints.
