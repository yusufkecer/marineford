## 0.1.0-dev

- Dispatch tablosu: arity'ye ozel `invoke0..3`, guard'li hot path, yeniden-giris
  icin `bridgeCall` yonlendirmesi, hata izolasyonu ve otomatik devre disi birakma.
- `MarinefordJson`: derin JSON sarmalama/cozme ve kutulama kurali.
- `PatchStore`: atomik yazma, retention, bozuk state'e karsi dayaniklilik.
- `MarinefordClient`: manifest kontrolu, imza/hash/ABI dogrulama, indirme, aktivasyon,
  crash-loop korumasi, rollback.
- `PatchObserver` olay akisi.
