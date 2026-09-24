#!/usr/bin/env python3
"""
Air-Waves 桌面端 — 静态资源装配脚本

职责：把「原项目根目录」里 WebView 真正需要的文件，复制到
      desktop/build/web/ ，最终被塞进 AirWaves.app/Contents/Resources/web 。

两条关键设计：

1) 不改动原项目
   只做「复制」，源文件一个字节都不动。原项目的
   start.sh / serve.py / 浏览器直开 三种方式继续可用。

2) 自动识别被引用的图片，而不是写死清单
   assets/ 里有 12 张图共 52MB，但代码只引用其中 3 张（约 16MB）。
   脚本用正则从 styles.css / app.js 里提取实际引用路径，
   于是：
     * 未引用的备选图自动排除，App 体积省下约 36MB
     * 如果上游改了引用（换了背景图），重新打包会自动跟上，
       不需要来这里改清单
   想强制全量打包时用 --all-assets。

用法：
    python3 stage_web.py                    # 装配到 desktop/build/web
    python3 stage_web.py --out /tmp/x       # 指定输出目录
    python3 stage_web.py --all-assets       # 包含 assets/ 全部文件
    python3 stage_web.py --list             # 只打印将要复制的文件（dry-run）
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 路径定位
#
# 本客户端可能以两种布局存在：
#   (a) 作为 Air-Waves 仓库的子目录：  Air-Waves/desktop/scripts/…
#   (b) 作为独立仓库与网页应用并列：  Air-Waves/  ← 网页应用
#                                     air-waves-macos/  ← 本仓库
#
# 所以不能写死「往上两级」，而是主动去找含 index.html 的目录。
# 实际使用时由 build.sh 通过 --root 显式传入，这里的自动探测只是兜底
# （便于单独运行本脚本做调试）。
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
DESKTOP_DIR = SCRIPT_DIR.parent


def locate_project_root() -> Path:
    """
    找到 Air-Waves 网页应用的根目录（含 index.html 的那一层）。

    候选顺序：
      1. 环境变量 AIRWAVES_WEB_ROOT（最高优先级，便于自定义布局）
      2. 上一层目录（独立仓库布局：与本仓库并列）
      3. 上两层目录（子目录布局：作为 Air-Waves/desktop 存在）
      4. 上一层目录下常见的几个名字（Air-Waves / Air-waves 等）
    """
    env = os.environ.get("AIRWAVES_WEB_ROOT")
    if env:
        return Path(env).expanduser().resolve()

    candidates = [
        DESKTOP_DIR.parent,                              # 独立仓库：并列布局
        DESKTOP_DIR.parent.parent,                       # 子目录：Air-Waves/desktop
    ]
    # 并列布局下，网页应用目录名可能大小写不一
    for name in ("Air-Waves", "Air-waves", "air-waves", "AirWaves"):
        candidates.append(DESKTOP_DIR.parent / name)

    for cand in candidates:
        if (cand / "index.html").is_file() and (cand / "app.js").is_file():
            return cand.resolve()

    # 都找不到时返回默认值，由调用方给出明确报错
    return candidates[0].resolve()


PROJECT_ROOT = locate_project_root()

# WebView 需要复制的顶层文件
WEB_FILES = [
    "index.html",
    "styles.css",
    "app.js",
    "audio.js",
]

# 顶层忽略项：这些是开发/构建产物，与运行时无关
IGNORED_TOP_LEVEL = {
    "desktop",
    "README.md",
    "START.md",
    ".git",
    ".gitignore",
    "__pycache__",
}

# 从代码里提取资源引用的正则
#   CSS: url("assets/scene/scene-player.png")  或  url(assets/...)
CSS_URL_RE = re.compile(r"""url\(\s*['"]?([^'")]+?)['"]?\s*\)""")
#   JS/HTML: 'assets/...'  或  "assets/..."
QUOTED_ASSET_RE = re.compile(r"""['"](assets/[^'"]+)['"]""")

# 这些扩展名才值得从 assets/ 里挑
ASSET_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg",
    ".woff", ".woff2", ".ttf", ".otf",
    ".mp3", ".wav", ".ogg", ".json",
}


def log(msg: str) -> None:
    print(f"[stage] {msg}", flush=True)


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024.0
    return f"{n:.1f} GB"


def discover_referenced_assets(root: Path) -> tuple[set[str], list[str]]:
    """
    扫描前端代码，返回它实际会去请求的资源相对路径集合。

    返回 (找到的路径集合, 扫描过程中发现缺失的文件列表)
    """
    referenced: set[str] = set()
    missing: list[str] = []

    sources = [root / name for name in WEB_FILES if (root / name).is_file()]
    # 顺带扫一遍 assets 之外的其它 js/css（本项目目前没有，留作扩展）
    for extra in root.glob("*.js"):
        if extra not in sources:
            sources.append(extra)
    for extra in root.glob("*.css"):
        if extra not in sources:
            sources.append(extra)

    for src in sources:
        try:
            text = src.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            log(f"警告：无法读取 {src.name}: {exc}")
            continue

        candidates: set[str] = set()
        candidates.update(m for m in CSS_URL_RE.findall(text) if m.startswith("assets/"))
        candidates.update(QUOTED_ASSET_RE.findall(text))

        for raw in candidates:
            # 去掉可能存在的查询串/锚点
            path_part = raw.split("?", 1)[0].split("#", 1)[0].strip()
            if not path_part:
                continue
            if Path(path_part).suffix.lower() not in ASSET_SUFFIXES:
                continue
            if (root / path_part).is_file():
                referenced.add(path_part)
            else:
                missing.append(path_part)

    return referenced, missing


def collect_assets(root: Path, all_assets: bool) -> tuple[list[Path], int, int]:
    """
    返回 (要复制的文件列表, 被引用数, 因未被引用而跳过的字节数)
    """
    assets_dir = root / "assets"
    if not assets_dir.is_dir():
        return [], 0, 0

    all_files = sorted(p for p in assets_dir.rglob("*") if p.is_file())

    if all_assets:
        return all_files, len(all_files), 0

    referenced, missing = discover_referenced_assets(root)
    for miss in missing:
        log(f"警告：代码引用了但文件不存在 —— {miss}")

    chosen: list[Path] = []
    skipped_bytes = 0
    for path in all_files:
        rel = path.relative_to(root).as_posix()
        if rel in referenced:
            chosen.append(path)
        else:
            skipped_bytes += path.stat().st_size

    log(f"从代码中识别到 {len(referenced)} 个被引用的资源：")
    for rel in sorted(referenced):
        log(f"    ✓ {rel}")
    if skipped_bytes:
        log(f"跳过 {len(all_files) - len(chosen)} 个未被引用的文件，"
            f"节省 {human(skipped_bytes)}")

    return chosen, len(referenced), skipped_bytes


def copy_file(src: Path, dst: Path) -> int:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return dst.stat().st_size


def main() -> int:
    parser = argparse.ArgumentParser(description="装配 Air-Waves 桌面端静态资源")
    parser.add_argument("--root", default=str(PROJECT_ROOT),
                        help="原项目根目录（默认自动推断）")
    parser.add_argument("--out", default=str(DESKTOP_DIR / "build" / "web"),
                        help="输出目录（默认 desktop/build/web）")
    parser.add_argument("--all-assets", action="store_true",
                        help="包含 assets/ 下全部文件（不做引用筛选）")
    parser.add_argument("--list", action="store_true", dest="dry_run",
                        help="只列出将要复制的文件，不实际写入")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    out = Path(args.out).resolve()

    if not (root / "index.html").is_file():
        log(f"错误：在 {root} 下找不到 index.html，请用 --root 指定项目根目录")
        return 2

    log(f"源目录: {root}")
    log(f"输出目录: {out}")

    # ---- 清空输出目录，保证打包结果可复现（不残留上一次的旧文件）----
    if out.exists() and not args.dry_run:
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    total_bytes = 0
    file_count = 0

    # ---- 1. 顶层 Web 文件 ----
    for name in WEB_FILES:
        src = root / name
        if not src.is_file():
            log(f"错误：缺少必需文件 {name}")
            return 3
        if args.dry_run:
            log(f"将复制 {name} ({human(src.stat().st_size)})")
        else:
            size = copy_file(src, out / name)
            total_bytes += size
        file_count += 1

    # ---- 2. 静态资源 ----
    assets, referenced_count, skipped_bytes = collect_assets(root, args.all_assets)
    if not assets:
        log("警告：没有找到任何 assets 资源，页面背景将不可用")

    for path in assets:
        rel = path.relative_to(root)
        if args.dry_run:
            log(f"将复制 {rel.as_posix()} ({human(path.stat().st_size)})")
        else:
            size = copy_file(path, out / rel)
            total_bytes += size
        file_count += 1

    if args.dry_run:
        log("dry-run 结束，未写入任何文件")
        return 0

    # ---- 3. 校验 ----
    must_exist = ["index.html", "styles.css", "app.js", "audio.js"]
    for name in must_exist:
        if not (out / name).is_file():
            log(f"错误：装配结果缺少 {name}")
            return 4

    log("装配完成")
    log(f"    文件数: {file_count}")
    log(f"    总体积: {human(total_bytes)}")
    if skipped_bytes:
        log(f"    相比全量打包节省: {human(skipped_bytes)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
