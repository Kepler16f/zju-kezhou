#!/usr/bin/env python3
"""make_icons.py — 从 assets/brand/icon_source.png 生成全平台应用图标。

源图特征（实测）：1024×1024 RGB，整幅圆角矩形（半径≈22.2%），四角为白色；
白船 + 笔的白色主体居中，右下角有极淡的 "AI" 水印。

产物（全部写回仓库，CI 直接取用）：
  assets/brand/  icon_master_1024.png（满幅方形，四角由径向镜像补全）
                 icon_rounded_1024.png（圆角矩形，角外透明）
                 icon_round_1024.png（正圆，角外透明）
                 icon_foreground_1024.png（只有船+笔，透明底）
                 icon_background_1024.png（满幅渐变背景）
                 icon_preview.png（对照预览：方形/圆角/圆形）
  android/app/src/main/res/  mipmap-*/ic_launcher.png（圆角，旧版）
                             mipmap-*/ic_launcher_round.png（正圆）
                             mipmap-*/ic_launcher_foreground.png（自适应前景）
                             mipmap-*/ic_launcher_background.png（自适应背景）
                             mipmap-anydpi-v26/ic_launcher{,_round}.xml
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png（满幅不透明方形，iOS 自行裁圆角）
  macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png（按 HIG 的圆角方，留边）
  windows/runner/resources/app_icon.ico（多尺寸，圆角透明）
  assets/brand/ohos/  app_icon.png / icon.png / startIcon.png / foreground.png
                      / background.png / layered_image.json（鸿蒙分层图标）

用法：python packaging/make_icons.py [--only android,windows,...]
"""
import argparse
import io
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'compass_app')
SRC = os.path.join(APP, 'assets', 'brand', 'icon_source.png')
BRAND = os.path.join(APP, 'assets', 'brand')

CORNER_RATIO = 0.222  # 源图圆角半径 / 边长（实测 ≈227/1024）
SS = 4  # 遮罩超采样倍数（抗锯齿）


def _log(msg):
    print('[icons] %s' % msg)


def load_source():
    im = Image.open(SRC).convert('RGBA')
    return im


def detect_radius(im, white=250):
    """从另一角探测圆角半径：行 0 / 列 0 上第一段"非白"像素的起点。"""
    w, h = im.size
    px = im.load()
    xs = []
    for x in range(w):
        r, g, b, _ = px[x, 0]
        if r < white or g < white or b < white:
            xs.append(x)
            break
    for x in range(w - 1, -1, -1):
        r, g, b, _ = px[x, 0]
        if r < white or g < white or b < white:
            xs.append(w - 1 - x)
            break
    for y in range(h):
        r, g, b, _ = px[0, y]
        if r < white or g < white or b < white:
            xs.append(y)
            break
    for y in range(h - 1, -1, -1):
        r, g, b, _ = px[0, y]
        if r < white or g < white or b < white:
            xs.append(h - 1 - y)
            break
    if not xs:
        return int(min(w, h) * CORNER_RATIO)
    xs.sort()
    r = xs[len(xs) // 2]
    return max(4, r)


def _neighbor_fill(a, unknown, iters=600):
    """调和填充：未知像素每轮取"已知四邻"的平均值，洋葱式向内推进。
    a: (H,W,4) float；unknown: (H,W) bool（就地修改 a）。无回卷（用 pad 取邻）。"""
    import numpy as np
    h, w = unknown.shape
    known = ~unknown
    if not unknown.any():
        return a
    for _ in range(iters):
        p = np.pad(a, ((1, 1), (1, 1), (0, 0)))
        k = np.pad(known.astype(float), 1)
        s = np.zeros_like(a)
        c = np.zeros((h, w))
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            kk = k[1 + dy:h + 1 + dy, 1 + dx:w + 1 + dx]
            s += p[1 + dy:h + 1 + dy, 1 + dx:w + 1 + dx] * kk[:, :, None]
            c += kk
        front = unknown & (c > 0)
        if not front.any():
            break
        a[front] = s[front] / c[front][:, None]
        known |= front
        unknown &= ~front
    return a


def fill_corners(im, r):
    """四角（圆角外）用调和填充补全：以弧内真实像素为边界向内扩散，
    没有反射法的接缝与白边问题。逐角在子图上算，避免整幅开销。"""
    import numpy as np
    a = np.asarray(im.convert('RGBA')).astype(float)
    h, w = a.shape[:2]
    # 边界有一圈白色抗锯齿：把它也划入"未知"（erode 6px），否则会被
    # 当作已知色向角区扩散出白条纹。
    inside = _erode(inside_shape_mask(w, h, r), 6)
    out = a.copy()
    for x0, y0, x1, y1 in ((0, 0, r + 8, r + 8), (w - r - 8, 0, w, r + 8),
                           (0, h - r - 8, r + 8, h), (w - r - 8, h - r - 8, w, h)):
        sub = out[y0:y1, x0:x1]
        unknown = ~inside[y0:y1, x0:x1]
        _neighbor_fill(sub, unknown.copy(), iters=3 * r)
    return Image.fromarray(np.clip(out, 0, 255).astype('uint8'), 'RGBA')


def inside_shape_mask(w, h, r):
    """圆角矩形（半径 r、铺满画布）的内部区域布尔矩阵。"""
    import numpy as np
    ys, xs = np.mgrid[0:h, 0:w]
    out = np.ones((h, w), dtype=bool)
    for cx, cy, xq, yq in ((r, r, xs < r, ys < r),
                           (w - 1 - r, r, xs > w - 1 - r, ys < r),
                           (r, h - 1 - r, xs < r, ys > h - 1 - r),
                           (w - 1 - r, h - 1 - r, xs > w - 1 - r, ys > h - 1 - r)):
        d = np.hypot(xs - cx, ys - cy)
        out &= ~(xq & yq & (d > r))
    return out


def _erode(m, n=1):
    import numpy as np
    for _ in range(n):
        p = np.pad(m, 1, constant_values=False)
        m = (p[1:-1, 1:-1] & p[:-2, 1:-1] & p[2:, 1:-1]
             & p[1:-1, :-2] & p[1:-1, 2:])
    return m


def _dilate(m, n=1):
    import numpy as np
    for _ in range(n):
        p = np.pad(m, 1)
        m = (p[1:-1, 1:-1] | p[:-2, 1:-1] | p[2:, 1:-1]
             | p[1:-1, :-2] | p[1:-1, 2:])
    return m


def remove_watermark(im, r):
    """抹掉右下角淡白 "AI" 水印。

    水印笔画太淡（与背景差仅 5-30 灰阶），阈值分割总会残留笔画碎片；
    这里直接把水印所在矩形的"圆角内部"整块作为未知区做调和填充：
    边界是最外一圈真实像素，区域仅 ~120×95px，平滑渐变插值误差极小。"""
    import numpy as np
    w, h = im.size
    a = np.asarray(im.convert('RGBA')).astype(float)
    inside = inside_shape_mask(w, h, r)
    rect = np.zeros((h, w), dtype=bool)
    # 覆盖水印完整范围（"AI" 笔画最高到 y≈860、最左到 x≈800），且完全
    # 低于船体（字标 bbox 到 y≈808）。
    rect[int(h * 0.82):, int(w * 0.76):] = True
    unknown = rect & inside
    if not unknown.any():
        return im, None
    ys, xs = np.where(unknown)
    box = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
    # 在子窗口上填充（快）。注意：形状外的白色角区也必须标为未知——
    # 否则它们会作为"已知"边界把白色渗进插值结果里。
    x0, y0 = max(0, box[0] - 1), max(0, box[1] - 1)
    x1, y1 = min(w, box[2] + 1), min(h, box[3] + 1)
    sub = a[y0:y1, x0:x1]
    sub_unknown = unknown[y0:y1, x0:x1] | ~inside[y0:y1, x0:x1]
    _neighbor_fill(sub, sub_unknown, iters=600)
    return Image.fromarray(np.clip(a, 0, 255).astype('uint8'), 'RGBA'), box


def rounded_mask(size, radius, supersample=SS):
    w, h = size
    m = Image.new('L', (w * supersample, h * supersample), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, w * supersample - 1, h * supersample - 1],
                        radius=radius * supersample, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def circle_mask(size, supersample=SS):
    w, h = size
    m = Image.new('L', (w * supersample, h * supersample), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([0, 0, w * supersample - 1, h * supersample - 1], fill=255)
    return m.resize((w, h), Image.LANCZOS)


def apply_mask(im, mask):
    out = im.copy()
    out.putalpha(mask)
    return out


def extract_foreground(im, r):
    """按"白色程度"提取船+笔：min(RGB) 150→0，210→1，仅限圆角内部
    （排除四角白底与右下角水印），再裁到主体外接框。"""
    import numpy as np
    w, h = im.size
    a = np.asarray(im.convert('RGBA')).astype(float)
    # 圆角边界有一圈白色抗锯齿，向内收缩 6px 再取，避免被当成字标
    inside = _erode(inside_shape_mask(w, h, r), 6)
    mn = a[:, :, :3].min(axis=2)
    alpha = np.clip((mn - 150.0) / 60.0, 0, 1)
    alpha[~inside] = 0
    alpha[int(h * 0.80):, int(w * 0.72):] = 0  # 右下角水印区整体排除
    strong = alpha > 0.5
    if not strong.any():
        return Image.new('RGBA', (w, h), (0, 0, 0, 0)), (0, 0, w, h)
    ys, xs = np.where(strong)
    x0, y0 = int(xs.min()), int(ys.min())
    x1, y1 = int(xs.max()) + 1, int(ys.max()) + 1
    pad = int((y1 - y0) * 0.02) + 2
    x0, y0 = max(0, x0 - pad), max(0, y0 - pad)
    x1, y1 = min(w, x1 + pad), min(h, y1 + pad)
    rgba = a.copy()
    rgba[:, :, 3] = np.round(alpha * 255)
    rgba[alpha <= 0.02] = 0
    out = Image.fromarray(np.clip(rgba, 0, 255).astype('uint8'), 'RGBA')
    cleaned = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    cleaned.paste(out.crop((x0, y0, x1, y1)), (x0, y0))
    return cleaned, (x0, y0, x1, y1)


def fit_glyph(fg, bbox, canvas, ratio):
    """把字标缩放到边长 canvas、主体占 ratio 的比例，居中。"""
    x0, y0, x1, y1 = bbox
    glyph = fg.crop((x0, y0, x1, y1))
    gw, gh = glyph.size
    target = int(canvas * ratio)
    scale = min(target / gw, target / gh)
    nw, nh = max(1, int(gw * scale)), max(1, int(gh * scale))
    glyph = glyph.resize((nw, nh), Image.LANCZOS)
    out = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    out.paste(glyph, ((canvas - nw) // 2, (canvas - nh) // 2), glyph)
    return out


def save_png(im, path, force_rgb=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if force_rgb:
        im = im.convert('RGB')
    im.save(path)
    _log('wrote %s (%dx%d%s)' % (os.path.relpath(path, ROOT), im.width, im.height,
                                 ', RGB' if force_rgb else ''))


def gen_android(master, rounded, circle, fg, bg, radius_px_1024):
    res = os.path.join(APP, 'android', 'app', 'src', 'main', 'res')
    legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    adaptive = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
    for dpi, size in legacy.items():
        r = max(2, int(round(radius_px_1024 * size / 1024.0)))
        sq = apply_mask(master.resize((size, size), Image.LANCZOS),
                        rounded_mask((size, size), r, supersample=4))
        save_png(sq, os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher.png'))
        ci = apply_mask(master.resize((size, size), Image.LANCZOS),
                        circle_mask((size, size), supersample=4))
        save_png(ci, os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher_round.png'))
    for dpi, size in adaptive.items():
        save_png(fg.resize((size, size), Image.LANCZOS),
                 os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher_foreground.png'))
        save_png(bg.resize((size, size), Image.LANCZOS),
                 os.path.join(res, 'mipmap-%s' % dpi, 'ic_launcher_background.png'))
    anydpi = os.path.join(res, 'mipmap-anydpi-v26')
    os.makedirs(anydpi, exist_ok=True)
    for name in ('ic_launcher', 'ic_launcher_round'):
        xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
               '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
               '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
               '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
               '</adaptive-icon>\n')
        with io.open(os.path.join(anydpi, '%s.xml' % name), 'w', encoding='utf-8', newline='\n') as f:
            f.write(xml)
        _log('wrote %s.xml' % os.path.relpath(os.path.join(anydpi, name), ROOT))


def gen_ios(master):
    base = os.path.join(APP, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    sizes = {
        'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
        'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
        'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180,
        'Icon-App-76x76@1x.png': 76, 'Icon-App-76x76@2x.png': 152,
        'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }
    for name, size in sizes.items():
        save_png(master.resize((size, size), Image.LANCZOS),
                 os.path.join(base, name), force_rgb=True)


def gen_macos(master):
    """macOS：HIG 圆角方，内容约占 82.4%，四周留白。"""
    base = os.path.join(APP, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    sizes = {'app_icon_16.png': 16, 'app_icon_32.png': 32, 'app_icon_64.png': 64,
             'app_icon_128.png': 128, 'app_icon_256.png': 256,
             'app_icon_512.png': 512, 'app_icon_1024.png': 1024}
    for name, size in sizes.items():
        inset = size * (1 - 0.824) / 2.0
        inner = max(1, int(round(size - 2 * inset)))
        r = max(2, int(round(inner * 0.2237)))
        tile = apply_mask(master.resize((inner, inner), Image.LANCZOS),
                          rounded_mask((inner, inner), r, supersample=4))
        canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        canvas.paste(tile, (int(round(inset)), int(round(inset))), tile)
        save_png(canvas, os.path.join(base, name))


def gen_windows(rounded):
    path = os.path.join(APP, 'windows', 'runner', 'resources', 'app_icon.ico')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    rounded.resize((256, 256), Image.LANCZOS).save(path, format='ICO',
                                                   sizes=sizes)
    _log('wrote %s (%d sizes)' % (os.path.relpath(path, ROOT), len(sizes)))


def gen_ohos(rounded, fg, bg):
    base = os.path.join(BRAND, 'ohos')
    os.makedirs(base, exist_ok=True)
    icon = rounded.resize((1024, 1024), Image.LANCZOS)
    for name in ('app_icon.png', 'icon.png', 'startIcon.png'):
        save_png(icon, os.path.join(base, name))
    save_png(fg.resize((1024, 1024), Image.LANCZOS), os.path.join(base, 'foreground.png'))
    save_png(bg.resize((1024, 1024), Image.LANCZOS), os.path.join(base, 'background.png'))
    layered = {
        'layered-image': {
            'background': '$media:background',
            'foreground': '$media:foreground',
        }
    }
    with io.open(os.path.join(base, 'layered_image.json'), 'w',
                 encoding='utf-8', newline='\n') as f:
        json.dump(layered, f, indent=2, ensure_ascii=False)


def gen_brand(master, rounded, circle, fg, bg):
    save_png(master, os.path.join(BRAND, 'icon_master_1024.png'))
    save_png(rounded, os.path.join(BRAND, 'icon_rounded_1024.png'))
    save_png(circle, os.path.join(BRAND, 'icon_round_1024.png'))
    save_png(fg, os.path.join(BRAND, 'icon_foreground_1024.png'))
    save_png(bg, os.path.join(BRAND, 'icon_background_1024.png'))
    # 预览图：方形 / 圆角 / 圆形 三态并排（浅灰棋盘底）
    cell = 256
    prev = Image.new('RGB', (cell * 3 + 40, cell + 20), (238, 240, 244))
    for i, im in enumerate((master, rounded, circle)):
        t = im.resize((cell, cell), Image.LANCZOS)
        prev.paste(t, (10 + i * (cell + 10), 10), t)
    save_png(prev.convert('RGB'), os.path.join(BRAND, 'icon_preview.png'), force_rgb=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', default='brand,android,ios,macos,windows,ohos')
    args = ap.parse_args()
    only = set(x.strip() for x in args.only.split(',') if x.strip())

    if not os.path.exists(SRC):
        sys.exit('缺少源图：%s' % SRC)
    src = load_source()
    side = src.width
    r = detect_radius(src)
    _log('源图 %dx%d，圆角半径 %d（%.1f%%）' % (side, side, r, 100.0 * r / side))

    src, wm = remove_watermark(src, r)   # 先清水印：角区反射才不会带上水印
    if wm:
        _log('已抹除右下角水印框 %s' % (wm,))
    master = fill_corners(src, r)                      # 满幅方形
    radius = int(round(side * CORNER_RATIO))
    rounded = apply_mask(master, rounded_mask((side, side), radius))
    circle = apply_mask(master, circle_mask((side, side)))
    fg_raw, bbox = extract_foreground(src, r)
    _log('字标外接框 %s' % (bbox,))
    fg = fit_glyph(fg_raw, bbox, side, 0.62)           # 安全区：主体 ≤62%
    bg = master

    if 'brand' in only:
        gen_brand(master, rounded, circle, fg, bg)
    if 'android' in only:
        gen_android(master, rounded, circle, fg, bg, radius)
    if 'ios' in only:
        gen_ios(master)
    if 'macos' in only:
        gen_macos(master)
    if 'windows' in only:
        gen_windows(rounded)
    if 'ohos' in only:
        gen_ohos(rounded, fg, bg)
    _log('完成')


if __name__ == '__main__':
    main()
