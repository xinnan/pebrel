#!/usr/bin/env python3
"""Verify an iOS .ipa bundle structure, binary architecture, assets, and licenses."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile


ROOT = Path(__file__).resolve().parents[2]
VENDOR_MANIFEST = ROOT / "mobile/android/app/src/main/assets/reader/extensions-vendor.json"

REQUIRED_FILES = [
    "Info.plist",
    "themes.json",
    "host-icons.json",
    "ssh_agent_chat.py",
    "MapleMono-NF-CN-Regular.ttf",
    "JetBrainsMono-Regular.ttf",
    "en.lproj/Localizable.strings",
    "zh-Hans.lproj/Localizable.strings",
    "reader/reader.css",
    "reader/reader.js",
    "reader/extensions.js",
    "reader/highlight.min.js",
    "reader/katex/katex.min.js",
    "reader/katex/katex.min.css",
    "reader/mermaid/mermaid.min.js",
    "licenses/THIRD-PARTY-NOTICES.md",
]


def is_arm64_macho(data: bytes) -> bool:
    if len(data) < 16:
        return False
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == 0xFEEDFACF:  # MH_MAGIC_64 little-endian
        cputype = struct.unpack_from("<I", data, 4)[0]
        return cputype == 0x0100000C  # CPU_TYPE_ARM64
    if magic in (0xBEBAFECA, 0xCAFEBABE):  # FAT_CIGAM / FAT_MAGIC
        return True
    return False


def verify(ipa_path: Path, require_relay: bool = False) -> dict:
    if not ipa_path.is_file():
        raise FileNotFoundError(f"Missing IPA: {ipa_path}")

    with zipfile.ZipFile(ipa_path) as archive:
        names = set(archive.namelist())
        app_dirs = sorted({
            part
            for name in names
            if name.startswith("Payload/") and ".app/" in name
            for part in [name.split(".app/", 1)[0] + ".app/"]
        })
        if len(app_dirs) != 1:
            raise ValueError(f"Expected exactly one Payload/*.app directory, found: {app_dirs}")
        app_prefix = app_dirs[0]

        plist_data = archive.read(app_prefix + "Info.plist")
        info = plistlib.loads(plist_data)
        bundle_id = info.get("CFBundleIdentifier")
        executable = info.get("CFBundleExecutable")
        version = info.get("CFBundleShortVersionString")
        build = info.get("CFBundleVersion")
        if not bundle_id or not executable or not version or not build:
            raise ValueError("Incomplete Info.plist identity fields")

        exe_bytes = archive.read(app_prefix + executable)
        if not is_arm64_macho(exe_bytes):
            raise ValueError(f"Executable {executable} is not a valid arm64 Mach-O binary")

        missing = [rel for rel in REQUIRED_FILES if (app_prefix + rel) not in names]
        if missing:
            raise ValueError(f"Missing required IPA resources: {missing}")

        themes = json.loads(archive.read(app_prefix + "themes.json").decode("utf-8"))
        if "MintLight" not in themes or len(themes) < 16:
            raise ValueError(f"Unexpected themes.json entries: {len(themes)}")

        icons = json.loads(archive.read(app_prefix + "host-icons.json").decode("utf-8"))
        if len(icons) < 16 or not any(icon.get("id") == "term" for icon in icons):
            raise ValueError("Invalid host-icons.json payload")

        vendor = json.loads(VENDOR_MANIFEST.read_text(encoding="utf-8"))
        for package in vendor:
            for rel_path, expected_sha in package.get("files", {}).items():
                rel = "reader/" + rel_path
                actual = hashlib.sha256(archive.read(app_prefix + rel)).hexdigest()
                if actual != expected_sha:
                    raise ValueError(f"Reader asset hash mismatch for {rel}")

        relay_arches: list[str] = []
        for arch in ("x86_64", "aarch64"):
            manifest_entry = app_prefix + f"native-relay/{arch}/manifest.json"
            binary_entry = app_prefix + f"native-relay/{arch}/pebrel-relay"
            if manifest_entry in names and binary_entry in names:
                manifest = json.loads(archive.read(manifest_entry).decode("utf-8"))
                binary_hash = hashlib.sha256(archive.read(binary_entry)).hexdigest()
                if manifest.get("sha256") != binary_hash or manifest.get("protocol") != 2:
                    raise ValueError(f"Embedded relay integrity check failed for {arch}")
                relay_arches.append(arch)
        if require_relay and set(relay_arches) != {"x86_64", "aarch64"}:
            raise ValueError(f"Expected both embedded relay architectures, found: {relay_arches}")

    ipa_sha256 = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
    return {
        "ipa": ipa_path.name,
        "size_bytes": ipa_path.stat().st_size,
        "sha256": ipa_sha256,
        "bundle_id": bundle_id,
        "version": version,
        "build": build,
        "executable": executable,
        "themes": len(themes),
        "host_icons": len(icons),
        "embedded_relays": relay_arches,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--require-relay", action="store_true")
    parser.add_argument("--report", type=Path, default=None)
    args = parser.parse_args()
    result = verify(args.ipa, require_relay=args.require_relay)
    if args.report is not None:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
