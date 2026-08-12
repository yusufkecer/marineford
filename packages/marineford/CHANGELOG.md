## 0.1.0-dev

- Dispatch tablosu: arity'ye ozel `invoke0..3`, guard'li hot path, yeniden-giris
  icin `bridgeCall` yonlendirmesi, hata izolasyonu ve otomatik devre disi birakma.
- `MarinefordJson`: derin JSON sarmalama/cozme ve kutulama kurali.
- `PatchStore`: atomik yazma, retention, bozuk state'e karsi dayaniklilik.
- `MarinefordClient`: manifest kontrolu, imza/hash/ABI dogrulama, indirme, aktivasyon,
  crash-loop korumasi, rollback.
- `PatchObserver` olay akisi.

## Unreleased

- `@patchable` and `@PatchableService` moved here from `marineford_annotation`,
  which is gone. Anything marking a function already depends on this package —
  the generated shim calls `Patch` and `MarinefordJson` — so the separate
  package cost an import in every marked file and bought nothing. The patch-side
  `@RuntimeOverride` is deliberately *not* exported: a patch is compiled by
  dart_eval from source the CLI collects, so importing it could never work.
