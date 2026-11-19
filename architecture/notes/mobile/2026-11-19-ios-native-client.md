# iOS Native Client Architecture and FFI Boundary

## Status
Accepted (2026-11-19)

## Context
Pebrel's mobile companion and SSH client previously existed only for Android (`mobile/android`). Bringing feature parity to iOS while preserving single-authority protocol, cryptography, and terminal emulation rules requires reusing `mobile/ssh` (`russh` + `russh-sftp`), `mobile/link` (Noise NKpsk0 E2EE), pinned Ghostty `libghostty-vt`, pinned `whisper.cpp` v1.7.6, and the offline KaTeX/Mermaid reader assets without duplicating protocol logic or breaking Android builds.

## Evidence
- `mobile/ssh` already isolates SSH/SFTP protocol state inside `session.rs`, `transport.rs`, and `sftp.rs`; only `bridge.rs` and `mobile_link.rs` depended on `jni`.
- `mobile/android/ghostty` and `mobile/android/voice` already wrap upstream `libghostty-vt` and `whisper.cpp` behind small C++ adapters.
- `WKWebView` rejects custom `WKURLSchemeHandler` registrations for `http`/`https`; a dedicated `pebrel-reader://` scheme preserves offline CSP isolation and unmodified reader asset hashes.
- iOS sandboxing prohibits `fork/exec` of local shells, and Apple's `SecKeyCopyExternalRepresentation` omits ASN.1 SPKI headers across RSA/ECDSA certificates.

## Decision
1. Keep one Rust transport authority in `mobile/ssh`: extract the Noise channel handle table into `link_store.rs`, keep `jni` as the default Cargo feature for Android compatibility, and add `staticlib` + `c_ffi.rs` (`pebrel_ssh_*` / `pebrel_link_*`) for iOS `PebrelSshFFI.xcframework`.
2. Add JNI-free C++17 bridges for iOS under `mobile/ios/Native/PebrelGhostty` and `mobile/ios/Native/PebrelVoice`, built into XCFrameworks from the same pinned upstream sources and hashes as Android.
3. Build the iOS app in native SwiftUI + UIKit (`mobile/ios/`) with zero third-party SwiftPM dependencies, extracting X.509 SPKI DER directly for TLS pinning, serving offline reader assets over `pebrel-reader://`, syncing themes/icons/strings from desktop and Android authorities via `mobile/tools/generate_ios_assets.py`, and declaring local device shell explicitly unsupported on iOS.
4. Provide both local macOS (`mobile/tools/build_ios_ipa.py`) and GitHub Actions (`macos-26`, `.github/workflows/ios-release.yml`) `.ipa` packaging supporting `adhoc`/`unsigned` sideloading and optional `signed` Apple Developer exports.

## Rejected alternatives
- **Pure Swift rewrite of SSH/Noise/VT**: rejected because duplicating `russh`, `russh-sftp`, Noise NKpsk0 framing, and VT parsing would fork security-critical protocol authorities.
- **Kotlin Multiplatform / Compose Multiplatform**: rejected because refactoring the 33k-line Android tree would risk Android regressions and add heavy Gradle/KMP maintenance overhead.
- **Stubbing a fake local shell on iOS**: rejected under `docs/architecture.md` ("unsupported behavior must be explicit, not a silently successful stub").

## Consequences
- `mobile/ssh` compiles cleanly both with `--locked` (Android JNI) and `--locked --no-default-features` (iOS C FFI).
- Compiling `.ipa` binaries still requires macOS + Xcode (`macos-26` CI runner or a local Mac); Linux environments validate Rust C FFI tests, C header syntax, asset/localization generation, and IPA verifier tests.

## Validation
- `cargo test --locked --manifest-path mobile/ssh/Cargo.toml` and `--no-default-features` pass all 12 tests including multi-chunk C FFI Noise round-trip and error-path tests.
- `python3 -m unittest mobile/tools/test_ios_tools.py` validates asset parity, localization conversion, and positive/negative `.ipa` audits.
- Real Xcode compilation, `PebrelTests` on iOS Simulator, and `.ipa` packaging are executed by `.github/workflows/ios-release.yml` on `macos-26` (or locally on macOS).

## Supersedes
None

## Revisit when
- Upstream Ghostty ships an official `libghostty-vt` iOS XCFramework release matching our pinned revision.
- `mobile/ios` enters the root workspace or required PR CI matrix in `scripts/ci_plan.py`.
