#!/usr/bin/env python3
"""Build the public russh + mobile-link static XCFramework for iOS."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from cargo_notices import collect
from ios_xcframework import create_xcframework, stage_static_framework


ROOT = Path(__file__).resolve().parents[2]
CRATE = ROOT / "mobile/ssh"
HEADER_FILE = ROOT / "mobile/ios/Native/PebrelSshFFI/include/pebrel_ssh.h"
DEFAULT_OUTPUT = ROOT / "mobile/ios/Build/Frameworks"
TARGETS = {
    "ios-arm64": ("aarch64-apple-ios", "iphoneos"),
    "ios-arm64-simulator": ("aarch64-apple-ios-sim", "iphonesimulator"),
}


def collect_notices(output_dir: Path, records: list[dict]) -> None:
    license_source = json.loads((CRATE / "licenses/SOURCE.json").read_text(encoding="utf-8"))
    apache = CRATE / "licenses" / license_source["file"]
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--locked", "--format-version", "1", "--manifest-path", str(CRATE / "Cargo.toml")],
        text=True,
        encoding="utf-8",
    ))
    destination = output_dir / "licenses/Russh"
    resolved = {node["id"] for node in metadata["resolve"]["nodes"]}
    packages = collect(
        [pkg for pkg in metadata["packages"] if pkg["id"] in resolved],
        destination,
        apache,
        license_source["sha256"],
    )
    if not any(pkg["name"] == "russh" and pkg["texts"] for pkg in packages):
        raise RuntimeError("Missing russh license")
    shutil.copy2(CRATE / "Cargo.lock", destination / "Cargo.lock")
    shutil.copy2(CRATE / "licenses/SOURCE.json", destination / "LICENSE-SOURCE.json")
    (destination / "DEPENDENCIES.json").write_text(json.dumps(packages, indent=2) + "\n", encoding="utf-8")
    provenance = {
        "russh": "0.62.2",
        "rust": subprocess.check_output(["rustc", "--version"], text=True, encoding="utf-8").strip(),
        "libraries": records,
        "lock_sha256": hashlib.sha256((CRATE / "Cargo.lock").read_bytes()).hexdigest(),
    }
    (destination / "BUILD.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--slice", choices=("ios-arm64", "ios-arm64-simulator", "all"), default="all")
    parser.add_argument("--deployment-target", default="16.0")
    args = parser.parse_args()

    if platform.system() != "Darwin":
        raise SystemExit("Building iOS XCFrameworks requires macOS with Xcode.")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    selected = list(TARGETS.keys()) if args.slice == "all" else [args.slice]

    records = []
    staged_frameworks: list[Path] = []

    for slice_name in selected:
        triple, sdk = TARGETS[slice_name]
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True, encoding="utf-8").strip()
        env = os.environ.copy()
        env["IPHONEOS_DEPLOYMENT_TARGET"] = args.deployment_target
        env["SDKROOT"] = sdk_path
        print(f"Building pebrel-mobile-ssh for {triple} ({sdk})", flush=True)
        subprocess.run(
            [
                "cargo",
                "build",
                "--locked",
                "--release",
                "--no-default-features",
                "--target",
                triple,
                "--manifest-path",
                str(CRATE / "Cargo.toml"),
                "--target-dir",
                str(CRATE / "target"),
            ],
            env=env,
            check=True,
        )
        lib = CRATE / "target" / triple / "release/libpebrel_ssh.a"
        if not lib.is_file() or lib.stat().st_size == 0:
            raise RuntimeError(f"Missing static library: {lib}")
        records.append({
            "slice": slice_name,
            "target": triple,
            "sha256": hashlib.sha256(lib.read_bytes()).hexdigest(),
        })
        fw = stage_static_framework(
            staging_dir=output / ".staging/PebrelSshFFI" / slice_name,
            framework_name="PebrelSshFFI",
            static_lib=lib,
            header_file=HEADER_FILE,
            bundle_id="io.github.kuddev.pebrel.mobile.ssh-ffi",
            deployment_target=args.deployment_target,
        )
        staged_frameworks.append(fw)

    xcframework = output / "PebrelSshFFI.xcframework"
    create_xcframework(staged_frameworks, xcframework)
    collect_notices(output, records)
    print(f"Created {xcframework}", flush=True)


if __name__ == "__main__":
    main()
