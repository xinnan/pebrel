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

import build_ios_ghostty
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

    def test_zig_host_pin_selects_linux_and_macos_and_rejects_unknown(self) -> None:
        pins = json.loads(build_ios_ghostty.PINS.read_text(encoding="utf-8"))
        url, sha, archive = build_ios_ghostty.zig_host_pin("Linux", "x86_64", pins)
        self.assertEqual(url, pins["zig_url"])
        self.assertEqual(sha, pins["zig_sha256"])
        self.assertEqual(archive, "zig-linux-x86_64.tar.xz")

        url_arm, sha_arm, archive_arm = build_ios_ghostty.zig_host_pin("Linux", "aarch64", pins)
        self.assertEqual(url_arm, pins["zig_linux_arm64_url"])
        self.assertEqual(sha_arm, pins["zig_linux_arm64_sha256"])
        self.assertEqual(archive_arm, "zig-linux-arm64.tar.xz")

        url_mac, _, archive_mac = build_ios_ghostty.zig_host_pin("Darwin", "arm64", pins)
        self.assertIn("aarch64-macos-0.15.2", url_mac)
        self.assertEqual(archive_mac, "zig-aarch64-macos.tar.xz")

        with self.assertRaises(SystemExit):
            build_ios_ghostty.zig_host_pin("Windows", "AMD64", pins)
        with self.assertRaises(SystemExit):
            build_ios_ghostty.zig_host_pin("Linux", "riscv64", pins)

    def test_write_static_vt_wrapper_references_ghostty_static_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sources = root / "sources/ghostty"
            sources.mkdir(parents=True)
            wrapper = build_ios_ghostty.write_static_vt_wrapper(root / "wrapper", sources)
            zon = (wrapper / "build.zig.zon").read_text(encoding="utf-8")
            zig = (wrapper / "build.zig").read_text(encoding="utf-8")
            self.assertIn('.path = "../sources/ghostty"', zon)
            self.assertIn("0x9362cfe2028b69d2", zon)
            self.assertIn('ghostty.artifact("ghostty-vt-static")', zig)
            self.assertIn('"libghostty-vt.a"', zig)

    def test_resolve_prebuilt_vt_and_licenses_positive_and_negative(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # Layout 1: CI artifact / ghostty work root (`out/<slice>`, `licenses/Ghostty`, `PREBUILT.json`)
            art = root / "artifact"
            lib = art / "out/ios-arm64/lib/libghostty-vt.a"
            hdr = art / "out/ios-arm64/include/ghostty/vt.h"
            lib.parent.mkdir(parents=True)
            hdr.parent.mkdir(parents=True)
            lib.write_bytes(b"!<arch>\nfake")
            hdr.write_text("#pragma once\n", encoding="utf-8")
            (art / "PREBUILT.json").write_text(json.dumps({"revision": "rev-abc"}), encoding="utf-8")
            lic = art / "licenses/Ghostty/Ghostty-MIT.txt"
            lic.parent.mkdir(parents=True)
            lic.write_text("MIT", encoding="utf-8")

            resolved_lib, resolved_inc = build_ios_ghostty.resolve_prebuilt_vt(
                art, "ios-arm64", expected_revision="rev-abc"
            )
            self.assertEqual(resolved_lib, lib.resolve())
            self.assertEqual(resolved_inc, (art / "out/ios-arm64/include").resolve())

            dst_lic = root / "dst-licenses"
            build_ios_ghostty.copy_prebuilt_licenses(art, dst_lic)
            self.assertEqual((dst_lic / "Ghostty-MIT.txt").read_text(encoding="utf-8"), "MIT")

            # Layout 2: passing `--output` root of `--vt-only` (`ghostty/out/<slice>`, `ghostty/licenses/Ghostty`)
            out_root = root / "vt-only-out"
            lib2 = out_root / "ghostty/out/ios-arm64-simulator/lib/libghostty-vt.a"
            hdr2 = out_root / "ghostty/out/ios-arm64-simulator/include/ghostty/vt.h"
            lib2.parent.mkdir(parents=True)
            hdr2.parent.mkdir(parents=True)
            lib2.write_bytes(b"!<arch>\nsim")
            hdr2.write_text("#pragma once\n", encoding="utf-8")
            lic2 = out_root / "ghostty/licenses/Ghostty/Zig-MIT.txt"
            lic2.parent.mkdir(parents=True)
            lic2.write_text("ZIG", encoding="utf-8")

            resolved_lib2, _ = build_ios_ghostty.resolve_prebuilt_vt(out_root, "ios-arm64-simulator")
            self.assertEqual(resolved_lib2, lib2.resolve())
            dst_lic2 = root / "dst-licenses-2"
            build_ios_ghostty.copy_prebuilt_licenses(out_root, dst_lic2)
            self.assertEqual((dst_lic2 / "Zig-MIT.txt").read_text(encoding="utf-8"), "ZIG")

            # Negative case 1: mismatched revision in PREBUILT.json
            with self.assertRaises(ValueError):
                build_ios_ghostty.resolve_prebuilt_vt(art, "ios-arm64", expected_revision="rev-different")

            # Negative case 2: missing slice
            with self.assertRaises(FileNotFoundError):
                build_ios_ghostty.resolve_prebuilt_vt(art, "ios-arm64-simulator", expected_revision="rev-abc")

            # Negative case 3: zero-byte archive rejected
            lib.write_bytes(b"")
            with self.assertRaises(FileNotFoundError):
                build_ios_ghostty.resolve_prebuilt_vt(art, "ios-arm64", expected_revision="rev-abc")

    def test_extract_ar_members_handles_unaligned_bsd_archive_and_rejects_invalid(self) -> None:
        def bsd_member(name: str, payload: bytes) -> bytes:
            name_bytes = name.encode("utf-8")
            # Mirror Zig 0.15.2's 4-byte-padded BSD `#1/<n>` member name length.
            padded_len = (len(name_bytes) + 3) & ~3
            padded_name = name_bytes.ljust(padded_len, b"\x00")
            body = padded_name + payload
            hdr = (
                f"#1/{padded_len:<13}"
                f"{'0':<12}"
                f"{'0':<6}"
                f"{'0':<6}"
                f"{'100644':<8}"
                f"{len(body):<10}"
                "`\n"
            ).encode("ascii")
            assert len(hdr) == 60
            return hdr + body + (b"\n" if len(body) % 2 == 1 else b"")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            macho_a = struct.pack("<IIII", 0xFEEDFACF, 0x0100000C, 0, 1) + b"AAAA"
            macho_b = struct.pack("<IIII", 0xFEEDFACF, 0x0100000C, 0, 1) + b"BBBB"
            archive = root / "libghostty-vt.a"
            archive.write_bytes(
                b"!<arch>\n"
                + bsd_member("__.SYMDEF", b"\x00" * 16)
                + bsd_member("libghostty-vt-static_zcu.o", macho_a)
                + bsd_member("compiler_rt.o", macho_b)
            )
            extracted = build_ios_ghostty.extract_ar_members(archive, root / "objs")
            self.assertEqual([p.name for p in extracted], ["000-libghostty-vt-static_zcu.o", "001-compiler_rt.o"])
            self.assertEqual(extracted[0].read_bytes(), macho_a)
            self.assertEqual(extracted[1].read_bytes(), macho_b)

            # Negative case: invalid magic
            bad = root / "not-an-archive.a"
            bad.write_bytes(b"NOT_AR")
            with self.assertRaises(ValueError):
                build_ios_ghostty.extract_ar_members(bad, root / "bad-objs")

            # Negative case: symbol table only (no objects)
            sym_only = root / "sym-only.a"
            sym_only.write_bytes(b"!<arch>\n" + bsd_member("__.SYMDEF", b"\x00" * 8))
            with self.assertRaises(ValueError):
                build_ios_ghostty.extract_ar_members(sym_only, root / "sym-objs")

    def test_ios_app_icon_is_full_bleed_opaque_rgb_without_black_frame(self) -> None:
        import zlib
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            catalog = root / "Assets.xcassets"
            generate_ios_assets.generate_app_icon(generate_ios_assets.ROOT, catalog)
            icon_path = catalog / "AppIcon.appiconset/AppIcon-1024.png"
            data = icon_path.read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", data[16:29])
            self.assertEqual((width, height), (1024, 1024))
            self.assertEqual(bit_depth, 8)
            self.assertEqual(color_type, 2)  # RGB only (no alpha channel)
            self.assertEqual(interlace, 0)

            # Decompress first and middle scanlines to verify opaque titanium corners and dark central mark.
            pos = 8
            idat = bytearray()
            while pos + 8 <= len(data):
                length, ctype = struct.unpack(">I4s", data[pos : pos + 8])
                if ctype == b"IDAT":
                    idat.extend(data[pos + 8 : pos + 8 + length])
                pos += 12 + length
            raw = zlib.decompress(bytes(idat))
            row_stride = 1 + width * 3
            self.assertEqual(len(raw), height * row_stride)
            # Top-left and top-right corners must match the titanium tile color (#D9DFE6), never black.
            self.assertEqual(tuple(raw[1:4]), (217, 223, 230))
            self.assertEqual(tuple(raw[1 + (width - 1) * 3 : 1 + width * 3]), (217, 223, 230))
            # Center pixel must belong to the dark pebble mark (luminance well below background).
            mid_off = (height // 2) * row_stride + 1 + (width // 2) * 3
            self.assertLess(sum(raw[mid_off : mid_off + 3]) / 3, 100)

            # Negative case: invalid PNG bytes rejected
            bad = root / "bad.png"
            bad.write_bytes(b"not-a-png")
            with self.assertRaises(ValueError):
                generate_ios_assets.render_opaque_ios_app_icon(bad, root / "out.png")


if __name__ == "__main__":
    unittest.main()
