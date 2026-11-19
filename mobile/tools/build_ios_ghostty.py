#!/usr/bin/env python3
"""Build the pinned Ghostty libghostty-vt + C++ bridge XCFramework for iOS."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from build_ghostty import digest, source_archive
from ios_xcframework import create_xcframework, stage_static_framework


ROOT = Path(__file__).resolve().parents[2]
PINS = ROOT / "mobile/android/ghostty/UPSTREAM.json"
BRIDGE_SRC = ROOT / "mobile/ios/Native/PebrelGhostty/src/pebrel_ghostty_ios.cpp"
BRIDGE_HEADERS = ROOT / "mobile/ios/Native/PebrelGhostty/include"
BRIDGE_HEADER_FILE = BRIDGE_HEADERS / "pebrel_ghostty_ios.h"
DEFAULT_OUTPUT = ROOT / "mobile/ios/Build"

ZIG_MACOS_PINS = {
    "arm64": (
        "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz",
        "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b",
        "zig-aarch64-macos.tar.xz",
    ),
    "x86_64": (
        "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz",
        "375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f",
        "zig-x86_64-macos.tar.xz",
    ),
}

SLICES = {
    "ios-arm64": {
        "zig_target": "aarch64-ios.{ver}",
        "zig_cpu": "baseline",
        "sdk": "iphoneos",
        "clang_target": "arm64-apple-ios{ver}",
    },
    "ios-arm64-simulator": {
        "zig_target": "aarch64-ios.{ver}-simulator",
        "zig_cpu": "apple_m1",
        "sdk": "iphonesimulator",
        "clang_target": "arm64-apple-ios{ver}-simulator",
    },
}


def zig_macos_host(machine: str) -> tuple[str, str, str]:
    arch = machine.lower()
    if arch in ("arm64", "aarch64"):
        return ZIG_MACOS_PINS["arm64"]
    if arch in ("x86_64", "amd64"):
        return ZIG_MACOS_PINS["x86_64"]
    raise SystemExit(f"Unsupported macOS architecture: {machine}")


def build_env(sources: Path, output: Path) -> dict[str, str]:
    env = os.environ.copy()
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "SDKROOT"):
        env.pop(name, None)
    env.update(
        ZIG_GLOBAL_CACHE_DIR=str(output / "cache/global"),
        GIT_CEILING_DIRECTORIES=str(sources.resolve().parent),
    )
    return env


def copy_licenses(sources: Path, zig_root: Path, cache_dir: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sources / "LICENSE", destination / "Ghostty-MIT.txt")
    shutil.copy2(sources / "build.zig.zon", destination / "upstream-dependencies.zig.zon")
    shutil.copy2(zig_root / "LICENSE", destination / "Zig-MIT.txt")
    packages = cache_dir / "p"
    if packages.is_dir():
        for package in sorted(packages.iterdir()):
            if not package.is_dir():
                continue
            for name in ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENSE-MIT", "LICENSE-APACHE", "COPYING", "NOTICE"):
                notice = package / name
                if notice.is_file():
                    target = destination / package.name / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(notice, target)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--slice", choices=("ios-arm64", "ios-arm64-simulator", "all"), default="all")
    parser.add_argument("--deployment-target", default="16.0")
    args = parser.parse_args()

    if platform.system() != "Darwin":
        raise SystemExit("Building iOS Ghostty XCFramework requires macOS with Xcode.")

    pins = json.loads(PINS.read_text(encoding="utf-8"))
    output = args.output.resolve()
    ghostty_work = output / "ghostty"
    frameworks = output / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)

    zig_url, zig_sha, zig_archive = zig_macos_host(platform.machine())
    sources = source_archive(
        pins["source_url"],
        pins["source_sha256"],
        ghostty_work / "downloads/terminal-core.tar.gz",
        ghostty_work / "sources",
    )
    zig_root = source_archive(
        zig_url,
        zig_sha,
        ghostty_work / "downloads" / zig_archive,
        ghostty_work / "tools",
    )
    zig = zig_root / "zig"
    if subprocess.check_output([str(zig), "version"], text=True, encoding="utf-8").strip() != pins["zig_version"]:
        raise SystemExit("Unexpected Zig version")

    env = build_env(sources, ghostty_work)
    selected = list(SLICES.keys()) if args.slice == "all" else [args.slice]
    staged_frameworks: list[Path] = []

    for slice_name in selected:
        spec = SLICES[slice_name]
        sdk = spec["sdk"]
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True, encoding="utf-8").strip()
        zig_target = spec["zig_target"].format(ver=args.deployment_target)
        clang_target = spec["clang_target"].format(ver=args.deployment_target)
        prefix = ghostty_work / "out" / slice_name
        prefix.mkdir(parents=True, exist_ok=True)

        print(f"Building libghostty-vt {pins['revision']} for {slice_name} ({zig_target})", flush=True)
        subprocess.run(
            [
                str(zig),
                "build",
                "-Demit-lib-vt",
                "-Demit-xcframework=false",
                "-Doptimize=ReleaseFast",
                f"-Dtarget={zig_target}",
                f"-Dcpu={spec['zig_cpu']}",
                "--prefix",
                str(prefix),
                "--cache-dir",
                str(ghostty_work / "cache" / slice_name),
            ],
            cwd=sources,
            env=env,
            check=True,
        )
        vt_lib = prefix / "lib/libghostty-vt.a"
        vt_include = prefix / "include"
        if not vt_lib.is_file() or vt_lib.stat().st_size == 0:
            raise RuntimeError(f"Missing static library: {vt_lib}")

        bridge_obj = prefix / "pebrel_ghostty_ios.o"
        combined_lib = prefix / "libpebrel_ghostty.a"
        subprocess.run(
            [
                "xcrun",
                "--sdk",
                sdk,
                "clang++",
                "-std=c++17",
                "-O2",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-fvisibility=hidden",
                "-DGHOSTTY_STATIC",
                "-target",
                clang_target,
                "-isysroot",
                sdk_path,
                "-I",
                str(vt_include),
                "-I",
                str(BRIDGE_HEADERS),
                "-c",
                str(BRIDGE_SRC),
                "-o",
                str(bridge_obj),
            ],
            check=True,
        )
        subprocess.run(
            ["xcrun", "libtool", "-static", "-o", str(combined_lib), str(vt_lib), str(bridge_obj)],
            check=True,
        )
        (prefix / "SOURCE.json").write_text(
            json.dumps({**pins, "slice": slice_name, "library_sha256": digest(combined_lib)}, indent=2) + "\n",
            encoding="utf-8",
        )
        staged_frameworks.append(
            stage_static_framework(
                staging_dir=frameworks / ".staging/PebrelGhostty" / slice_name,
                framework_name="PebrelGhostty",
                static_lib=combined_lib,
                header_file=BRIDGE_HEADER_FILE,
                bundle_id="io.github.kuddev.pebrel.mobile.ghostty",
                deployment_target=args.deployment_target,
            )
        )

    xcframework = frameworks / "PebrelGhostty.xcframework"
    create_xcframework(staged_frameworks, xcframework)
    copy_licenses(sources, zig_root, ghostty_work / "cache/global", frameworks / "licenses/Ghostty")
    shutil.copy2(PINS, frameworks / "licenses/Ghostty-UPSTREAM.json")
    print(f"Created {xcframework}", flush=True)


if __name__ == "__main__":
    main()
