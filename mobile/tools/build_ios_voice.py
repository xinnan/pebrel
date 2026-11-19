#!/usr/bin/env python3
"""Build the pinned whisper.cpp v1.7.6 static XCFramework for iOS."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess

from build_ghostty import digest, source_archive
from ios_xcframework import create_xcframework, stage_static_framework


ROOT = Path(__file__).resolve().parents[2]
BRIDGE_SRC = ROOT / "mobile/ios/Native/PebrelVoice/src/pebrel_voice_ios.cpp"
BRIDGE_HEADERS = ROOT / "mobile/ios/Native/PebrelVoice/include"
BRIDGE_HEADER_FILE = BRIDGE_HEADERS / "pebrel_voice_ios.h"
DEFAULT_OUTPUT = ROOT / "mobile/ios/Build"

WHISPER_VERSION = "v1.7.6"
WHISPER_URL = "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.7.6"
WHISPER_SHA256 = "166140e9a6d8a36f787a2bd77f8f44dd64874f12dd8359ff7c1f4f9acb86202e"

SLICES = {
    "ios-arm64": {
        "sdk": "iphoneos",
        "clang_target": "arm64-apple-ios{ver}",
        "cmake_sysname": "iOS",
        "cmake_arch": "arm64",
    },
    "ios-arm64-simulator": {
        "sdk": "iphonesimulator",
        "clang_target": "arm64-apple-ios{ver}-simulator",
        "cmake_sysname": "iOS",
        "cmake_arch": "arm64",
    },
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--slice", choices=("ios-arm64", "ios-arm64-simulator", "all"), default="all")
    parser.add_argument("--deployment-target", default="16.0")
    args = parser.parse_args()

    if platform.system() != "Darwin":
        raise SystemExit("Building iOS Whisper XCFramework requires macOS with Xcode.")

    output = args.output.resolve()
    work = output / "voice"
    frameworks = output / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)

    sources = source_archive(
        WHISPER_URL,
        WHISPER_SHA256,
        work / "downloads/whisper.tar.gz",
        work / "sources",
    )

    selected = list(SLICES.keys()) if args.slice == "all" else [args.slice]
    staged_frameworks: list[Path] = []
    records = []

    for slice_name in selected:
        spec = SLICES[slice_name]
        sdk = spec["sdk"]
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True, encoding="utf-8").strip()
        clang_target = spec["clang_target"].format(ver=args.deployment_target)
        build_dir = work / "cmake" / slice_name
        build_dir.mkdir(parents=True, exist_ok=True)

        print(f"Building whisper.cpp {WHISPER_VERSION} for {slice_name}", flush=True)
        cmake_cmd = [
            "cmake",
            "-S", str(sources),
            "-B", str(build_dir),
            "-DCMAKE_SYSTEM_NAME=iOS",
            f"-DCMAKE_OSX_SYSROOT={sdk}",
            f"-DCMAKE_OSX_ARCHITECTURES={spec['cmake_arch']}",
            f"-DCMAKE_OSX_DEPLOYMENT_TARGET={args.deployment_target}",
            "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DWHISPER_BUILD_TESTS=OFF",
            "-DWHISPER_BUILD_EXAMPLES=OFF",
            "-DWHISPER_BUILD_SERVER=OFF",
            "-DGGML_METAL=OFF",
            "-DGGML_OPENMP=OFF",
            "-DGGML_NATIVE=OFF",
            "-DGGML_BACKEND_DL=OFF",
            "-DGGML_CPU_ALL_VARIANTS=OFF",
            "-DGGML_ACCELERATE=ON",
        ]
        subprocess.run(cmake_cmd, check=True)
        subprocess.run(["cmake", "--build", str(build_dir), "--config", "Release", "--parallel"], check=True)

        static_libs = sorted(
            p
            for p in build_dir.rglob("*.a")
            if p.is_file() and p.stat().st_size > 0 and "CMakeFiles" not in p.parts
        )
        if not any(p.name == "libwhisper.a" for p in static_libs):
            raise RuntimeError(f"Missing libwhisper.a in {build_dir}")

        bridge_obj = build_dir / "pebrel_voice_ios.o"
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
                "-target",
                clang_target,
                "-isysroot",
                sdk_path,
                "-I", str(sources / "include"),
                "-I", str(sources / "ggml/include"),
                "-I", str(BRIDGE_HEADERS),
                "-c", str(BRIDGE_SRC),
                "-o", str(bridge_obj),
            ],
            check=True,
        )

        combined_lib = work / "out" / slice_name / "libpebrel_voice.a"
        combined_lib.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["xcrun", "libtool", "-static", "-o", str(combined_lib), str(bridge_obj), *(str(p) for p in static_libs)],
            check=True,
        )
        records.append({"slice": slice_name, "sha256": digest(combined_lib)})
        staged_frameworks.append(
            stage_static_framework(
                staging_dir=frameworks / ".staging/PebrelVoice" / slice_name,
                framework_name="PebrelVoice",
                static_lib=combined_lib,
                header_file=BRIDGE_HEADER_FILE,
                bundle_id="io.github.kuddev.pebrel.mobile.voice",
                deployment_target=args.deployment_target,
            )
        )

    xcframework = frameworks / "PebrelVoice.xcframework"
    create_xcframework(staged_frameworks, xcframework)

    notices = frameworks / "licenses/Whisper"
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sources / "LICENSE", notices / "Whisper-MIT.txt")
    (notices / "SOURCE.json").write_text(
        json.dumps(
            {
                "project": "https://github.com/ggml-org/whisper.cpp",
                "version": WHISPER_VERSION,
                "source_url": WHISPER_URL,
                "source_sha256": WHISPER_SHA256,
                "libraries": records,
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    print(f"Created {xcframework}", flush=True)


if __name__ == "__main__":
    main()
