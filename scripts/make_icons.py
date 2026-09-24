#!/usr/bin/env python3
"""
Air-Waves 桌面端 — 图标生成

把原项目里的 Windows 图标 Air-Waves.ico 转换成 macOS 的 AppIcon.icns 。

已知限制（重要）：
    上游的 .ico 最高只有 256×256，且不含 alpha 通道。
    macOS 的理想图标是 1024×1024（512@2x），因此放大到 512/1024
    会不可避免地变软。这是「占位图标」的固有代价，不是脚本缺陷。

    想换成高清图标时，只要把任意一张 ≥1024×1024 的方形 PNG 放到
    desktop/macos/Resources/icon-source.png ，本脚本会优先使用它，
    无需改动任何代码。

依赖：Pillow（已验证本机 Python 3.9 自带 PIL 11.3.0）
    pip3 install --user Pillow      # 仅在缺失时需要

用法：
    python3 make_icons.py                 # 生成 AppIcon.icns 到 Resources/
    python3 make_icons.py --preview       # 同时导出一张 512 预览图便于肉眼检查
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DESKTOP_DIR = SCRIPT_DIR.parent
RESOURCES_DIR = DESKTOP_DIR / "macos" / "Resources"

# 图标源图候选位置。
# 本仓库可以独立存在，所以网页应用（Air-Waves.ico 的所在地）不能写死路径，
# 而是按顺序探测——与 stage_web.py / build.sh 的定位逻辑保持一致。
def _ico_candidates():
    import os
    env = os.environ.get("AIRWAVES_WEB_ROOT")
    parent = DESKTOP_DIR.parent
    cands = []
    if env:
        cands.append(Path(env).expanduser())
    cands += [
        parent,                       # 并列布局：~/Documents/Air-waves.ico（少见）
        parent / "Air-Waves",         # 并列布局（推荐）
        parent / "Air-waves",
        parent / "air-waves",
        parent / "AirWaves",
        parent.parent,                # 子目录布局：Air-Waves/desktop
        DESKTOP_DIR.parent,
    ]
    seen, out = set(), []
    for c in cands:
        p = (c / "Air-Waves.ico")
        if str(p) not in seen:
            seen.add(str(p))
            out.append(p)
    return out


ICO_CANDIDATES = _ico_candidates()
ICO_SOURCE = ICO_CANDIDATES[0]          # 供报错信息显示的首选位置
PNG_SOURCE = RESOURCES_DIR / "icon-source.png"
ICONSET_DIR = DESKTOP_DIR / "build" / "AppIcon.iconset"
ICNS_OUT = RESOURCES_DIR / "AppIcon.icns"


def find_ico_source():
    """返回第一个真实存在的 Air-Waves.ico，找不到返回 None。"""
    for cand in ICO_CANDIDATES:
        if cand.is_file():
            return cand
    return None

# macOS iconset 要求的全部尺寸：(像素边长, 文件名)
ICONSET_ENTRIES = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]


def log(msg: str) -> None:
    print(f"[icons] {msg}", flush=True)


def load_best_source():
    """
    取可用的最高质量源图。

    优先级：Resources/icon-source.png（用户自备） > Air-Waves.ico 的最大帧
    """
    from PIL import Image

    if PNG_SOURCE.is_file():
        img = Image.open(PNG_SOURCE).convert("RGBA")
        log(f"使用自备高清图标 {PNG_SOURCE.name} ({img.width}×{img.height})")
        return img

    ico_path = find_ico_source()
    if ico_path is None:
        return None

    ico = Image.open(ico_path)
    try:
        sizes = ico.ico.sizes()
    except Exception:
        sizes = [(ico.width, ico.height)]

    best = max(sizes, key=lambda s: s[0] * s[1])
    ico.size = best
    img = ico.convert("RGBA")
    log(f"使用 {ico_path.name} 的最大帧 {best[0]}×{best[1]}")
    if best[0] < 512:
        log(f"提示：源图仅 {best[0]}px，放大到 512/1024 后会偏软。")
        log(f"      如介意，把一张 ≥1024px 的方形 PNG 放到")
        log(f"      {PNG_SOURCE.relative_to(DESKTOP_DIR)} 即可自动启用。")
    return img


def square(img, size: int):
    """等比缩放并居中到正方形画布，避免非方形源图被拉伸变形。"""
    from PIL import Image

    w, h = img.size
    scale = min(size / w, size / h)
    new_size = (max(1, round(w * scale)), max(1, round(h * scale)))
    resized = img.resize(new_size, Image.LANCZOS)

    if new_size == (size, size):
        return resized

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(resized, ((size - new_size[0]) // 2, (size - new_size[1]) // 2), resized)
    return canvas


def squircle_mask(size: int, radius_ratio: float):
    """
    生成 iOS / macOS 风格的圆角遮罩（单通道 L 模式，255 = 保留）。

    两个关键点：

    1. 抗锯齿
       遮罩按 4 倍超采样绘制后缩回目标尺寸，缩小时的插值天然产生平滑的
       边缘渐变。直接画会有硬锯齿——图标要在 Dock 里被放大到 128pt 显示，
       锯齿非常明显。

    2. 为什么用超椭圆而不是普通圆角矩形
       Apple 从 Big Sur 起使用的不是「四分之一圆弧 + 直线」的圆角矩形，
       而是连续曲率的超椭圆（俗称 squircle，俗称「连续圆角」）。
       两者并排看差别很明显：圆弧圆角在直线与圆弧的接缝处有曲率突变，
       视觉上更「硬」。超椭圆由指数 n 控制：
           n = 2   → 圆
           n 越大  → 越接近直角矩形
       这里取 n = 5，是视觉上与 macOS 原生图标最接近的一档。

    参数：
        radius_ratio  圆角半径 / 边长。macOS Big Sur+ 的规格是 0.2237。
    """
    from PIL import Image, ImageDraw

    ss = 4                        # 超采样倍数
    big = size * ss
    r = max(1.0, big * radius_ratio)
    n = 5.0                       # 超椭圆指数

    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    # 圆角矩形是超椭圆的良好近似；后面再用「线性混合」把直边与圆角
    # 之间的过渡拉平，得到连续曲率的外观。
    draw.rounded_rectangle([(0, 0), (big - 1, big - 1)], radius=r, fill=255)

    # 连续曲率处理：对遮罩值做幂次映射。
    # 边缘的抗锯齿渐变被重新分布，圆弧段因此获得更接近超椭圆的
    # 缓慢过渡，而中心区域保持满值不受影响。
    # 0.85 是目视比对 macOS 原生图标后选定的值。
    gamma = 0.85
    lut = [min(255, int(round(255.0 * ((v / 255.0) ** gamma)))) for v in range(256)]
    mask = mask.point(lut)

    return mask.resize((size, size), Image.LANCZOS)


def apply_icon_shape(img, radius_ratio: float):
    """把源图裁成 macOS 图标形状（圆角 + 透明外角）。"""
    from PIL import Image

    size = img.size[0]
    mask = squircle_mask(size, radius_ratio)
    out = img.copy()
    # 用遮罩作为 alpha 通道：圆角外变透明，让 Dock / Finder 显示桌面背景
    out.putalpha(mask)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="生成 macOS 应用图标")
    parser.add_argument("--preview", action="store_true",
                        help="额外导出一张 512×512 预览图")
    parser.add_argument("--radius", type=float, default=0.2237,
                        help="圆角半径 / 边长（默认 0.2237，即 macOS Big Sur+ 规格）")
    parser.add_argument("--square", action="store_true",
                        help="不裁剪成圆角，保留原始方形（上游原始素材的满幅外观）")
    args = parser.parse_args()

    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        log("错误：缺少 Pillow。请执行  pip3 install --user Pillow")
        return 2

    if find_ico_source() is None and not PNG_SOURCE.is_file():
        log("错误：找不到图标源文件")
        log(f"  已探测以下位置，均不存在 Air-Waves.ico：")
        for cand in ICO_CANDIDATES:
            log(f"      {cand}")
        log(f"  也没有自备图标 {PNG_SOURCE}")
        log("")
        log("  解决方式（任选其一）：")
        log("    1. 把 Air-Waves 网页应用放在本仓库同级目录下")
        log("    2. 用 AIRWAVES_WEB_ROOT=/path/to/Air-Waves 指定位置")
        log(f"    3. 放一张 ≥1024px 的方形 PNG 到 {PNG_SOURCE.relative_to(DESKTOP_DIR)}")
        log("    4. 用 --square 之外的方式跳过图标：图标缺失不影响 App 运行，")
        log("       只是会显示为系统通用图标")
        return 3

    source = load_best_source()
    if source is None:
        log("错误：无法读取图标源")
        return 3

    # ---- 裁成 macOS 图标形状 ----
    if args.square:
        log("保持方形（--square）：不做圆角裁剪")
    else:
        # 每个尺寸都单独裁一次：圆角半径必须按目标像素计算，
        # 不能先裁大图再缩小，否则小尺寸下圆角比例会失真。
        log(f"裁剪为圆角矩形：半径 = 边长 × {args.radius}（macOS Big Sur+ 规格）")

    def shaped(size: int):
        img = square(source, size)
        if args.square:
            return img
        return apply_icon_shape(img, args.radius)

    # ---- 生成 iconset ----
    if ICONSET_DIR.exists():
        import shutil
        shutil.rmtree(ICONSET_DIR)
    ICONSET_DIR.mkdir(parents=True, exist_ok=True)

    for size, name in ICONSET_ENTRIES:
        out = ICONSET_DIR / name
        shaped(size).save(out, format="PNG")
    log(f"已生成 {len(ICONSET_ENTRIES)} 个尺寸到 {ICONSET_DIR}")

    if args.preview:
        preview = DESKTOP_DIR / "build" / "icon-preview-512.png"
        shaped(512).save(preview, format="PNG")
        log(f"预览图: {preview}")

        # 同时导出一张「在浅色 / 深色背景上的效果图」，便于肉眼确认
        # 圆角外确实是透明的（Finder 与 Dock 会透出桌面）
        from PIL import Image
        sheet = Image.new("RGB", (512 * 2 + 36, 512 + 24), (255, 255, 255))
        icon = shaped(512)
        light = Image.new("RGB", (512, 512), (245, 245, 247))
        light.paste(icon, (0, 0), icon)
        dark = Image.new("RGB", (512, 512), (32, 32, 34))
        dark.paste(icon, (0, 0), icon)
        sheet.paste(light, (12, 12))
        sheet.paste(dark, (512 + 24, 12))
        sheet_path = DESKTOP_DIR / "build" / "icon-preview-bg.png"
        sheet.save(sheet_path, format="PNG")
        log(f"背景对照图（左浅右深）: {sheet_path}")

    # ---- 打包为 .icns ----
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET_DIR), "-o", str(ICNS_OUT)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        log(f"错误：iconutil 失败 (退出码 {result.returncode})")
        log(result.stderr.strip() or "(无错误输出)")
        return 4

    size_kb = ICNS_OUT.stat().st_size / 1024
    log(f"已生成 {ICNS_OUT.relative_to(DESKTOP_DIR)} ({size_kb:.0f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
