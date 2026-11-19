"""Offline unit tests for iOS asset generation, localization conversion, and IPA verification."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import generate_ios_assets
import ios_xcframework
import verify_ios_ipa


class IosToolsTest(unittest.TestCase):
    def test_android_format_specifiers_convert_for_ios(self) -> None:
        self.assertEqual(
            generate_ios_assets.convert_format_specifiers("All %1$d on %2$s (%d, %s)"),
            "All %1$ld on %2$@ (%ld, %@)",
        )
        self.assertEqual(
            generate_ios_assets.decode_android_string(r'"Can\'t connect\nRetry"'),
            "Can't connect\nRetry",
        )

    def test_all_swift_l10n_keys_exist_in_both_locales(self) -> None:
        import re
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resources = root / "GeneratedResources"
            catalog = root / "Assets.xcassets"
            generate_ios_assets.generate(resources, catalog)
            en_text = (resources / "Localizations/en.lproj/Localizable.strings").read_text(encoding="utf-8")
            zh_text = (resources / "Localizations/zh-Hans.lproj/Localizable.strings").read_text(encoding="utf-8")
            en_keys = set(re.findall(r'^"([^"]+)"\s*=', en_text, re.M))
            zh_keys = set(re.findall(r'^"([^"]+)"\s*=', zh_text, re.M))
            self.assertEqual(en_keys, zh_keys)
            swift_root = TOOLS_DIR.parent / "ios/Pebrel/Sources"
            missing = []
            for path in sorted(swift_root.rglob("*.swift")):
                txt = path.read_text(encoding="utf-8")
                for match in re.finditer(r'L10n\.tr\("([^"]+)"', txt):
                    key = match.group(1)
                    if "\\" not in key and key not in en_keys:
                        missing.append(f"{path.name}:{key}")
            self.assertEqual(missing, [], f"Missing L10n keys: {missing}")

    def test_generate_ios_assets_produces_complete_parity(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resources = root / "GeneratedResources"
            catalog = root / "Assets.xcassets"
            summary = generate_ios_assets.generate(resources, catalog)

            self.assertEqual(summary["themes"], 16)
            self.assertEqual(summary["host_icons"], 20)
            self.assertGreater(summary["en_strings"], 650)
            self.assertEqual(summary["en_strings"], summary["zh_strings"])

            self.assertTrue((resources / "themes.json").is_file())
            self.assertTrue((resources / "host-icons.json").is_file())
            self.assertTrue((resources / "ssh_agent_chat.py").is_file())
            self.assertTrue((resources / "Fonts/MapleMono-NF-CN-Regular.ttf").is_file())
            self.assertTrue((resources / "Fonts/JetBrainsMono-Regular.ttf").is_file())
            self.assertTrue((resources / "reader/katex/katex.min.js").is_file())
            self.assertTrue((resources / "Localizations/en.lproj/Localizable.strings").is_file())
            self.assertTrue((resources / "Localizations/zh-Hans.lproj/Localizable.strings").is_file())
            self.assertTrue((catalog / "AppIcon.appiconset/AppIcon-1024.png").is_file())

    def test_verify_ios_ipa_accepts_valid_and_rejects_tampered(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resources = root / "GeneratedResources"
            catalog = root / "Assets.xcassets"
            generate_ios_assets.generate(resources, catalog)

            app_dir = root / "Payload/Pebrel.app"
            app_dir.mkdir(parents=True)

            # Minimal valid arm64 Mach-O header (MH_MAGIC_64 + CPU_TYPE_ARM64)
            macho = struct.pack("<IIII", 0xFEEDFACF, 0x0100000C, 0, 2) + b"\x00" * 64
            (app_dir / "Pebrel").write_bytes(macho)

            info = {
                "CFBundleIdentifier": "io.github.kuddev.pebrel.mobile",
                "CFBundleExecutable": "Pebrel",
                "CFBundleShortVersionString": "2.5.0-preview",
                "CFBundleVersion": "1",
            }
            (app_dir / "Info.plist").write_bytes(plistlib.dumps(info))

            for name in ("themes.json", "host-icons.json", "ssh_agent_chat.py"):
                (app_dir / name).write_bytes((resources / name).read_bytes())
            for font in ("MapleMono-NF-CN-Regular.ttf", "JetBrainsMono-Regular.ttf"):
                (app_dir / font).write_bytes((resources / "Fonts" / font).read_bytes())
            for loc in ("en.lproj", "zh-Hans.lproj"):
                dst = app_dir / loc / "Localizable.strings"
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes((resources / "Localizations" / loc / "Localizable.strings").read_bytes())

            ipa_path = root / "Pebrel-test.ipa"
            with zipfile.ZipFile(ipa_path, "w") as zf:
                for p in sorted(app_dir.rglob("*")):
                    if p.is_file():
                        zf.write(p, p.relative_to(root).as_posix())
                for folder in ("reader", "licenses"):
                    for p in sorted((resources / folder).rglob("*")):
                        if p.is_file():
                            rel = Path("Payload/Pebrel.app") / folder / p.relative_to(resources / folder)
                            zf.write(p, rel.as_posix())

            report = verify_ios_ipa.verify(ipa_path, require_relay=False)
            self.assertEqual(report["bundle_id"], "io.github.kuddev.pebrel.mobile")
            self.assertEqual(report["themes"], 16)
            self.assertEqual(report["host_icons"], 20)

            # Negative case: require_relay fails when native-relay is absent
            with self.assertRaises(ValueError):
                verify_ios_ipa.verify(ipa_path, require_relay=True)

            # Negative case: non-arm64 executable fails
            bad_ipa = root / "Pebrel-bad.ipa"
            with zipfile.ZipFile(ipa_path, "r") as zin, zipfile.ZipFile(bad_ipa, "w") as zout:
                for item in zin.infolist():
                    if item.filename == "Payload/Pebrel.app/Pebrel":
                        zout.writestr(item, b"not-a-macho-binary-at-all")
                    else:
                        zout.writestr(item, zin.read(item.filename))
            with self.assertRaises(ValueError):
                verify_ios_ipa.verify(bad_ipa)

    def test_stage_static_framework_creates_valid_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_lib = root / "libdemo.a"
            fake_lib.write_bytes(b"!<arch>\n")
            fake_header = root / "demo_ffi.h"
            fake_header.write_text("#pragma once\nint demo_ping(void);\n", encoding="utf-8")

            fw = ios_xcframework.stage_static_framework(
                staging_dir=root / "staging",
                framework_name="PebrelDemo",
                static_lib=fake_lib,
                header_file=fake_header,
                bundle_id="io.github.kuddev.pebrel.mobile.demo",
                deployment_target="16.0",
            )
            self.assertEqual(fw, root / "staging/PebrelDemo.framework")
            self.assertEqual((fw / "PebrelDemo").read_bytes(), b"!<arch>\n")
            self.assertTrue((fw / "Headers/demo_ffi.h").is_file())
            modulemap = (fw / "Modules/module.modulemap").read_text(encoding="utf-8")
            self.assertIn('framework module PebrelDemo', modulemap)
            self.assertIn('umbrella header "demo_ffi.h"', modulemap)
            info = plistlib.loads((fw / "Info.plist").read_bytes())
            self.assertEqual(info["CFBundleExecutable"], "PebrelDemo")
            self.assertEqual(info["CFBundlePackageType"], "FMWK")
            self.assertEqual(info["CFBundleIdentifier"], "io.github.kuddev.pebrel.mobile.demo")
            self.assertEqual(info["MinimumOSVersion"], "16.0")


if __name__ == "__main__":
    unittest.main()
