"""
Phase 4 图标包资源生成脚本

用法：uv run --with Pillow scripts/generate_icon_pack_resources.py

职责：
1. 从 assets/icon/icon2.png 提取白色前景（阈值 R≥250 && G≥250 && B≥250）
   → 生成 drawable/icon2_fg_white.png（透明背景，1024×1024，注意 PNG 名与 XML 不同避免重复资源）
2. 染色为 #2C3E50 深蓝
   → 生成 drawable/icon2_fg_dark.png（给 minimal 用，PNG 名与 XML 不同避免重复资源）
3. 为 4 套图标包各合成完整图标（背景色 + 前景），缩放到 5 个密度
   → 覆盖 mipmap-{density}/launcher_icon.png（default）
   → 新建 mipmap-{density}/launcher_icon_warm.png
   → 新建 mipmap-{density}/launcher_icon_festive.png
   → 新建 mipmap-{density}/launcher_icon_minimal.png

关键参数：
- 阈值 250：icon2 外围灰边框 R 在 197-245，安全低于阈值
- 反锯齿：R 在 230-249 的边缘像素按比例给 alpha，避免硬边 staircase
"""
import os
import numpy as np
from PIL import Image, ImageFilter

# 路径配置
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_ICON = os.path.join(ROOT, 'assets', 'icon', 'icon2.png')
RES_DIR = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
DRAWABLE_DIR = os.path.join(RES_DIR, 'drawable')

# 4 套图标包定义：(id, background_hex, foreground_type)
PACKS = [
    ('default', '#2C3E50', 'white'),   # 深蓝背景 + 白前景
    ('warm',    '#E65100', 'white'),   # 深橙背景 + 白前景
    ('festive', '#C62828', 'white'),   # 红色背景 + 白前景
    ('minimal', '#FAFAFA', 'dark'),    # 浅白背景 + 深蓝前景
]

DARK_TINT = (0x2C, 0x3E, 0x50)  # #2C3E50

# 5 个密度的 launcher icon 输出尺寸（px）
DENSITIES = {
    'mdpi':    48,
    'hdpi':    72,
    'xhdpi':   96,
    'xxhdpi':  144,
    'xxxhdpi': 192,
}


def hex_to_rgb(hex_str):
    """#RRGGBB → (r, g, b)"""
    h = hex_str.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))


def extract_foreground(src_path, dst_path, tint_color=None):
    """
    从 src_path 提取白色前景，保存到 dst_path（透明 PNG）。

    两阶段算法（修复外围灰边框污染问题）：
    1. 硬阈值 R/G/B 全部 >= 250 → 不透明前景（alpha=255）
    2. 对前景 mask 做形态学膨胀（2px），膨胀区域内的"浅色像素"视为反锯齿边缘
       - 浅色定义：R/G/B 全部 >= 220 且至少一个 < 250
       - alpha 按最小通道值线性映射（220→60，249→220）

    tint_color 不为 None 时，前景像素的 RGB 替换为 tint_color（保留 alpha）。
    """
    src = Image.open(src_path).convert('RGB')
    w, h = src.size
    arr = np.array(src)  # shape (h, w, 3)

    # 阶段 1：硬阈值得到前景 mask
    fg_mask = (arr[:, :, 0] >= 250) & (arr[:, :, 1] >= 250) & (arr[:, :, 2] >= 250)
    fg_count_raw = int(fg_mask.sum())

    # 阶段 1.5：形态学开运算（先腐蚀再膨胀），移除外围灰边框里的孤立白点噪声
    # icon2.png 在外层灰框里约有 262 个零散白点（AI 生成图的纹理噪声）
    fg_mask_img = Image.fromarray((fg_mask * 255).astype(np.uint8), 'L')
    # MinFilter(3) = 1px 腐蚀（去掉孤立点）；MaxFilter(3) = 1px 膨胀（恢复主体形状）
    opened = fg_mask_img.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
    fg_mask = np.array(opened) > 128
    fg_count = int(fg_mask.sum())

    # 阶段 2：膨胀 2px（在清理后的 mask 上），得到 AA 候选区域
    fg_mask_img = Image.fromarray((fg_mask * 255).astype(np.uint8), 'L')
    dilated = fg_mask_img.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MaxFilter(3))
    aa_zone = np.array(dilated) > 128  # 膨胀后的 mask

    # AA 候选：在膨胀区内，但不在原始前景内
    aa_candidates = aa_zone & (~fg_mask)

    # 浅色过滤：R/G/B 全部 >= 220 才算 AA 边缘（避免外围灰边框 RGB 197-245 被误纳入）
    light_mask = (arr[:, :, 0] >= 220) & (arr[:, :, 1] >= 220) & (arr[:, :, 2] >= 220)
    aa_mask = aa_candidates & light_mask

    # 构建 alpha 数组
    alpha = np.zeros((h, w), dtype=np.uint8)
    alpha[fg_mask] = 255

    # AA 边缘按最小通道值线性映射
    # arr[aa_mask] shape: (n_aa_pixels, 3)，按 axis=1 取每行最小值
    min_ch = np.min(arr[aa_mask], axis=1)  # shape (n_aa_pixels,)
    # min_ch 范围 220-249 → alpha 60-220
    aa_alpha = (60 + (min_ch.astype(np.int32) - 220) * (220 - 60) / (249 - 220)).clip(0, 255).astype(np.uint8)
    alpha[aa_mask] = aa_alpha

    aa_count = int(aa_mask.sum())

    # 构建 RGBA
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    if tint_color is not None:
        rgba[:, :, 0] = tint_color[0]
        rgba[:, :, 1] = tint_color[1]
        rgba[:, :, 2] = tint_color[2]
    else:
        rgba[:, :, 0] = 255
        rgba[:, :, 1] = 255
        rgba[:, :, 2] = 255
    rgba[:, :, 3] = alpha

    out = Image.fromarray(rgba, 'RGBA')
    out.save(dst_path)
    print(f'  -> {os.path.relpath(dst_path, ROOT)} ({w}x{h}, fg_raw={fg_count_raw} fg_after_opening={fg_count} aa={aa_count})')
    return out


def composite_full_icon(fg_img, bg_color_rgb, dst_path, size):
    """
    把前景 fg_img（RGBA）合成到 bg_color_rgb 背景上，缩放到 size×size。
    """
    # 先在 fg_img 原尺寸（1024×1024）上合成背景
    bg = Image.new('RGBA', fg_img.size, bg_color_rgb + (255,))
    composed = Image.alpha_composite(bg, fg_img)
    # 缩放到目标密度尺寸（LANCZOS 高质量）
    final = composed.resize((size, size), Image.LANCZOS)
    final.save(dst_path)
    print(f'  -> {os.path.relpath(dst_path, ROOT)} ({size}x{size})')


def main():
    print('=== Phase 4 icon pack resource generation ===')
    print(f'source: {os.path.relpath(SRC_ICON, ROOT)}')
    print()

    if not os.path.exists(SRC_ICON):
        print(f'ERROR: source icon missing: {SRC_ICON}')
        return 1

    os.makedirs(DRAWABLE_DIR, exist_ok=True)

    # === Step 1: extract white foreground ===
    print('[1/3] extract white foreground...')
    fg_white_path = os.path.join(DRAWABLE_DIR, 'icon2_fg_white.png')
    fg_white = extract_foreground(SRC_ICON, fg_white_path, tint_color=None)

    # === Step 2: tint dark foreground ===
    print('[2/3] tint dark foreground (for minimal pack)...')
    fg_dark_path = os.path.join(DRAWABLE_DIR, 'icon2_fg_dark.png')
    fg_dark = extract_foreground(SRC_ICON, fg_dark_path, tint_color=DARK_TINT)

    # === Step 3: composite 4 pack fallback PNGs (5 densities each) ===
    print('[3/3] composite 4 icon packs fallback PNGs...')

    for pack_id, bg_hex, fg_type in PACKS:
        print(f'  -- {pack_id} (bg={bg_hex}, fg={fg_type}) --')
        bg_rgb = hex_to_rgb(bg_hex)
        fg_img = fg_white if fg_type == 'white' else fg_dark

        for density, size in DENSITIES.items():
            mipmap_dir = os.path.join(RES_DIR, f'mipmap-{density}')
            os.makedirs(mipmap_dir, exist_ok=True)

            if pack_id == 'default':
                # default pack overwrites existing launcher_icon.png
                out_name = 'launcher_icon.png'
            else:
                out_name = f'launcher_icon_{pack_id}.png'

            dst_path = os.path.join(mipmap_dir, out_name)
            composite_full_icon(fg_img, bg_rgb, dst_path, size)

    print()
    print('DONE.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
