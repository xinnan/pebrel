# Pebrel iOS

Native SwiftUI + UIKit iOS client sharing Pebrel's core native engines with Android:

- **SSH / SFTP / Noise NKpsk0 E2EE**: Shared Rust transport ([`mobile/ssh`](../ssh) + [`mobile/link`](../link)) exported via C FFI (`PebrelSshFFI.xcframework`).
- **Terminal Engine**: Pinned Ghostty `libghostty-vt` (`28f9367...`, Zig `0.15.2`) wrapped in a JNI-free C++17 bridge (`PebrelGhostty.xcframework`) and CoreGraphics/CoreText grid renderer.
- **Local Voice Input**: Pinned `whisper.cpp` `v1.7.6` (`PebrelVoice.xcframework`) with on-device SHA-256 verified Whisper Base model download and `AVAudioEngine` 16 kHz capture.
- **Offline Rich Reader**: Bundled KaTeX, Mermaid, and highlight.js served strictly offline via a custom `pebrel-reader://` `WKURLSchemeHandler` inside `WKWebView`.

## Platform boundaries vs. Android

- **Local device shell**: Intentionally unsupported on stock iOS because iOS sandboxing forbids spawning local shell processes (`fork/exec`). The app explicitly documents this boundary and focuses on **Desktop pairing (LAN / Relay)**, **Direct SSH + tmux/herdr**, **SFTP**, **Git**, and **AI Agent Conversations**.
- **Background execution**: iOS suspends sockets shortly after entering the background. Drafts and transcripts remain intact and connections recover automatically on foreground return or network change.

## Building an `.ipa`

### Option A: GitHub Actions (no local Mac required)

Run the **`iOS Preview IPA package`** workflow ([`.github/workflows/ios-release.yml`](../../.github/workflows/ios-release.yml)) via **Actions → Run workflow**:

- `sign_mode = adhoc` (default): builds XCFrameworks, runs `PebrelTests` on iOS Simulator, verifies the bundle with `verify_ios_ipa.py`, and uploads `Pebrel-<version>-ios-adhoc.ipa` for **AltStore / SideStore / Sideloadly / TrollStore**.
- `sign_mode = unsigned`: same bundle without ad-hoc signature.
- `sign_mode = signed`: uses repository secrets (`APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_PROVISIONING_PROFILE_BASE64`, `APPLE_EXPORT_OPTIONS_PLIST_BASE64`, `APPLE_KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`) for Apple Developer Ad-Hoc / TestFlight / App Store export.

### Option B: Local macOS build

Prerequisites on macOS (Apple Silicon recommended, Xcode 16+):

```bash
brew install xcodegen cmake
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

One-command ad-hoc / unsigned `.ipa` build:

```bash
python3 mobile/tools/build_ios_ipa.py --version 2.5.0-preview --mode adhoc --output mobile/ios/dist
```

Signed `.ipa` build (copy `ExportOptions.template.plist` and fill in your Team ID and Provisioning Profile):

```bash
python3 mobile/tools/build_ios_ipa.py \
  --version 2.5.0-preview \
  --mode signed \
  --team-id YOUR_TEAM_ID \
  --export-options mobile/ios/ExportOptions.plist \
  --output mobile/ios/dist
```

## Sideloading an ad-hoc / unsigned `.ipa`

- **AltStore / SideStore / Sideloadly**: import the generated `.ipa` directly; those tools re-sign it with your Apple ID.
- **TrollStore**: install the `adhoc` `.ipa` directly without re-signing.
