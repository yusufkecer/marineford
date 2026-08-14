## 0.1.0

First release. The rules both the device and the publisher check, in one place
so they cannot disagree.

- `PatchManifest` and `PatchEntry`, with a defensive JSON parse.
- The `.mfp` patch container: framing, and a flag it does not recognise is
  refused rather than ignored.
- Ed25519 signing and verification (`PatchSigner`, `PatchVerifier`).
- Patch selection: ABI match, version constraint, revocation, local blocklist,
  downgrade protection, staged rollout — as one pure function, so the CLI can
  answer "what would devices do" without guessing.
- Deterministic rollout bucketing (`rolloutBucket`, `isInRollout`).
