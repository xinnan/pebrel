"""Helper to wrap iOS static archives into static .framework bundles for XCFrameworks.

Wrapping each slice as a static .framework prevents Xcode's `ProcessXCFramework`
`Multiple commands produce '.../include/module.modulemap'` collision when an app
links multiple static-library XCFrameworks.
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import shutil
import subprocess


def stage_static_framework(
    staging_dir: Path,
    framework_name: str,
    static_lib: Path,
    header_file: Path,
    bundle_id: str,
    deployment_target: str,
) -> Path:
    fw_dir = staging_dir / f"{framework_name}.framework"
    if fw_dir.exists():
        shutil.rmtree(fw_dir)
    headers_dir = fw_dir / "Headers"
    modules_dir = fw_dir / "Modules"
    headers_dir.mkdir(parents=True, exist_ok=True)
    modules_dir.mkdir(parents=True, exist_ok=True)

    shutil.copy2(static_lib, fw_dir / framework_name)
    shutil.copy2(header_file, headers_dir / header_file.name)
    (modules_dir / "module.modulemap").write_text(
        f'framework module {framework_name} {{\n'
        f'    umbrella header "{header_file.name}"\n'
        f'    export *\n'
        f'}}\n',
        encoding="utf-8",
    )
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": framework_name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": framework_name,
        "CFBundlePackageType": "FMWK",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "MinimumOSVersion": deployment_target,
    }
    (fw_dir / "Info.plist").write_bytes(plistlib.dumps(info))
    return fw_dir


def create_xcframework(frameworks: list[Path], output_xcframework: Path) -> None:
    if output_xcframework.exists():
        shutil.rmtree(output_xcframework)
    cmd = ["xcodebuild", "-create-xcframework"]
    for fw in frameworks:
        cmd.extend(["-framework", str(fw)])
    cmd.extend(["-output", str(output_xcframework)])
    subprocess.run(cmd, check=True)
