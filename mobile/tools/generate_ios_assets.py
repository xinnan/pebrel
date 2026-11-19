#!/usr/bin/env python3
"""Generate iOS bundle assets, AppIcon, reader bundle, notices, and Localizable.strings."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

from generate_assets import theme_palettes


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RESOURCES = ROOT / "mobile/ios/Pebrel/GeneratedResources"
DEFAULT_ASSETS_CATALOG = ROOT / "mobile/ios/Pebrel/Resources/Assets.xcassets"

IOS_EXTRA_STRINGS = {
    "en": {
        "ios_local_shell_title": "Local device shell unavailable on iOS",
        "ios_local_shell_body": "iOS sandboxing does not permit spawning a local shell process. Connect to your Pebrel desktop or an SSH host instead.",
        "ios_background_boundary": "iOS suspends network sockets shortly after entering the background. Pebrel preserves your drafts and transcripts and reconnects when you return.",
        "ios_camera_usage": "Pebrel uses the camera to scan desktop pairing QR codes on your device.",
        "ios_mic_usage": "Pebrel uses the microphone for local on-device voice transcription.",
        "ios_local_network_usage": "Pebrel discovers paired Pebrel desktops on your local network.",
        "ios_key_import_hint": "Import a private key file from Files.",
        "ios_copy_failed": "Could not copy to clipboard",
        "ios_sftp_downloaded": "Saved to Files",
        "ios_relay_export_ready": "Relay access JSON is ready to export",
        "ios_reader_open_external": "Open link",
        "ios_voice_unavailable": "Voice engine unavailable in this build.",
        "ios_session_terminal": "Terminal",
        "ios_session_conversation": "Conversation",
        "ios_all_files": "All files",
        "ios_copy_path": "Copy path",
        "ios_no_saved_hosts": "No saved SSH hosts yet",
        "ios_no_saved_computers": "No paired computers yet",
        "ios_edit_address_hint": "Example: 192.168.1.20:54321",
        "ios_notices_title": "Third-party notices",
        "create": "Create",
        "invalid_port": "Enter a port between 1 and 65535.",
        "invalid_username": "Enter a valid username.",
        "loading": "Loading…",
        "name": "Name",
        "ssh_session_name": "Session name (optional)",
    },
    "zh-Hans": {
        "ios_local_shell_title": "iOS 不支持本地设备终端",
        "ios_local_shell_body": "受 iOS 沙盒策略限制，应用无法拉起本地 Shell 进程。请连接 Pebrel 桌面端或通过 SSH 访问远程主机。",
        "ios_background_boundary": "iOS 进入后台后系统会很快挂起网络连接。Pebrel 会保留当前草稿与会话记录，并在回到前台后自动重连。",
        "ios_camera_usage": "Pebrel 需要使用相机在本地扫描桌面端配对二维码。",
        "ios_mic_usage": "Pebrel 需要使用麦克风进行本地离线语音转写。",
        "ios_local_network_usage": "Pebrel 需要访问本地网络以发现局域网内的 Pebrel 桌面端。",
        "ios_key_import_hint": "从“文件”导入私钥文件。",
        "ios_copy_failed": "无法复制到剪贴板",
        "ios_sftp_downloaded": "已保存到文件",
        "ios_relay_export_ready": "中继接入 JSON 已准备好导出",
        "ios_reader_open_external": "打开链接",
        "ios_voice_unavailable": "当前构建未启用本地语音引擎。",
        "ios_session_terminal": "终端",
        "ios_session_conversation": "对话",
        "ios_all_files": "全部文件",
        "ios_copy_path": "复制路径",
        "ios_no_saved_hosts": "暂无已保存的 SSH 主机",
        "ios_no_saved_computers": "暂无已配对的电脑",
        "ios_edit_address_hint": "例如：192.168.1.20:54321",
        "ios_notices_title": "第三方开源许可声明",
        "create": "创建",
        "invalid_port": "请输入 1 到 65535 之间的端口号。",
        "invalid_username": "请输入有效的用户名。",
        "loading": "加载中…",
        "name": "名称",
        "ssh_session_name": "会话名称（可选）",
    },
}

FORMAT_SPEC_RE = re.compile(r"%(?:(\d+)\$)?([sd])")


def decode_android_string(raw: str) -> str:
    """Decode Android string resource escaping into plain Unicode text."""
    text = raw.strip()
    if len(text) >= 2 and text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    out: list[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "n":
                out.append("\n")
            elif nxt == "t":
                out.append("\t")
            elif nxt in ("'", '"', "\\"):
                out.append(nxt)
            elif nxt == "u" and i + 5 < len(text):
                hex_part = text[i + 2 : i + 6]
                if re.fullmatch(r"[0-9a-fA-F]{4}", hex_part):
                    out.append(chr(int(hex_part, 16)))
                    i += 6
                    continue
                out.append(nxt)
            else:
                out.append(nxt)
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def convert_format_specifiers(text: str) -> str:
    """Convert Android Java/printf format tokens to Apple Foundation NSString tokens."""
    def replace(match: re.Match[str]) -> str:
        pos = match.group(1)
        kind = match.group(2)
        ios_kind = "@" if kind == "s" else "ld"
        return f"%{pos}${ios_kind}" if pos else f"%{ios_kind}"

    return FORMAT_SPEC_RE.sub(replace, text)


def escape_ios_strings_value(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def collect_android_strings(xml_dirs: list[Path]) -> dict[str, str]:
    entries: dict[str, str] = {}
    for directory in xml_dirs:
        if not directory.is_dir():
            continue
        for xml_file in sorted(directory.glob("*.xml")):
            root = ET.parse(xml_file).getroot()
            if root.tag != "resources":
                continue
            for child in root:
                name = child.attrib.get("name")
                if not name:
                    continue
                if child.tag == "string":
                    raw = "".join(child.itertext())
                    entries[name] = convert_format_specifiers(decode_android_string(raw))
                elif child.tag == "plurals":
                    for item in child:
                        if item.tag == "item":
                            qty = item.attrib.get("quantity", "other")
                            raw = "".join(item.itertext())
                            entries[f"{name}_{qty}"] = convert_format_specifiers(decode_android_string(raw))
    return entries


def write_localizable_strings(destination: Path, entries: dict[str, str]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    lines = ["/* Generated from mobile/android string resources by generate_ios_assets.py. Do not edit manually. */"]
    for key in sorted(entries):
        lines.append(f'"{escape_ios_strings_value(key)}" = "{escape_ios_strings_value(entries[key])}";')
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")


def generate_host_icons(root: Path) -> list[dict[str, str]]:
    icon_source = (root / "pebrel_app/src/display/ui/os_icons.rs").read_text(encoding="utf-8")
    catalog = icon_source.split("pub(crate) const CATALOG:", 1)[1].split("];", 1)[0]
    icons = []
    for body in re.findall(r"OsIcon \{ (.*?) \}", catalog):
        def field(name: str) -> str:
            match = re.search(rf'{name}: "([^"]+)"', body)
            if match is None:
                raise ValueError(f"Missing OsIcon field: {name}")
            return match.group(1)

        cp_match = re.search(r"glyph: '\\u\{([0-9a-f]+)\}'", body)
        if cp_match is None:
            raise ValueError("Missing OsIcon glyph codepoint")
        icons.append({
            "id": field("id"),
            "glyph": chr(int(cp_match.group(1), 16)),
            "zh": field("zh"),
            "en": field("en"),
        })
    if len(icons) != catalog.count("OsIcon {") or not any(icon["id"] == "term" for icon in icons):
        raise ValueError("Unparsed desktop host icon catalog")
    return icons


def generate_app_icon(root: Path, catalog: Path) -> None:
    catalog.mkdir(parents=True, exist_ok=True)
    (catalog / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    appicon = catalog / "AppIcon.appiconset"
    appicon.mkdir(parents=True, exist_ok=True)
    source_icon = root / "extra/logo/nebula-titanium.png"
    target_icon = appicon / "AppIcon-1024.png"
    shutil.copyfile(source_icon, target_icon)
    (appicon / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {
                        "filename": "AppIcon-1024.png",
                        "idiom": "universal",
                        "platform": "ios",
                        "size": "1024x1024",
                    }
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    brand_set = catalog / "PebrelLogo.imageset"
    brand_set.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source_icon, brand_set / "pebrel-logo.png")
    (brand_set / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    {"filename": "pebrel-logo.png", "idiom": "universal", "scale": "1x"},
                    {"idiom": "universal", "scale": "2x"},
                    {"idiom": "universal", "scale": "3x"},
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )


def generate(
    resources: Path,
    assets_catalog: Path,
    frameworks_dir: Path | None = None,
    relay_assets: Path | None = None,
) -> dict[str, int]:
    resources.mkdir(parents=True, exist_ok=True)

    # 1. Authoritative desktop palettes & host icons
    palettes = theme_palettes(
        (ROOT / "pebrel_settings/src/themes.rs").read_text(encoding="utf-8"),
        (ROOT / "pebrel_settings/src/lib.rs").read_text(encoding="utf-8"),
    )
    (resources / "themes.json").write_text(json.dumps(palettes, separators=(",", ":")), encoding="utf-8")

    icons = generate_host_icons(ROOT)
    (resources / "host-icons.json").write_text(json.dumps(icons, ensure_ascii=False), encoding="utf-8")

    # 2. Fonts
    fonts_dir = resources / "Fonts"
    fonts_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "assets/fonts/MapleMono-NF-CN-Regular.ttf", fonts_dir / "MapleMono-NF-CN-Regular.ttf")
    shutil.copyfile(ROOT / "assets/fonts/JetBrainsMono-Regular.ttf", fonts_dir / "JetBrainsMono-Regular.ttf")

    # 3. Rich reader bundle (KaTeX, Mermaid, highlight.js, reader.js, reader.css)
    reader_dst = resources / "reader"
    if reader_dst.exists():
        shutil.rmtree(reader_dst)
    shutil.copytree(ROOT / "mobile/android/app/src/main/assets/reader", reader_dst)

    # 4. SSH agent chat transcript reader script
    shutil.copyfile(
        ROOT / "mobile/android/app/src/main/res/raw/ssh_agent_chat.py",
        resources / "ssh_agent_chat.py",
    )

    # 5. Localization (.lproj/Localizable.strings) synced from Android XMLs
    en_strings = collect_android_strings([
        ROOT / "mobile/android/app/src/main/res/values",
        ROOT / "mobile/android/ghostty/src/main/res/values",
    ])
    zh_strings = collect_android_strings([
        ROOT / "mobile/android/app/src/main/res/values-zh-rCN",
        ROOT / "mobile/android/ghostty/src/main/res/values-zh-rCN",
    ])
    en_strings.update(IOS_EXTRA_STRINGS["en"])
    zh_strings.update(IOS_EXTRA_STRINGS["zh-Hans"])
    write_localizable_strings(resources / "Localizations/en.lproj/Localizable.strings", en_strings)
    write_localizable_strings(resources / "Localizations/zh-Hans.lproj/Localizable.strings", zh_strings)

    # 6. AppIcon & brand logo catalog
    generate_app_icon(ROOT, assets_catalog)

    # 7. Licenses & third-party notices
    licenses_dst = resources / "licenses"
    if licenses_dst.exists():
        shutil.rmtree(licenses_dst)
    licenses_dst.mkdir(parents=True, exist_ok=True)
    for license_file in sorted((ROOT / "mobile/android/third_party/licenses").glob("*.txt")):
        shutil.copyfile(license_file, licenses_dst / license_file.name)
    shutil.copyfile(ROOT / "LICENSE", licenses_dst / "GPL-3.0-only.txt")
    shutil.copyfile(ROOT / "mobile/android/ghostty/UPSTREAM.json", licenses_dst / "Ghostty-UPSTREAM.json")
    ios_notices = ROOT / "mobile/ios/THIRD-PARTY-NOTICES.md"
    if ios_notices.is_file():
        shutil.copyfile(ios_notices, licenses_dst / "THIRD-PARTY-NOTICES.md")
    else:
        shutil.copyfile(
            ROOT / "mobile/android/third_party/THIRD-PARTY-NOTICES.md",
            licenses_dst / "THIRD-PARTY-NOTICES.md",
        )
    if frameworks_dir is not None and (frameworks_dir / "licenses").is_dir():
        shutil.copytree(frameworks_dir / "licenses", licenses_dst, dirs_exist_ok=True)

    # 8. Optional embedded Linux pebrel-relay binaries for one-click SSH relay deployment
    native_relay_dst = resources / "native-relay"
    if native_relay_dst.exists():
        shutil.rmtree(native_relay_dst)
    if relay_assets is not None and relay_assets.is_dir():
        shutil.copytree(relay_assets, native_relay_dst)
    else:
        native_relay_dst.mkdir(parents=True, exist_ok=True)
        (native_relay_dst / ".placeholder").write_text(
            "Embedded Linux pebrel-relay binaries are populated during CI or --relay-assets builds.\n",
            encoding="utf-8",
        )

    return {
        "themes": len(palettes),
        "host_icons": len(icons),
        "en_strings": len(en_strings),
        "zh_strings": len(zh_strings),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, default=DEFAULT_RESOURCES)
    parser.add_argument("--assets-catalog", type=Path, default=DEFAULT_ASSETS_CATALOG)
    parser.add_argument("--frameworks-dir", type=Path, default=ROOT / "mobile/ios/Build/Frameworks")
    parser.add_argument("--relay-assets", type=Path, default=None)
    args = parser.parse_args()
    summary = generate(args.resources, args.assets_catalog, args.frameworks_dir, args.relay_assets)
    print(f"Generated iOS assets: {json.dumps(summary)}", flush=True)


if __name__ == "__main__":
    main()
