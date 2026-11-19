# Pebrel iOS third-party notices

Pebrel iOS combines GPLv3-compatible components and is distributed under GPL version 3.
Original component licenses and copyright notices remain applicable; inclusion does not relicense upstream sources.

- **Ghostty `libghostty-vt`** (revision `28f9367bee11ad42f40f8aa589eb8c6db62d34be`, MIT):
  https://github.com/ghostty-org/ghostty — built from verified public source with Zig `0.15.2`.
  Licenses and provenance are bundled under `licenses/Ghostty` and `licenses/Ghostty-UPSTREAM.json`.
- **russh `0.62.2`** (Apache-2.0) & **russh-sftp `2.3.0`** (Apache-2.0):
  https://github.com/warp-tech/russh and https://github.com/AspectUnk/russh-sftp — shared Rust SSH/SFTP/Noise transport (`mobile/ssh` + `mobile/link`).
  Resolved dependency notices and `Cargo.lock` are bundled under `licenses/Russh`.
- **whisper.cpp `v1.7.6`** (MIT):
  https://github.com/ggml-org/whisper.cpp — on-device speech-to-text engine (`licenses/Whisper`).
- **Maple Mono NF CN `7.900`** (SIL OFL 1.1) & **JetBrains Mono `2.304`** (SIL OFL 1.1):
  Unmodified desktop terminal fonts bundled in the app (`licenses/MapleMono-OFL.txt`, `licenses/JetBrainsMono-OFL.txt`).
- **highlight.js `11.11.1`** (BSD-3-Clause), **KaTeX `0.18.9`** (MIT), **Mermaid `11.17.2`** (MIT), **core-js `3.50.0`** (MIT):
  Offline rich reader extensions bundled under `reader/` with no runtime CDN or external network loads.
- **Apple SDK frameworks** (SwiftUI, UIKit, WebKit, AVFoundation, Network, Security, CryptoKit, CoreText, CoreGraphics, Accelerate):
  System frameworks provided by iOS.
