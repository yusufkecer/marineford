## 0.1.0-dev

- Manifest modeli ve savunmacı JSON parse (`PatchManifest`, `PatchEntry`).
- `.mfp` patch konteyneri: framing, ileri uyumluluk için flag reddi.
- Ed25519 imza doğrulama ve imzalama (`PatchVerifier`, `PatchSigner`).
- Patch seçim algoritması: ABI eşleşmesi, sürüm kısıtı, revoke, yerel
  blocklist, downgrade koruması, kademeli rollout.
- Deterministik rollout kovası (`rolloutBucket`, `isInRollout`).
