#!/usr/bin/env python3
# fblib.py -- 直接写 /dev/fb0 的最小绘图库（BGRA a8r8g8b8, 1080x2340, stride 4320）
import os, mmap, numpy as np
from PIL import Image, ImageDraw, ImageFont

FB = "/dev/fb0"
FB_W, FB_H = 1080, 2340
FB_BYTES = FB_W * FB_H * 4
FONT_REG = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"
FONT_MONO = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"

_font_cache = {}

BRIGHTNESS = 1.0        # 全局软件调光系数（0.15 .. 1.0）；blit() 时对 RGB 缩放

def font(size, mono=False):
    key = (size, mono)
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(FONT_MONO if mono else FONT_REG, size)
    return _font_cache[key]

def new_surface(color=(0, 0, 0)):
    """返回一个 RGB 画布 (PIL Image)"""
    return Image.new("RGB", (FB_W, FB_H), color)

def blit(img, box=None, brightness=None):
    """把 RGB PIL Image 贴到 /dev/fb0。box=(x,y) 时只贴该图尺寸的区域（局部刷新）"""
    if img.mode != "RGB":
        img = img.convert("RGB")
    a = np.asarray(img, dtype=np.uint8)
    b = BRIGHTNESS if brightness is None else brightness
    if b < 0.999:
        if b < 0.02:
            b = 0.02
        a = (a.astype(np.uint16) * int(b * 256) >> 8).astype(np.uint8)
    h, w = a.shape[0], a.shape[1]
    bgra = np.empty((h, w, 4), dtype=np.uint8)
    bgra[..., 0] = a[..., 2]   # B
    bgra[..., 1] = a[..., 1]   # G
    bgra[..., 2] = a[..., 0]   # R
    bgra[..., 3] = 255         # A
    payload = bgra.tobytes()
    fd = os.open(FB, os.O_RDWR)
    try:
        m = mmap.mmap(fd, FB_BYTES, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        try:
            if box is None:
                m[:] = payload
            else:
                x0, y0 = box
                row = w * 4
                src = 0
                for y in range(y0, y0 + h):
                    off = (y * FB_W + x0) * 4
                    m[off:off + row] = payload[src:src + row]
                    src += row
        finally:
            m.close()
    finally:
        os.close(fd)

def grab():
    """从 /dev/fb0 读回当前画面 -> RGB PIL Image（用于截图）"""
    fd = os.open(FB, os.O_RDONLY)
    try:
        m = mmap.mmap(fd, FB_BYTES, mmap.MAP_SHARED, mmap.PROT_READ)
        try:
            tmp = np.frombuffer(m, dtype=np.uint8)
            arr = tmp.reshape(FB_H, FB_W, 4).copy()   # copy: 不持有 mmap 视图
            del tmp
        finally:
            m.close()
    finally:
        os.close(fd)
    rgb = np.empty((FB_H, FB_W, 3), dtype=np.uint8)
    rgb[..., 0] = arr[..., 2]
    rgb[..., 1] = arr[..., 1]
    rgb[..., 2] = arr[..., 0]
    return Image.fromarray(rgb, "RGB")

def wrap(draw, text, f, maxw):
    """按像素宽度换行（支持中文，逐字符断行）"""
    out = []
    for raw in text.split("\n"):
        line = ""
        for ch in raw:
            if draw.textlength(line + ch, font=f) <= maxw:
                line += ch
            else:
                out.append(line)
                line = ch
        out.append(line)
    return out

def draw_lines(draw, text, f, x, y, maxw, fill=(255, 255, 255), spacing=1.25, align="center"):
    lines = wrap(draw, text, f, maxw)
    lh = int(f.size * spacing)
    for ln in lines:
        if align == "center":
            w = draw.textlength(ln, font=f)
            draw.text((x + (maxw - w) / 2, y), ln, font=f, fill=fill)
        elif align == "right":
            w = draw.textlength(ln, font=f)
            draw.text((x + maxw - w, y), ln, font=f, fill=fill)
        else:
            draw.text((x, y), ln, font=f, fill=fill)
        y += lh
    return y - int(f.size * spacing) + lh   # 返回下一行基线

def message(text, size=72, bg=(8, 10, 16), fg=(235, 240, 255), sub=None,
            sub_size=48, sub_fg=(140, 150, 170), accent=None):
    """全屏居中显示一段中文/英文信息"""
    img = new_surface(bg)
    d = ImageDraw.Draw(img)
    f = font(size)
    maxw = FB_W - 120
    lines = wrap(d, text, f, maxw)
    lh = int(size * 1.30)
    total = lh * len(lines)
    fs = None
    ys = (FB_H - total) // 2
    if accent is not None:
        d.rectangle([0, ys - 60, FB_W, ys - 54], fill=accent)
    y = ys
    for ln in lines:
        w = d.textlength(ln, font=f)
        d.text(((FB_W - w) / 2, y), ln, font=f, fill=fg)
        y += lh
    if sub:
        fs = font(sub_size)
        y += 40
        for ln in wrap(d, sub, fs, maxw):
            w = d.textlength(ln, font=fs)
            d.text(((FB_W - w) / 2, y), ln, font=fs, fill=sub_fg)
            y += int(sub_size * 1.30)
    blit(img)
    return img
