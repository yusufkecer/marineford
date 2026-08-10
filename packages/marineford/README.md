# marineford

The Flutter runtime for [marineford](https://github.com/) code push.

See the [repository README](../../README.md) for what this is, what it costs,
and the one constraint to understand before adopting it.

```dart
await Marineford.init(MarinefordConfig(
  appId: 'com.example.app',
  appVersion: Version.parse('1.4.0'),
  abi: kMarinefordAbi,
  manifestUrl: Uri.parse('https://cdn.example.com/prod/manifest.json'),
  publicKey: kMarinefordPublicKey,
));
unawaited(Marineford.checkForUpdate());
```

`init` reads two small files and, when a patch is already installed, builds a
dart_eval runtime — about a millisecond, which is why it is safe to await before
`runApp`. With no patch installed it does neither.
