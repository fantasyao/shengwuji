"""
重新生成 icon2.png —— 渐变绿色圆角卡片 + 干净白色前景

抛弃有棋盘格残留的 icon2.png.bak，改用：
- icon2_fg_white.png 的白色前景（垃圾桶+麦克风+声波，已干净透明）
- Python 画的绿色渐变圆角矩形（对角线渐变，匹配原图卡片配色）

这样棋盘格问题彻底消失（不再依赖 AI 生成的 .bak），边缘由几何 mask 保证圆润。

输出：assets/icon/icon2.png（启动页专用，其他场景不用这个文件）
"""
import os
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FG_PATH = os.path.join(ROOT, 'assets', 'icon', 'icon2_fg_white.png')
DST = os.path.join(ROOT, 'assets', 'icon', 'icon2.png')

# 渐变端点色（从 icon2.png.bak 卡片区域采样）
TL_COLOR = (104, 232, 233)  # 左上 浅青蓝
BR_COLOR = (171, 236, 136)  # 右下 浅黄绿

# 卡片几何（匹配原图卡片位置，保证白色前景对齐）
LEFT, TOP, RIGHT, BOTTOM = 212, 213, 821, 841
CORNER_RADIUS = 135  # Material spec: 短边 × 22.2%
EXPAND = 4  # 补偿高斯模糊收缩（= blur_radius）


def main():
    print('=== regen icon2.png (gradient card + white foreground) ===')
    print(f'foreground: {os.path.relpath(FG_PATH, ROOT)}')
    print(f'output:     {os.path.relpath(DST, ROOT)}')
    print()

    # 1. 加载白色前景
    fg = Image.open(FG_PATH).convert('RGBA')
    W, H = fg.size
    print(f'[1] foreground: {W}x{H}')
    fg_arr = np.array(fg)

    # 2. 生成对角线渐变（左上 TL_COLOR → 右下 BR_COLOR）
    # t = (x/W + y/H) / 2，左上=0，右下=1
    t_x = np.linspace(0, 1, W, dtype=np.float32)[None, :]
    t_y = np.linspace(0, 1, H, dtype=np.float32)[:, None]
    t = (t_x + t_y) / 2.0
    grad = np.zeros((H, W, 3), dtype=np.float32)
    for c in range(3):
        grad[:, :, c] = TL_COLOR[c] * (1 - t) + BR_COLOR[c] * t
    print(f'[2] gradient: {TL_COLOR} -> {BR_COLOR}')

    # 3. 圆角矩形 mask（高斯模糊 4px 抗锯齿）
    mask = Image.new('L', (W, H), 0)
    draw = ImageDraw.Draw(mask)
    bbox = [LEFT - EXPAND, TOP - EXPAND, RIGHT + EXPAND, BOTTOM + EXPAND]
    try:
        draw.rounded_rectangle(bbox, radius=CORNER_RADIUS + EXPAND, fill=255)
    except TypeError:
        print('    [warn] Pillow too old, fallback to rectangle')
        draw.rectangle(bbox, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius=4))
    mask_arr = np.array(mask).astype(np.float32) / 255.0
    print(f'[3] rounded rect mask: {bbox} radius={CORNER_RADIUS + EXPAND}')

    # 4. 合成绿色渐变卡片（渐变色 × mask = 卡片，mask 外透明）
    card_rgba = np.zeros((H, W, 4), dtype=np.float32)
    for c in range(3):
        card_rgba[:, :, c] = grad[:, :, c] * mask_arr
    card_rgba[:, :, 3] = mask_arr * 255.0
    card_img = Image.fromarray(card_rgba.clip(0, 255).astype(np.uint8), 'RGBA')
    print(f'[4] gradient card composited')

    # 5. 叠加白色前景（alpha_composite：前景白色覆盖卡片）
    final = Image.alpha_composite(card_img, fg)
    final.save(DST, optimize=True)
    file_size = os.path.getsize(DST)
    print(f'[5] saved: {os.path.relpath(DST, ROOT)} ({file_size} bytes)')
    print()

    # === 像素级验证 ===
    verify(final, mask_arr, fg_arr, W, H)


def verify(img, mask_arr, fg_arr, W, H):
    """像素级验证新 icon2.png"""
    arr = np.array(img)
    alpha = arr[:, :, 3]
    rgb = arr[:, :, :3]

    print('=== verification ===')

    # 四角必须透明（alpha=0），RGB 也应为 0（无棋盘格残留）
    print('corners (expect alpha=0):')
    for name, x, y in [('TL', 0, 0), ('TR', W-1, 0), ('BL', 0, H-1), ('BR', W-1, H-1)]:
        r2, g2, b2, a2 = img.getpixel((x, y))
        ok = 'OK' if a2 == 0 else 'FAIL'
        print(f'  {name} ({x},{y}): RGBA=({r2},{g2},{b2},{a2}) [{ok}]')

    # 卡片中心应该有内容（绿色或白色前景）
    cx, cy = (LEFT + RIGHT) // 2, (TOP + BOTTOM) // 2
    r2, g2, b2, a2 = img.getpixel((cx, cy))
    print(f'card center ({cx},{cy}): RGBA=({r2},{g2},{b2},{a2}) (alpha should be 255)')

    # 卡片边缘（非圆角处）应该 alpha=255
    edge_points = [(LEFT + 10, TOP + 10), (RIGHT - 10, BOTTOM - 10)]
    for x, y in edge_points:
        r2, g2, b2, a2 = img.getpixel((x, y))
        print(f'card corner area ({x},{y}): RGBA=({r2},{g2},{b2},{a2})')

    # alpha 分布
    total = alpha.size
    opaque = (alpha == 255).sum()
    transparent = (alpha == 0).sum()
    partial = total - opaque - transparent
    print(f'alpha distribution:')
    print(f'  opaque(255)  : {opaque/total*100:.1f}%')
    print(f'  transparent  : {transparent/total*100:.1f}%')
    print(f'  partial(AA)  : {partial/total*100:.1f}%')

    # 透明区 RGB 残留检查（关键：棋盘格清零验证）
    alpha_zero = alpha == 0
    if alpha_zero.sum() > 0:
        rgb_in_transparent = rgb[alpha_zero]
        nonzero = ((rgb_in_transparent[:, 0] != 0) |
                   (rgb_in_transparent[:, 1] != 0) |
                   (rgb_in_transparent[:, 2] != 0)).sum()
        status = 'OK' if nonzero == 0 else 'FAIL'
        print(f'transparent RGB residue: {nonzero}/{alpha_zero.sum()} [{status}]')

    # 不透明区域边界（应接近卡片 610x629）
    opaque_mask = alpha == 255
    rows = np.any(opaque_mask, axis=1)
    cols = np.any(opaque_mask, axis=0)
    if rows.any():
        t = int(np.argmax(rows))
        b = int(len(rows) - 1 - np.argmax(rows[::-1]))
        l = int(np.argmax(cols))
        r = int(len(cols) - 1 - np.argmax(cols[::-1]))
        print(f'opaque bbox: ({l},{t})-({r},{b}) ({r-l+1}x{b-t+1})')
        print(f'(card ref:  {LEFT},{TOP}-{RIGHT},{BOTTOM} {RIGHT-LEFT+1}x{BOTTOM-TOP+1})')

    # 白色前景是否保留
    white_pixels = ((rgb[:, :, 0] >= 250) & (rgb[:, :, 1] >= 250) &
                    (rgb[:, :, 2] >= 250) & (alpha == 255)).sum()
    print(f'white foreground pixels: {white_pixels} (icon2_fg_white had ~17808)')

    print()
    print('DONE.')


if __name__ == '__main__':
    main()
