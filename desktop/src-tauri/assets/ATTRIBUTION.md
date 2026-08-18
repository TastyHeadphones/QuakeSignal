# QuakeSignal desktop alert-audio provenance

`quakesignal_japanese_voice.wav` is a lossless FFmpeg WAVE conversion of the
reviewed iOS asset
`ios/QuakeSignal/Resources/Audio/quakesignal_japanese_voice.caf`.
It contains QuakeSignal's original Japanese safety message:

> 地震情報です。強い揺れに備え、身の安全を確保してください。

English meaning: “Earthquake information. Prepare for strong shaking and
secure your safety.” It is not copied from, affiliated with, or presented as a
J-Alert, Japan Meteorological Agency, government, carrier, or broadcaster
recording.

The source was synthesized with `pyopenjtalk==0.4.1` and its bundled HTS Voice
“Mei.” The voice is copyright 2009–2013 Nagoya Institute of Technology,
Department of Computer Science, and is released by the MMDAgent Project Team
under [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/).
See the complete generator and dependency record in
`ios/QuakeSignal/Resources/Audio/ATTRIBUTION.md`.

The desktop copy is embedded in the Rust binary and used only when the user
selects “Japanese safety voice.” The exact output hash must be updated here if
the source is regenerated.

- `quakesignal_japanese_voice.wav` — mono 22.05-kHz signed 16-bit PCM,
  5.450023 seconds — SHA-256
  `50aaa1e2268b1ed7d5dce74fd3b547dffff3d66732116af3e146cc269e2b7032`
