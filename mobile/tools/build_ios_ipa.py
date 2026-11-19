#!/usr/bin/env python3
"""End-to-end macOS builder producing unsigned/ad-hoc or signed Pebrel iOS .ipa packages."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[2]
IOS_DIR = ROOT / "mobile/ios"
TOOLS_DIR = ROOT / "mobile/tools"


def run(cmd: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=cwd, env=env, check=True)


def zip_app_to_ipa(app_path: Path, ipa_path: Path) -> None:
    if not app_path.is_dir():
        raise FileNotFoundError(f"Missing built app bundle: {app_path}")
    ipa_path.parent.mkdir(parents=True, exist_ok=True)
    if ipa_path.exists():
        ipa_path.unlink()
    with zipfile.ZipFile(ipa_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for item in sorted(app_path.rglob("*")):
            rel = Path("Payload") / app_path.name / item.relative_to(app_path)
            if item.is_symlink():
                info = zipfile.ZipInfo(rel.as_posix())
                info.create_system = 3
                info.external_attr = (0o120777 << 16)
                archive.writestr(info, os.readlink(item))
            elif item.is_dir():
                info = zipfile.ZipInfo(rel.as_posix() + "/")
                info.create_system = 3
                info.external_attr = (0o040755 << 16)
                archive.writestr(info, b"")
            else:
                archive.write(item, rel.as_posix())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="2.5.0-preview")
    parser.add_argument("--build-number", default="1")
    parser.add_argument("--mode", choices=("unsigned", "adhoc", "signed"), default="adhoc")
    parser.add_argument("--output", type=Path, default=IOS_DIR / "dist")
    parser.add_argument("--relay-assets", type=Path, default=None)
    parser.add_argument("--skip-native", action="store_true")
    parser.add_argument("--skip-voice", action="store_true")
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--team-id", default="")
    parser.add_argument("--export-options", type=Path, default=None)
    parser.add_argument("--deployment-target", default="16.0")
    args = parser.parse_args()

    if platform.system() != "Darwin":
        raise SystemExit("build_ios_ipa.py must run on macOS with Xcode installed.")

    py = sys.executable
    slice_arg = "ios-arm64" if args.skip_tests else "all"

    if not args.skip_native:
        run([py, str(TOOLS_DIR / "build_ios_ghostty.py"), "--slice", slice_arg, "--deployment-target", args.deployment_target])
        run([py, str(TOOLS_DIR / "build_ios_russh.py"), "--slice", slice_arg, "--deployment-target", args.deployment_target])
        if not args.skip_voice:
            run([py, str(TOOLS_DIR / "build_ios_voice.py"), "--slice", slice_arg, "--deployment-target", args.deployment_target])

    asset_cmd = [py, str(TOOLS_DIR / "generate_ios_assets.py")]
    if args.relay_assets is not None:
        asset_cmd.extend(["--relay-assets", str(args.relay_assets)])
    run(asset_cmd)

    if shutil.which("xcodegen") is None:
        raise SystemExit("Missing xcodegen. Install it with: brew install xcodegen")
    run(["xcodegen", "generate", "--spec", "project.yml"], cwd=IOS_DIR)

    derived_data = IOS_DIR / "Build/DerivedData"
    version_args = [
        f"MARKETING_VERSION={args.version}",
        f"CURRENT_PROJECT_VERSION={args.build_number}",
    ]

    if not args.skip_tests:
        sim_dest = "generic/platform=iOS Simulator"
        # Prefer running unit tests on an available iOS Simulator if one exists.
        sim_list = json.loads(
            subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True)
        )
        chosen_udid = None
        for runtime, devices in sim_list.get("devices", {}).items():
            if "iOS" not in runtime:
                continue
            for dev in devices:
                if dev.get("isAvailable") and "iPhone" in dev.get("name", ""):
                    chosen_udid = dev["udid"]
                    break
            if chosen_udid:
                break
        if chosen_udid:
            run(
                [
                    "xcodebuild",
                    "test",
                    "-project", "Pebrel.xcodeproj",
                    "-scheme", "Pebrel",
                    "-configuration", "Debug",
                    "-destination", f"id={chosen_udid}",
                    "-derivedDataPath", str(derived_data),
                    "CODE_SIGNING_ALLOWED=NO",
                    *version_args,
                ],
                cwd=IOS_DIR,
            )
        else:
            run(
                [
                    "xcodebuild",
                    "build-for-testing",
                    "-project", "Pebrel.xcodeproj",
                    "-scheme", "Pebrel",
                    "-configuration", "Debug",
                    "-destination", sim_dest,
                    "-derivedDataPath", str(derived_data),
                    "CODE_SIGNING_ALLOWED=NO",
                    *version_args,
                ],
                cwd=IOS_DIR,
            )

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    suffix = "signed" if args.mode == "signed" else ("adhoc" if args.mode == "adhoc" else "unsigned")
    ipa_path = output / f"Pebrel-{args.version}-ios-{suffix}.ipa"

    if args.mode == "signed":
        if not args.export_options or not args.export_options.is_file():
            raise SystemExit("Signed mode requires --export-options <ExportOptions.plist>.")
        archive_path = IOS_DIR / "Build/Pebrel.xcarchive"
        if archive_path.exists():
            shutil.rmtree(archive_path)
        archive_cmd = [
            "xcodebuild",
            "archive",
            "-project", "Pebrel.xcodeproj",
            "-scheme", "Pebrel",
            "-configuration", "Release",
            "-sdk", "iphoneos",
            "-destination", "generic/platform=iOS",
            "-archivePath", str(archive_path),
            "-derivedDataPath", str(derived_data),
            *version_args,
        ]
        if args.team_id:
            archive_cmd.append(f"DEVELOPMENT_TEAM={args.team_id}")
        run(archive_cmd, cwd=IOS_DIR)

        export_dir = IOS_DIR / "Build/Export"
        if export_dir.exists():
            shutil.rmtree(export_dir)
        run(
            [
                "xcodebuild",
                "-exportArchive",
                "-archivePath", str(archive_path),
                "-exportOptionsPlist", str(args.export_options),
                "-exportPath", str(export_dir),
            ],
            cwd=IOS_DIR,
        )
        exported = list(export_dir.glob("*.ipa"))
        if len(exported) != 1:
            raise RuntimeError(f"Expected one exported IPA in {export_dir}, found: {exported}")
        shutil.copyfile(exported[0], ipa_path)
    else:
        run(
            [
                "xcodebuild",
                "build",
                "-project", "Pebrel.xcodeproj",
                "-scheme", "Pebrel",
                "-configuration", "Release",
                "-sdk", "iphoneos",
                "-destination", "generic/platform=iOS",
                "-derivedDataPath", str(derived_data),
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGN_IDENTITY=",
                "AD_HOC_CODE_SIGNING_ALLOWED=YES",
                *version_args,
            ],
            cwd=IOS_DIR,
        )
        app_path = derived_data / "Build/Products/Release-iphoneos/Pebrel.app"
        if not app_path.is_dir():
            raise RuntimeError(f"Built app not found at {app_path}")
        if args.mode == "adhoc":
            run(["codesign", "--force", "--sign", "-", "--deep", "--timestamp=none", str(app_path)])
        else:
            sig = app_path / "_CodeSignature"
            if sig.exists():
                shutil.rmtree(sig)
        zip_app_to_ipa(app_path, ipa_path)

    report = output / f"Pebrel-{args.version}-ios-report.json"
    verify_cmd = [py, str(TOOLS_DIR / "verify_ios_ipa.py"), str(ipa_path), "--report", str(report)]
    if args.relay_assets is not None:
        verify_cmd.append("--require-relay")
    run(verify_cmd)

    sha = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
    (output / f"{ipa_path.name}.sha256").write_text(f"{sha}  {ipa_path.name}\n", encoding="utf-8")
    print(f"Done: {ipa_path} (SHA256={sha})", flush=True)


if __name__ == "__main__":
    main()
