#!/usr/bin/env python3
"""Build the pinned Ghostty libghostty-vt + C++ bridge XCFramework for iOS."""
from __future__ import annotations

import argparse
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


def zig_host_pin(system: str, machine: str, pins: dict[str, str]) -> tuple[str, str, str]:
    arch = machine.lower()
    if system == "Darwin":
        if arch in ("arm64", "aarch64"):
            return ZIG_MACOS_PINS["arm64"]
        if arch in ("x86_64", "amd64"):
            return ZIG_MACOS_PINS["x86_64"]
        raise SystemExit(f"Unsupported macOS architecture: {machine}")
    if system == "Linux":
        if arch in ("x86_64", "amd64"):
            return pins["zig_url"], pins["zig_sha256"], "zig-linux-x86_64.tar.xz"
        if arch in ("aarch64", "arm64"):
            return pins["zig_linux_arm64_url"], pins["zig_linux_arm64_sha256"], "zig-linux-arm64.tar.xz"
        raise SystemExit(f"Unsupported Linux architecture: {machine}")
    raise SystemExit(f"Unsupported host platform for Zig iOS VT build: {system}/{machine}")


def write_static_vt_wrapper(wrapper_dir: Path, sources: Path) -> Path:
    """Create a minimal Zig package that builds only Ghostty's static libghostty-vt.a.

    Building Ghostty's default install step also attempts to link libghostty-vt.dylib,
    which requires an Apple SDK and fails when cross-compiling from Linux. Depending on
    Ghostty as a local package and selecting only `artifact("ghostty-vt-static")` avoids
    touching upstream sources while producing the exact static archive and headers.
    """
    wrapper_dir.mkdir(parents=True, exist_ok=True)
    rel_ghostty = os.path.relpath(sources.resolve(), wrapper_dir.resolve()).replace(os.sep, "/")
    (wrapper_dir / "build.zig.zon").write_text(
        ".{\n"
        "    .name = .pebrel_ghostty_vt_static,\n"
        '    .version = "0.1.0",\n'
        "    .fingerprint = 0x9362cfe2028b69d2,\n"
        '    .paths = .{ "build.zig", "build.zig.zon" },\n'
        "    .dependencies = .{\n"
        f'        .ghostty = .{{ .path = "{rel_ghostty}" }},\n'
        "    },\n"
        "}\n",
        encoding="utf-8",
    )
    (wrapper_dir / "build.zig").write_text(
        'const std = @import("std");\n\n'
        "pub fn build(b: *std.Build) void {\n"
        "    const target = b.standardTargetOptions(.{});\n"
        "    const optimize = b.standardOptimizeOption(.{});\n"
        '    const simd = b.option(bool, "simd", "Enable SIMD") orelse false;\n'
        '    const ghostty = b.dependency("ghostty", .{\n'
        "        .target = target,\n"
        "        .optimize = optimize,\n"
        "        .simd = simd,\n"
        "    });\n"
        '    const lib = ghostty.artifact("ghostty-vt-static");\n'
        '    const install_lib = b.addInstallFileWithDir(lib.getEmittedBin(), .lib, "libghostty-vt.a");\n'
        "    b.getInstallStep().dependOn(&install_lib.step);\n"
        "    b.installDirectory(.{\n"
        '        .source_dir = ghostty.path("include/ghostty"),\n'
        "        .install_dir = .header,\n"
        '        .install_subdir = "ghostty",\n'
        "    });\n"
        "}\n",
        encoding="utf-8",
    )
    return wrapper_dir


def resolve_prebuilt_vt(
    prebuilt_root: Path,
    slice_name: str,
    expected_revision: str | None = None,
) -> tuple[Path, Path]:
    root = prebuilt_root.resolve()
    if expected_revision is not None:
        for meta_path in (root / "PREBUILT.json", root / "ghostty/PREBUILT.json"):
            if meta_path.is_file():
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                found_rev = meta.get("revision")
                if found_rev != expected_revision:
                    raise ValueError(
                        f"Prebuilt Ghostty VT revision {found_rev!r} in {meta_path} "
                        f"does not match pinned revision {expected_revision!r}"
                    )
                break
    candidates = [
        root / "out" / slice_name,
        root / "ghostty/out" / slice_name,
        root / slice_name,
    ]
    for base in candidates:
        vt_lib = base / "lib/libghostty-vt.a"
        vt_include = base / "include"
        if vt_lib.is_file() and vt_lib.stat().st_size > 0 and (vt_include / "ghostty/vt.h").is_file():
            return vt_lib, vt_include
    raise FileNotFoundError(
        f"Missing prebuilt libghostty-vt.a or include/ghostty/vt.h for slice {slice_name} under {root}"
    )


def extract_ar_members(archive: Path, destination: Path) -> list[Path]:
    """Extract object members from a BSD/GNU static archive (.a).

    Zig 0.15.2 emits BSD `#1/<n>` archive headers with 4-byte rather than 8-byte
    member payload alignment, causing Apple's `libtool` to warn and drop members
    like `compiler_rt.o` ("64-bit mach-o not 8-byte aligned"). Extracting the
    raw `.o` members and handing them directly to `xcrun libtool -static` lets
    Apple's toolchain produce a properly 8-byte-aligned static archive.
    """
    data = archive.read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise ValueError(f"Not a valid ar archive: {archive}")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)

    members: list[Path] = []
    gnu_names = b""
    pos = 8
    while pos + 60 <= len(data):
        header = data[pos : pos + 60]
        if header[58:60] != b"`\n":
            raise ValueError(f"Corrupt ar member header at offset {pos} in {archive}")
        raw_name = header[0:16].decode("ascii")
        size = int(header[48:58].decode("ascii").strip())
        payload_start = pos + 60
        payload_end = payload_start + size
        if payload_end > len(data):
            raise ValueError(f"Truncated ar member at offset {pos} in {archive}")
        payload = data[payload_start:payload_end]
        pos = payload_end + (payload_end & 1)

        if raw_name.startswith("#1/"):
            name_len = int(raw_name[3:].strip())
            member_name = payload[:name_len].split(b"\x00", 1)[0].decode("utf-8", "replace")
            obj_bytes = payload[name_len:]
        elif raw_name.strip() == "//":
            gnu_names = payload
            continue
        elif raw_name.strip() in ("/", "/SYM64/"):
            continue
        elif raw_name.startswith("/") and raw_name[1:].strip().isdigit():
            offset = int(raw_name[1:].strip())
            end = gnu_names.find(b"\n", offset)
            raw_entry = gnu_names[offset:] if end == -1 else gnu_names[offset:end]
            member_name = raw_entry.decode("utf-8", "replace").rstrip("/")
            obj_bytes = payload
        else:
            member_name = raw_name.strip().rstrip("/")
            obj_bytes = payload

        if member_name in ("", "__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED"):
            continue
        safe_name = Path(member_name).name or f"member_{len(members)}.o"
        out_file = destination / f"{len(members):03d}-{safe_name}"
        out_file.write_bytes(obj_bytes)
        members.append(out_file)

    if not members:
        raise ValueError(f"No object members found in archive: {archive}")
    return members


def copy_prebuilt_licenses(prebuilt_root: Path, destination: Path) -> None:
    root = prebuilt_root.resolve()
    for candidate in (
        root / "licenses/Ghostty",
        root / "ghostty/licenses/Ghostty",
        root / "Frameworks/licenses/Ghostty",
    ):
        if candidate.is_dir():
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(candidate, destination)
            return
    destination.mkdir(parents=True, exist_ok=True)


def build_env(sources: Path, output: Path) -> dict[str, str]:
    env = os.environ.copy()
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "SDKROOT"):
        env.pop(name, None)
    env.update(
        ZIG_GLOBAL_CACHE_DIR=str(output / "cache/global"),
        GIT_CEILING_DIRECTORIES=str(output.resolve()),
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
    parser.add_argument(
        "--vt-only",
        action="store_true",
        help="Build only static libghostty-vt.a slices + headers + licenses (works on Linux or macOS).",
    )
    parser.add_argument(
        "--prebuilt-vt",
        type=Path,
        default=None,
        help="Use prebuilt libghostty-vt.a slices (skips Zig; works with Xcode 26.4+/27.x).",
    )
    args = parser.parse_args()

    if args.vt_only and args.prebuilt_vt is not None:
        raise SystemExit("Cannot pass both --vt-only and --prebuilt-vt.")
    if not args.vt_only and platform.system() != "Darwin":
        raise SystemExit("Building iOS Ghostty XCFramework requires macOS with Xcode (or pass --vt-only on Linux).")

    pins = json.loads(PINS.read_text(encoding="utf-8"))
    output = args.output.resolve()
    ghostty_work = output / "ghostty"
    frameworks = output / "Frameworks"
    selected = list(SLICES.keys()) if args.slice == "all" else [args.slice]

    sources: Path | None = None
    zig_root: Path | None = None
    if args.prebuilt_vt is None:
        zig_url, zig_sha, zig_archive = zig_host_pin(platform.system(), platform.machine(), pins)
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
        use_static_wrapper = platform.system() != "Darwin" or args.vt_only
        wrapper_dir = write_static_vt_wrapper(ghostty_work / "wrapper", sources) if use_static_wrapper else None

        for slice_name in selected:
            spec = SLICES[slice_name]
            zig_target = spec["zig_target"].format(ver=args.deployment_target)
            prefix = ghostty_work / "out" / slice_name
            prefix.mkdir(parents=True, exist_ok=True)
            print(f"Building libghostty-vt {pins['revision']} for {slice_name} ({zig_target})", flush=True)
            if wrapper_dir is not None:
                simd_flag = "true" if platform.system() == "Darwin" else "false"
                cmd = [
                    str(zig),
                    "build",
                    "-Doptimize=ReleaseFast",
                    f"-Dsimd={simd_flag}",
                    f"-Dtarget={zig_target}",
                    f"-Dcpu={spec['zig_cpu']}",
                    "--prefix",
                    str(prefix),
                    "--cache-dir",
                    str(ghostty_work / "cache" / slice_name),
                ]
                cwd = wrapper_dir
            else:
                cmd = [
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
                ]
                cwd = sources
            subprocess.run(cmd, cwd=cwd, env=env, check=True)
            vt_lib = prefix / "lib/libghostty-vt.a"
            if not vt_lib.is_file() or vt_lib.stat().st_size == 0:
                raise RuntimeError(f"Missing static library: {vt_lib}")

        if args.vt_only:
            copy_licenses(sources, zig_root, ghostty_work / "cache/global", ghostty_work / "licenses/Ghostty")
            shutil.copy2(PINS, ghostty_work / "licenses/Ghostty-UPSTREAM.json")
            prebuilt_meta = {
                "revision": pins["revision"],
                "zig_version": pins["zig_version"],
                "deployment_target": args.deployment_target,
                "host": f"{platform.system()}/{platform.machine()}",
                "slices": {
                    s: {
                        "library": f"out/{s}/lib/libghostty-vt.a",
                        "sha256": digest(ghostty_work / "out" / s / "lib/libghostty-vt.a"),
                    }
                    for s in selected
                },
            }
            (ghostty_work / "PREBUILT.json").write_text(json.dumps(prebuilt_meta, indent=2) + "\n", encoding="utf-8")
            print(f"Built prebuilt VT slices under {ghostty_work}", flush=True)
            return

    frameworks.mkdir(parents=True, exist_ok=True)
    staged_frameworks: list[Path] = []
    for slice_name in selected:
        spec = SLICES[slice_name]
        sdk = spec["sdk"]
        sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True, encoding="utf-8").strip()
        clang_target = spec["clang_target"].format(ver=args.deployment_target)
        prefix = ghostty_work / "out" / slice_name
        prefix.mkdir(parents=True, exist_ok=True)

        if args.prebuilt_vt is not None:
            vt_lib, vt_include = resolve_prebuilt_vt(
                args.prebuilt_vt,
                slice_name,
                expected_revision=pins["revision"],
            )
            print(f"Using prebuilt libghostty-vt for {slice_name}: {vt_lib}", flush=True)
        else:
            vt_lib = prefix / "lib/libghostty-vt.a"
            vt_include = prefix / "include"

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
        vt_members = extract_ar_members(vt_lib, prefix / "vt-objects")
        subprocess.run(
            [
                "xcrun",
                "libtool",
                "-static",
                "-o",
                str(combined_lib),
                *(str(member) for member in vt_members),
                str(bridge_obj),
            ],
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
    if args.prebuilt_vt is not None:
        copy_prebuilt_licenses(args.prebuilt_vt, frameworks / "licenses/Ghostty")
    else:
        assert sources is not None and zig_root is not None
        copy_licenses(sources, zig_root, ghostty_work / "cache/global", frameworks / "licenses/Ghostty")
    shutil.copy2(PINS, frameworks / "licenses/Ghostty-UPSTREAM.json")
    print(f"Created {xcframework}", flush=True)


if __name__ == "__main__":
    main()
