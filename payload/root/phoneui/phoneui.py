#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# phoneui.py -- 小米9 (SM8150) 无 X 手机 GUI
#   显示: 直接写 /dev/fb0 (simplefb 1080x2340 BGRA)，DSI 自动扫描取帧
#   输入: 原始 evdev
#           * 按键: 音量+ / 音量- / 电源(长按=主页) / HOME 键
#           * 触摸: 多点协议 B(MT slots) + 单点(ABS_X/Y)，点按 / 拖动滚动
#           * 远程: /run/phoneui.fifo
#   远程: key up|down|ok|back|home | app <名> | auto on|off | bright 0.2-1.0
#         shot [路径] | toast <文本> | tap x y | drag dy | touch x y down|move|up | quit
import os, sys, time, struct, select, math, subprocess, fcntl
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fblib
from PIL import Image, ImageDraw, ImageFont

W, H = fblib.FB_W, fblib.FB_H
STATUS_H = 104
NAV_H = 120
CONTENT_Y0 = STATUS_H
CONTENT_Y1 = H - NAV_H
FIFO = "/run/phoneui.fifo"
HOME = os.path.dirname(os.path.abspath(__file__))

BG      = (12, 14, 22)
SURF    = (23, 27, 40)
SURF2   = (33, 40, 58)
ACCENT  = (0, 200, 255)
ACCENT2 = (255, 92, 160)
GREEN   = (80, 235, 150)
YELLOW  = (255, 210, 90)
TEXT    = (236, 240, 252)
DIM     = (146, 158, 186)
RED     = (255, 96, 96)

FMT = struct.Struct("llHHi")
KEYMAP = {115: "up", 114: "down", 116: "power", 172: "home", 158: "back", 102: "home",
          103: "up", 108: "down", 28: "ok", 139: "menu", 352: "ok", 176: "menu", 113: "back"}
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2F, 0x35, 0x36, 0x39
ABS_RANGES = {ABS_X: (0, 1079), ABS_Y: (0, 2339),
              ABS_MT_POSITION_X: (0, 1079), ABS_MT_POSITION_Y: (0, 2339)}

_C = {}
def cached(key, ttl, fn):
    e = _C.get(key); now = time.time()
    if e is not None and now - e[0] < ttl:
        return e[1]
    try:
        v = fn()
    except Exception:
        v = e[1] if e else None
    _C[key] = (now, v)
    return v

def sh(cmd, timeout=5):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""

def rd(path, dflt=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return dflt

def loadavg():
    p = rd("/proc/loadavg", "0 0 0").split()
    return p[0] if p else "?"

def uptime_s():
    try:
        return float(rd("/proc/uptime", "0 0").split()[0])
    except Exception:
        return 0.0

def temp(zone="thermal_zone5"):
    try:
        return int(rd("/sys/class/thermal/%s/temp" % zone, "0")) / 1000.0
    except Exception:
        return None

def net_info():
    def f():
        ip = ""
        out = sh("ip -4 -brief addr show wlan0 2>/dev/null").split()
        if len(out) >= 3:
            ip = out[2].split("/")[0]
        linked = rd("/sys/class/net/wlan0/carrier", "0") == "1"
        return (ip, linked, rd("/sys/class/net/wlan0/operstate", "?"))
    return cached("net", 4, f)

def meminfo():
    def f():
        mi = {}
        with open("/proc/meminfo") as fh:
            for ln in fh:
                k, v = ln.split(":", 1)
                mi[k] = int(v.strip().split()[0])
        return mi
    return cached("mem", 3, f)

def temps():
    def f():
        out = []
        for i in range(32):
            t = "/sys/class/thermal/thermal_zone%d" % i
            if os.path.exists(t + "/temp"):
                try:
                    out.append((rd(t + "/type", "z%d" % i), int(rd(t + "/temp")) / 1000.0))
                except Exception:
                    pass
        out.sort(key=lambda x: -x[1])
        return out
    return cached("temps", 3, f)

def df_root():
    def f():
        p = sh("df -h / | tail -1").split()
        return (p[2], p[1]) if len(p) > 3 else ("?", "?")
    return cached("df", 20, f)

def dmesg_lines():
    return cached("dmesg", 3, lambda: sh("dmesg", timeout=6).splitlines())

def ssid():
    return cached("ssid", 10, lambda: sh("iw dev wlan0 link 2>/dev/null | awk '/SSID/{print $2}'") or "-")

def gw():
    return cached("gw", 15, lambda: sh("ip route | awk '/default/{print $3; exit}'") or "-")


# ---------------------------------------------------------------- 图标
def icon(d, kind, cx, cy, r, col):
    lw = max(4, r // 8)
    if kind == "clock":
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=lw)
        d.line([cx, cy, cx, cy - r * 0.62], fill=col, width=lw)
        d.line([cx, cy, cx + r * 0.5, cy + r * 0.30], fill=col, width=lw)
        d.ellipse([cx - lw, cy - lw, cx + lw, cy + lw], fill=col)
    elif kind == "chip":
        w = h = r * 0.85
        d.rounded_rectangle([cx - w, cy - h, cx + w, cy + h], r * 0.18, outline=col, width=lw)
        d.rectangle([cx - w * 0.35, cy - h * 0.35, cx + w * 0.35, cy + h * 0.35], fill=col)
        for i in (-0.5, 0, 0.5):
            for s in (-1, 1):
                d.line([cx + w * i, cy + s * h, cx + w * i, cy + s * (h + r * 0.3)], fill=col, width=lw)
                d.line([cx + s * w, cy + h * i, cx + s * (w + r * 0.3), cy + h * i], fill=col, width=lw)
    elif kind == "display":
        w, h = r, r * 0.72
        d.rounded_rectangle([cx - w, cy - h, cx + w, cy + h], r * 0.12, outline=col, width=lw)
        d.line([cx - w * 0.4, cy + h * 1.5, cx + w * 0.4, cy + h * 1.5], fill=col, width=lw)
        d.line([cx, cy + h, cx, cy + h * 1.5], fill=col, width=lw)
        for i in range(3):
            d.rectangle([cx - w * 0.7, cy - h * (0.55 - i * 0.45),
                         cx + w * 0.7, cy - h * (0.30 - i * 0.45)], fill=col)
    elif kind == "log":
        for i in range(5):
            x2 = cx + r * (0.85 if i % 3 else 0.45)
            d.line([cx - r, cy - r * 0.6 + i * r * 0.3, x2, cy - r * 0.6 + i * r * 0.3], fill=col, width=lw)
        d.rounded_rectangle([cx - r - lw, cy - r * 0.9, cx + r + lw, cy + r * 0.9],
                            r * 0.15, outline=col, width=max(3, lw - 2))
    elif kind == "wifi":
        for rr in (r, r * 0.66, r * 0.33):
            d.arc([cx - rr, cy - rr + r * 0.35, cx + rr, cy + rr + r * 0.35], 200, 340, fill=col, width=lw)
        d.ellipse([cx - lw, cy + r * 0.42, cx + lw, cy + r * 0.42 + lw * 2], fill=col)
    elif kind == "term":
        d.rounded_rectangle([cx - r, cy - r * 0.8, cx + r, cy + r * 0.8], r * 0.14, outline=col, width=lw)
        d.line([cx - r * 0.6, cy - r * 0.3, cx - r * 0.15, cy], fill=col, width=lw)
        d.line([cx - r * 0.6, cy + r * 0.3, cx - r * 0.15, cy], fill=col, width=lw)
        d.line([cx + r * 0.1, cy + r * 0.45, cx + r * 0.65, cy + r * 0.45], fill=col, width=lw)
    elif kind == "touch":
        d.ellipse([cx - r * 0.55, cy - r * 0.55, cx + r * 0.55, cy + r * 0.55], outline=col, width=lw)
        d.ellipse([cx - r * 0.18, cy - r * 0.18, cx + r * 0.18, cy + r * 0.18], fill=col)
        for a in (0, 90, 180, 270):
            ax, ay = math.cos(math.radians(a)), math.sin(math.radians(a))
            d.line([cx + ax * r * 0.7, cy + ay * r * 0.7, cx + ax * r * 1.15, cy + ay * r * 1.15],
                   fill=col, width=lw)
    elif kind == "folder":
        d.rounded_rectangle([cx - r, cy - r * 0.62, cx + r * 0.1, cy - r * 0.2], r * 0.12, fill=col)
        d.rounded_rectangle([cx - r, cy - r * 0.38, cx + r, cy + r * 0.72], r * 0.16, outline=col, width=lw)
    elif kind == "gear":
        d.ellipse([cx - r * 0.45, cy - r * 0.45, cx + r * 0.45, cy + r * 0.45], outline=col, width=lw)
        for i in range(8):
            a = math.radians(i * 45)
            d.line([cx + math.cos(a) * r * 0.6, cy + math.sin(a) * r * 0.6,
                    cx + math.cos(a) * r * 1.05, cy + math.sin(a) * r * 1.05], fill=col, width=lw)
    elif kind == "info":
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=lw)
        d.ellipse([cx - lw, cy - r * 0.5 - lw, cx + lw, cy - r * 0.5 + lw], fill=col)
        d.line([cx, cy - r * 0.1, cx, cy + r * 0.55], fill=col, width=lw)
    elif kind == "power":
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=lw)
        d.rectangle([cx - lw * 0.8, cy - r * 1.15, cx + lw * 0.8, cy], fill=col)


# ---------------------------------------------------------------- 触摸
class TouchReader:
    """原始 evdev 多点触摸解析：输出 ('down'|'move'|'up', x, y, t)"""
    def __init__(self, fd, name):
        self.fd, self.name = fd, name
        self.slots = {}        # slot -> [x, y, tid]
        self.prev = {}         # tid -> (x, y)
        self.single = [None, None]
        self.cur_slot = 0
        self.has_mt = False
        self.scale_x, self.scale_y = 1.0, 1.0
        for code, attr in ((ABS_MT_POSITION_X, "scale_x"), (ABS_MT_POSITION_Y, "scale_y")):
            lo, hi = self.abs_range(code)
            if hi > lo:
                setattr(self, attr, (W if attr == "scale_x" else H) / float(hi - lo + 1))
        lo, hi = self.abs_range(ABS_MT_POSITION_X)
        if hi > lo:
            self.has_mt = True

    def abs_range(self, code):
        # EVIOCGABS(code) = _IOR('E', 0x40+code, struct input_absinfo[24])
        try:
            buf = fcntl.ioctl(self.fd, 0x80184540 | code, b"\0" * 24)
        except Exception:
            return ABS_RANGES.get(code, (0, 0))
        v, lo, hi, fz, fl, res = struct.unpack("iiiiii", buf)
        return lo, hi

    def _sx(self, v):
        return max(0, min(W - 1, int(v * self.scale_x)))

    def _sy(self, v):
        return max(0, min(H - 1, int(v * self.scale_y)))

    def read(self):
        try:
            data = os.read(self.fd, FMT.size * 128)
        except Exception:
            return []
        if not data:
            return []
        out = []
        for off in range(0, len(data) - FMT.size + 1, FMT.size):
            sec, usec, typ, code, val = FMT.unpack_from(data, off)
            if typ == EV_ABS:
                if code == ABS_MT_SLOT:
                    self.cur_slot = val
                elif code == ABS_MT_TRACKING_ID:
                    s = self.slots.setdefault(self.cur_slot, [0, 0, -1])
                    s[2] = val
                    self.has_mt = True
                elif code == ABS_MT_POSITION_X:
                    self.slots.setdefault(self.cur_slot, [0, 0, -1])[0] = val
                elif code == ABS_MT_POSITION_Y:
                    self.slots.setdefault(self.cur_slot, [0, 0, -1])[1] = val
                elif code == ABS_X:
                    self.single[0] = val
                elif code == ABS_Y:
                    self.single[1] = val
            elif typ == EV_SYN and code == 0:
                out += self._snapshot(sec + usec / 1e6)
        return out

    def _snapshot(self, t):
        ev = []
        now = {}
        for s, (x, y, tid) in self.slots.items():
            if tid is not None and tid >= 0:
                now[tid] = (x, y)
        if not self.has_mt:
            if self.single[0] is not None:
                now[1] = (self.single[0], self.single[1] or 0)
        for tid, (x, y) in now.items():
            px, py = self._sx(x), self._sy(y)
            if tid not in self.prev:
                ev.append(("down", px, py, t))
            elif self.prev[tid] != (x, y):
                ev.append(("move", px, py, t))
            self.prev[tid] = (x, y)
        for tid in list(self.prev.keys()):
            if tid not in now:
                x, y = self.prev.pop(tid)
                ev.append(("up", self._sx(x), self._sy(y), t))
        return ev


# ---------------------------------------------------------------- 应用基类
class App:
    title = "应用"; icon = "info"; live = False
    def __init__(self, ui):
        self.ui = ui
        self.scroll = 0
        self.max_scroll = 0
    def clamp(self):
        self.scroll = max(0, min(self.scroll, max(0, self.max_scroll)))
    def key(self, name):
        if name == "up":
            self.scroll -= 130
        elif name == "down":
            self.scroll += 130
        self.clamp()
        self.ui.dirty = True
        return True
    def drag(self, dy):
        self.scroll -= dy
        self.clamp()
        self.ui.dirty = True
    def tap(self, x, y):
        return False
    def draw(self, d): pass
    def tick(self): return False


def appbar(d, title, right=None):
    d.text((60, CONTENT_Y0 + 16), title, font=fblib.font(50), fill=TEXT)
    if right:
        f = fblib.font(32)
        w = d.textlength(right, font=f)
        d.text((W - 60 - w, CONTENT_Y0 + 30), right, font=f, fill=GREEN)
    d.line([40, CONTENT_Y0 + 88, W - 40, CONTENT_Y0 + 88], fill=(40, 46, 66), width=2)


class Home(App):
    title = "主页"; icon = "info"
    def __init__(self, ui):
        super().__init__(ui)
        self.sel = 0
        self.cols, self.gap, self.tile_h = 2, 40, 430
        self.top = CONTENT_Y0 + 168
    def tiles(self):
        out = []
        tw = (W - self.gap * 3) // 2
        for i, a in enumerate(self.ui.apps):
            r, c = divmod(i, self.cols)
            out.append((self.gap + c * (tw + self.gap),
                        self.top - self.scroll + r * (self.tile_h + self.gap),
                        tw, self.tile_h, a))
        return out
    def ensure_visible(self):
        rows = (len(self.ui.apps) + 1) // 2
        total = rows * (self.tile_h + self.gap) - self.gap
        view = CONTENT_Y1 - self.top
        self.max_scroll = max(0, total - view)
        r = self.sel // self.cols
        y0 = r * (self.tile_h + self.gap)
        if y0 < self.scroll:
            self.scroll = y0
        elif y0 + self.tile_h > self.scroll + view:
            self.scroll = y0 + self.tile_h - view
        self.clamp()
    def key(self, name):
        n = len(self.ui.apps)
        if name == "up":
            self.sel = (self.sel - self.cols) % n
        elif name == "down":
            self.sel = (self.sel + self.cols) % n
        elif name == "menu":
            self.sel = (self.sel + 1) % n
        elif name in ("ok", "power"):
            self.ui.open(self.sel)
        self.ensure_visible()
        self.ui.dirty = True
        return True
    def drag(self, dy):
        self.scroll -= dy
        self.clamp()
        self.ui.dirty = True
    def tap(self, x, y):
        for i, (tx, ty, tw, th, a) in enumerate(self.tiles()):
            if tx <= x <= tx + tw and ty <= y <= ty + th:
                self.sel = i
                self.ui.open(i)
                return True
        return False
    def draw(self, d):
        self.ensure_visible()
        now = time.localtime()
        d.text((self.gap + 8, CONTENT_Y0 + 10), time.strftime("%H:%M", now), font=fblib.font(96), fill=TEXT)
        wk = "日一二三四五六"[now.tm_wday]
        d.text((self.gap + 16, CONTENT_Y0 + 112), time.strftime("%Y-%m-%d", now) + " 星期" + wk,
               font=fblib.font(30), fill=DIM)
        ip, linked, op = net_info()
        t = temp()
        rtxt = ("%s · %.0f℃" % (ip if linked else "无网络", t)) if t else (ip or "-")
        f = fblib.font(30)
        d.text((W - self.gap - d.textlength(rtxt, font=f), CONTENT_Y0 + 28), rtxt, font=f,
               fill=GREEN if linked else DIM)
        d.text((W - self.gap - d.textlength("SM8150 · Linux 6.17", font=f), CONTENT_Y0 + 70),
               "SM8150 · Linux 6.17", font=f, fill=(96, 106, 132))
        for i, (x, y, tw, th, a) in enumerate(self.tiles()):
            on = (i == self.sel)
            d.rounded_rectangle([x, y, x + tw, y + th], 40, fill=SURF2 if on else SURF,
                                outline=ACCENT if on else (44, 52, 74), width=6 if on else 3)
            icon(d, a.icon, x + tw // 2, y + th * 0.37, 76, ACCENT if on else (118, 148, 200))
            fh = fblib.font(48)
            w = d.textlength(a.title, font=fh)
            d.text((x + (tw - w) / 2, y + th * 0.66), a.title, font=fh, fill=TEXT if on else DIM)
        if self.max_scroll > 0:      # 滚动指示条
            frac = self.scroll / float(self.max_scroll)
            track_y0, track_y1 = self.top, CONTENT_Y1 - 20
            hh = max(80, (track_y1 - track_y0) * 0.25)
            y0 = track_y0 + (track_y1 - track_y0 - hh) * frac
            d.rounded_rectangle([W - 14, y0, W - 6, y0 + hh], 4, fill=(70, 80, 104))


class ClockApp(App):
    title = "时钟"; icon = "clock"; live = True
    def tap(self, x, y):
        self.ui.toast_msg(time.strftime("%Y-%m-%d %H:%M:%S"))
        return True
    def draw(self, d):
        now = time.localtime()
        appbar(d, "时钟", time.strftime("%Y-%m-%d"))
        t = time.strftime("%H:%M:%S", now)
        f = fblib.font(200)
        d.text(((W - d.textlength(t, font=f)) / 2, CONTENT_Y0 + 130 - self.scroll), t, font=f, fill=ACCENT)
        wk = "日一二三四五六"[now.tm_wday]
        ds = "%s 星期%s" % (time.strftime("%Y-%m-%d", now), wk)
        f2 = fblib.font(48)
        d.text(((W - d.textlength(ds, font=f2)) / 2, CONTENT_Y0 + 380 - self.scroll), ds, font=f2, fill=TEXT)
        up = int(uptime_s())
        mi = meminfo()
        info = [("运行时间", "%d 天 %02d:%02d:%02d" % (up // 86400, up % 86400 // 3600, up % 3600 // 60, up % 60)),
                ("系统负载", loadavg()),
                ("CPU 温度", "%.1f ℃" % (temp("thermal_zone2") or 0)),
                ("内存占用", "%.0f / %.0f MB" % ((mi["MemTotal"] - mi["MemAvailable"]) / 1024,
                                               mi["MemTotal"] / 1024))]
        y = CONTENT_Y0 + 480 - self.scroll
        d.rounded_rectangle([60, y - 26, W - 60, y + 30 + len(info) * 88], 36, fill=SURF)
        for k, v in info:
            d.text((100, y), k, font=fblib.font(40), fill=DIM)
            fv = fblib.font(40)
            d.text((W - 100 - d.textlength(v, font=fv), y), v, font=fv, fill=TEXT)
            y += 88
        cx, cy, r = W // 2, CONTENT_Y1 - 250, 175
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(58, 70, 98), width=4)
        for i in range(12):
            a = math.radians(i * 30 - 90)
            d.line([cx + math.cos(a) * r * 0.87, cy + math.sin(a) * r * 0.87,
                    cx + math.cos(a) * r * 0.97, cy + math.sin(a) * r * 0.97], fill=(88, 102, 136), width=6)
        for val, ln, wd, cl in ((now.tm_hour % 12 + now.tm_min / 60.0, 0.50, 9, TEXT),
                                (now.tm_min + now.tm_sec / 60.0, 0.74, 6, TEXT),
                                (now.tm_sec, 0.84, 3, ACCENT2)):
            a = math.radians(val * 30 - 90)
            d.line([cx, cy, cx + math.cos(a) * r * ln, cy + math.sin(a) * r * ln], fill=cl, width=wd)
        d.ellipse([cx - 11, cy - 11, cx + 11, cy + 11], fill=ACCENT)
    def tick(self): return True


class SystemApp(App):
    title = "系统"; icon = "chip"; live = True
    ROW = 94
    def rows(self):
        mi = meminfo()
        st = df_root()
        ip, linked, op = net_info()
        up = int(uptime_s())
        return [("主机名", rd("/etc/hostname", "umeko-device")),
                ("内核", "6.17.0-sm8150 (aarch64)"),
                ("运行时间", "%dh %dm" % (up // 3600, up % 3600 // 60)),
                ("负载(1m)", loadavg()),
                ("内存", "%.0f/%.0f MB" % ((mi["MemTotal"] - mi["MemAvailable"]) / 1024, mi["MemTotal"] / 1024)),
                ("根分区", "%s / %s" % st[:2]),
                ("WiFi", ("%s (%s)" % (ip, op)) if ip else "未连接"),
                ("CPU 核心", "%d" % (os.cpu_count() or 0)),
                ("屏幕", "%dx%d BGRA stride %d" % (W, H, W * 4)),
                ("电源管理", "genpd 保持引导电源域")] + \
               [("温度 " + t.replace("-thermal", ""), "%.1f ℃" % v) for t, v in temps()[:8]]
    def draw(self, d):
        rows = self.rows()
        appbar(d, "系统信息", "音量±/拖动 滚动")
        self.max_scroll = max(0, len(rows) * self.ROW + 40 - (CONTENT_Y1 - CONTENT_Y0 - 100))
        y = CONTENT_Y0 + 110 - self.scroll
        for k, v in rows:
            if CONTENT_Y0 + 92 < y < CONTENT_Y1 - 10:
                d.rounded_rectangle([40, y, W - 40, y + 82], 22, fill=SURF)
                d.text((80, y + 20), k, font=fblib.font(38), fill=DIM)
                f = fblib.font(38)
                d.text((W - 80 - d.textlength(v, font=f), y + 20), v, font=f, fill=TEXT)
            y += self.ROW
    def tick(self): return True


class DisplayApp(App):
    title = "显示"; icon = "display"; live = True
    MODES = ["彩条", "渐变", "动球", "棋盘", "文字"]
    def __init__(self, ui):
        super().__init__(ui)
        self.mode = 0
    def key(self, name):
        if name in ("ok", "power", "down"):
            self.mode = (self.mode + 1) % len(self.MODES)
        elif name == "up":
            self.mode = (self.mode - 1) % len(self.MODES)
        self.ui.dirty = True
        return True
    def tap(self, x, y):
        self.mode = (self.mode + 1) % len(self.MODES)
        self.ui.dirty = True
        return True
    def draw(self, d):
        m = self.MODES[self.mode]
        y0, y1 = CONTENT_Y0, CONTENT_Y1
        if m == "彩条":
            cols = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
                    (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
            hh = (y1 - y0) // len(cols)
            for i, c in enumerate(cols):
                d.rectangle([0, y0 + i * hh, W, y0 + (i + 1) * hh], fill=c)
            for i in range(16):
                g = int(255 * i / 15)
                d.rectangle([i * W // 16, y0, (i + 1) * W // 16, y0 + 80], fill=(g, g, g))
        elif m == "渐变":
            for y in range(y0, y1, 2):
                t = (y - y0) / float(y1 - y0)
                d.rectangle([0, y, W, y + 2],
                            fill=(int(255 * t), int(255 * (1 - t)), int(255 * abs(0.5 - t) * 2)))
        elif m == "动球":
            d.rectangle([0, y0, W, y1], fill=(8, 10, 18))
            t = time.time()
            for i in range(7):
                ph = t * (0.7 + i * 0.19) + i
                x = W / 2 + math.sin(ph) * (W / 2 - 130)
                y = (y0 + y1) / 2 + math.cos(ph * 1.3) * ((y1 - y0) / 2 - 130)
                r = 60 + 25 * math.sin(ph * 2)
                d.ellipse([x - r, y - r, x + r, y + r],
                          fill=(int(127 + 128 * math.sin(ph)), int(127 + 128 * math.sin(ph + 2)),
                                int(127 + 128 * math.sin(ph + 4))))
        elif m == "棋盘":
            s = 90
            for yy in range(y0, y1, s):
                for xx in range(0, W, s):
                    d.rectangle([xx, yy, xx + s, yy + s],
                                fill=(200, 200, 200) if ((xx // s + yy // s) % 2) else (10, 10, 10))
        else:
            d.rectangle([0, y0, W, y1], fill=(10, 12, 20))
            for i, s in enumerate([28, 38, 50, 64, 82]):
                d.text((50, y0 + 140 + i * 160), "中文显示正常 %dpx  ABCdefg 0123" % s,
                       font=fblib.font(s), fill=(240, 245, 255))
        d.rounded_rectangle([30, CONTENT_Y0 + 10, 30 + 620, CONTENT_Y0 + 72], 18, fill=(0, 0, 0))
        d.text((52, CONTENT_Y0 + 22), "模式: %s (点按/电源 切换)" % m, font=fblib.font(34), fill=GREEN)
        d.rounded_rectangle([30, CONTENT_Y1 - 100, 30 + 700, CONTENT_Y1 - 22], 20, fill=(0, 0, 0))
        d.text((52, CONTENT_Y1 - 86), "退出：点底部「返回/主页」，或长按电源键",
               font=fblib.font(32), fill=YELLOW)
    def tick(self): return self.mode == 2


class LogApp(App):
    title = "日志"; icon = "log"; live = True
    ROW = 42
    def __init__(self, ui):
        super().__init__(ui)
        self.follow = True
    def key(self, name):
        if name in ("ok", "power"):
            self.follow = not self.follow
            self.ui.dirty = True
            return True
        self.follow = False
        return super().key(name)
    def drag(self, dy):
        self.follow = False
        return super().drag(dy)
    def tap(self, x, y):
        self.follow = not self.follow
        self.ui.dirty = True
        return True
    def draw(self, d):
        lines = dmesg_lines()
        appbar(d, "内核日志", "跟随: %s" % ("开" if self.follow else "关"))
        self.max_scroll = max(0, len(lines) * self.ROW - (CONTENT_Y1 - CONTENT_Y0 - 130))
        if self.follow:
            self.scroll = self.max_scroll
        y = CONTENT_Y0 + 104 - self.scroll
        f = fblib.font(28)
        for ln in lines:
            if y > CONTENT_Y0 + 92 and y < CONTENT_Y1 - 10:
                low = ln.lower()
                col = TEXT
                if ("error" in low or "fail" in low or "warn" in low or "bug" in low or "panic" in low):
                    col = YELLOW
                if "keeping" in ln:
                    col = GREEN
                d.text((26, y), ln[:82], font=f, fill=col)
            y += self.ROW
    def tick(self): return True


class NetApp(App):
    title = "网络"; icon = "wifi"; live = True
    def __init__(self, ui):
        super().__init__(ui)
        self.ping = "点这里 / 按电源 测到网关延迟"
        self.busy = False
    def do_ping(self):
        if self.busy:
            return
        self.busy = True
        self.ping = "测量中…"
        self.ui.dirty = True
        self.ui.render()
        out = sh("ping -c 4 -W 2 %s 2>&1 | tail -2" % gw(), timeout=18)
        self.ping = out.replace("\n", "  ")[:150] or "无响应"
        self.busy = False
        self.ui.dirty = True
    def key(self, name):
        if name in ("ok", "power"):
            self.do_ping()
        else:
            super().key(name)
        self.ui.dirty = True
        return True
    def tap(self, x, y):
        if y > CONTENT_Y1 - 400:
            self.do_ping()
            return True
        return False
    def rows(self):
        r = []
        for ln in sh("ip -4 -brief addr 2>/dev/null").splitlines():
            p = ln.split()
            if len(p) >= 3:
                r.append((p[0], " ".join(p[2:])))
        return r or [("网络", "无")]
    def draw(self, d):
        appbar(d, "网络", "电源/点按 测延迟")
        ip, linked, op = net_info()
        y = CONTENT_Y0 + 120 - self.scroll
        for k, v in self.rows():
            d.rounded_rectangle([40, y, W - 40, y + 190], 28, fill=SURF)
            d.text((80, y + 22), k + ("  ●" if k == "wlan0" and linked else ""), font=fblib.font(44),
                   fill=GREEN if (k == "wlan0" and linked) else ACCENT)
            for i, ln in enumerate([v[j:j + 40] for j in range(0, len(v), 40)][:3]):
                d.text((80, y + 88 + i * 46), ln, font=fblib.font(36), fill=TEXT)
            y += 210
        d.rounded_rectangle([40, y, W - 40, y + 210], 28, fill=SURF)
        d.text((80, y + 20), "WiFi SSID", font=fblib.font(40), fill=ACCENT)
        d.text((80, y + 76), ssid() + "   网关 " + gw(), font=fblib.font(38), fill=TEXT)
        d.text((80, y + 140), "状态: " + op, font=fblib.font(34), fill=DIM)
        y2 = max(y + 230, CONTENT_Y1 - 230)
        d.rounded_rectangle([40, y2, W - 40, y2 + 190], 28, fill=SURF2)
        d.text((80, y2 + 20), "延迟测试 (ping 网关)", font=fblib.font(38), fill=DIM)
        for i, ln in enumerate(self.ping.split("  ")[:3]):
            d.text((80, y2 + 78 + i * 44), ln.strip()[:46], font=fblib.font(32), fill=GREEN)
        self.max_scroll = max(0, y2 + 190 - CONTENT_Y1 + 20)
        self.clamp()
    def tick(self): return True


class TermApp(App):
    title = "终端"; icon = "term"
    CMDS = [("内核版本", "uname -a"),
            ("命令行", "cat /proc/cmdline | tr ' ' '\\n'"),
            ("分区/磁盘", "cat /proc/partitions"),
            ("内存", "free -h"),
            ("负载", "uptime; cat /proc/loadavg"),
            ("网络地址", "ip -brief addr"),
            ("显示电源域", "dmesg | grep -i keeping"),
            ("触摸/i2c", "dmesg | grep -iE 'fts|i2c|gpi' | tail -20"),
            ("内核模块", "lsmod"),
            ("挂载点", "mount | grep -v cgroup"),
            ("中断", "head -20 /proc/interrupts"),
            ("进程", "ps -eo pid,comm,pcpu --sort=-pcpu | head -15")]
    ROW = 100
    def __init__(self, ui):
        super().__init__(ui)
        self.sel = 0
        self.out = ""
        self.showing = False
    def key(self, name):
        if self.showing:
            if name in ("ok", "power", "back"):
                self.showing = False
            else:
                super().key(name)
        else:
            if name == "up":
                self.sel = (self.sel - 1) % len(self.CMDS)
            elif name == "down":
                self.sel = (self.sel + 1) % len(self.CMDS)
            elif name in ("ok", "power"):
                self.out = sh(self.CMDS[self.sel][1], timeout=10)[:6000]
                self.showing = True
                self.scroll = 0
        self.ui.dirty = True
        return True
    def tap(self, x, y):
        if self.showing:
            self.showing = False
            self.ui.dirty = True
            return True
        i = int((y - (CONTENT_Y0 + 110)) // self.ROW)
        if 0 <= i < len(self.CMDS):
            self.sel = i
            self.ui.dirty = True
            return True
        return False
    def draw(self, d):
        if not self.showing:
            appbar(d, "终端", "点按/电源 执行")
            y = CONTENT_Y0 + 110
            for i, (n, c) in enumerate(self.CMDS):
                on = i == self.sel
                d.rounded_rectangle([40, y, W - 40, y + 88], 22, fill=SURF2 if on else SURF,
                                    outline=ACCENT if on else None, width=5 if on else 1)
                d.text((80, y + 22), n, font=fblib.font(40), fill=TEXT if on else DIM)
                y += self.ROW
        else:
            d.rectangle([0, CONTENT_Y0, W, CONTENT_Y1], fill=(6, 8, 12))
            d.text((40, CONTENT_Y0 + 16), "$ " + self.CMDS[self.sel][1][:58], font=fblib.font(32), fill=GREEN)
            self.max_scroll = max(0, len(self.out.splitlines()) * 38 - (CONTENT_Y1 - CONTENT_Y0 - 130))
            self.clamp()
            y = CONTENT_Y0 + 84 - self.scroll
            for ln in (self.out or "(无输出)").splitlines():
                if CONTENT_Y0 + 70 < y < CONTENT_Y1 - 10:
                    d.text((34, y), ln[:84], font=fblib.font(27), fill=TEXT)
                y += 38
            d.text((40, CONTENT_Y1 - 46), "点按/电源 返回", font=fblib.font(30), fill=DIM)


class FilesApp(App):
    title = "文件"; icon = "folder"
    ROW = 96
    def __init__(self, ui):
        super().__init__(ui)
        self.path = "/root"
        self.sel = 0
        self.view = None
    def entries(self):
        def f():
            try:
                names = sorted(os.listdir(self.path),
                               key=lambda n: (not os.path.isdir(os.path.join(self.path, n)), n.lower()))
            except Exception as e:
                return [("", "<无法读取: %s>" % e)]
            out = []
            for n in names:
                p = os.path.join(self.path, n)
                try:
                    isdir = os.path.isdir(p)
                    size = "" if isdir else self.human(os.path.getsize(p))
                except Exception:
                    isdir, size = False, "?"
                out.append((n, "/" if isdir else size, isdir, p))
            return out
        return cached("ls:" + self.path, 1.0, f)
    @staticmethod
    def human(n):
        for u in ("B", "K", "M", "G"):
            if n < 1024:
                return "%d%s" % (n, u)
            n //= 1024
        return "%dT" % n
    def open_entry(self, idx):
        e = self.entries()
        if not (0 <= idx < len(e)):
            return
        n, sz, isdir, p = e[idx]
        if isdir:
            self.path = p
            self.sel = 0
            self.scroll = 0
        else:
            try:
                with open(p, "rb") as f:
                    data = f.read(20000)
                txt = data.decode("utf-8", "replace")
                self.view = (n, txt)
                self.scroll = 0
            except Exception as ex:
                self.ui.toast_msg("打不开: %s" % ex)
        self.ui.dirty = True
    def key(self, name):
        if self.view:
            if name in ("back", "ok", "power"):
                self.view = None
            else:
                super().key(name)
            self.ui.dirty = True
            return True
        e = self.entries()
        if name == "up":
            self.sel = max(0, self.sel - 1)
        elif name == "down":
            self.sel = min(len(e) - 1, self.sel + 1)
        elif name in ("ok", "power"):
            self.open_entry(self.sel)
        elif name == "back":
            self.path = os.path.dirname(self.path.rstrip("/")) or "/"
            self.sel = 0
        self.clamp()
        self.ui.dirty = True
        return True
    def tap(self, x, y):
        if self.view:
            self.view = None
            self.ui.dirty = True
            return True
        i = int((y - (CONTENT_Y0 + 100) + self.scroll) // self.ROW)
        if 0 <= i < len(self.entries()):
            self.sel = i
            self.open_entry(i)
            return True
        return False
    def draw(self, d):
        if self.view:
            name, txt = self.view
            appbar(d, name, "点按 返回")
            self.max_scroll = max(0, len(txt.splitlines()) * 36 - (CONTENT_Y1 - CONTENT_Y0 - 130))
            self.clamp()
            y = CONTENT_Y0 + 104 - self.scroll
            for ln in txt.splitlines():
                if CONTENT_Y0 + 92 < y < CONTENT_Y1 - 10:
                    d.text((30, y), ln[:86].expandtabs(4), font=fblib.font(26), fill=TEXT)
                y += 36
            return
        e = self.entries()
        appbar(d, "文件", "返回键 上级")
        d.text((60, CONTENT_Y0 + 96), self.path, font=fblib.font(30), fill=DIM)
        self.max_scroll = max(0, len(e) * self.ROW + 120 - (CONTENT_Y1 - CONTENT_Y0))
        self.clamp()
        y = CONTENT_Y0 + 150 - self.scroll
        for i, (n, sz, isdir, p) in enumerate(e):
            if CONTENT_Y0 + 140 < y < CONTENT_Y1 - 10:
                on = (i == self.sel)
                d.rounded_rectangle([30, y, W - 30, y + 84], 20, fill=SURF2 if on else SURF)
                icon(d, "folder" if isdir else "log", 80, y + 42, 26, ACCENT if isdir else (140, 160, 200))
                d.text((130, y + 22), n[:28], font=fblib.font(38), fill=TEXT if isdir else (200, 208, 226))
                f = fblib.font(30)
                d.text((W - 60 - d.textlength(sz, font=f), y + 28), sz, font=f, fill=DIM)
            y += self.ROW


class SettingsApp(App):
    title = "设置"; icon = "gear"; live = True
    ROW = 150
    def slider_rect(self):
        return [60, CONTENT_Y0 + 210, W - 60, CONTENT_Y0 + 258]
    def draw(self, d):
        appbar(d, "设置", "拖动/音量±")
        y = CONTENT_Y0 + 110
        d.rounded_rectangle([40, y, W - 40, y + 380], 30, fill=SURF)
        d.text((80, y + 30), "屏幕亮度（软件调光）", font=fblib.font(40), fill=TEXT)
        r = self.slider_rect()
        d.rounded_rectangle(r, 24, fill=(16, 20, 32), outline=(60, 70, 96), width=3)
        frac = (self.ui.brightness - 0.15) / 0.85
        fill_r = [r[0], r[1], r[0] + int((r[2] - r[0]) * frac), r[3]]
        d.rounded_rectangle(fill_r, 24, fill=ACCENT)
        d.text((80, r[3] + 24), "%.0f%%" % (self.ui.brightness * 100), font=fblib.font(38), fill=ACCENT)
        d.text((80, r[3] + 84), "音量± 调整 · 也可直接拖动滑块", font=fblib.font(30), fill=DIM)
        y += 460
        opts = [("自动巡航演示", self.ui.auto), ("待机时钟（无操作 3 分钟）", self.ui.idle_clock)]
        for i, (name, on) in enumerate(opts):
            d.rounded_rectangle([40, y, W - 40, y + 120], 26, fill=SURF2 if on else SURF)
            d.text((80, y + 36), name, font=fblib.font(40), fill=TEXT)
            bx, by = W - 190, y + 32
            d.rounded_rectangle([bx, by, bx + 120, by + 56], 28, fill=GREEN if on else (60, 66, 88))
            d.ellipse([bx + (62 if on else 4), by + 4, bx + (116 if on else 58), by + 52], fill=(255, 255, 255))
            y += 140
        d.rounded_rectangle([40, y, W - 40, y + 120], 26, fill=SURF)
        d.text((80, y + 36), "截图保存到 /root/phoneui/shot.png", font=fblib.font(34), fill=TEXT)
        y += 140
        d.rounded_rectangle([40, y, W - 40, y + 120], 26, fill=SURF)
        d.text((80, y + 36), "重启图形界面", font=fblib.font(40), fill=ACCENT2)
        self.max_scroll = max(0, y + 160 - CONTENT_Y1)
        self.clamp()
    def key(self, name):
        if name == "up":
            self.ui.set_brightness(self.ui.brightness + 0.1)
        elif name == "down":
            self.ui.set_brightness(self.ui.brightness - 0.1)
        else:
            super().key(name)
        self.ui.dirty = True
        return True
    def tap(self, x, y):
        r = self.slider_rect()
        if r[1] - 20 <= y <= r[3] + 20:
            frac = min(1.0, max(0.0, (x - r[0]) / float(r[2] - r[0])))
            self.ui.set_brightness(0.15 + frac * 0.85)
            return True
        y0 = CONTENT_Y0 + 110 + 460
        for i, kind in enumerate(("auto", "idle", "shot", "restart")):
            if y0 <= y <= y0 + 120:
                if kind == "auto":
                    self.ui.auto = not self.ui.auto
                elif kind == "idle":
                    self.ui.idle_clock = not self.ui.idle_clock
                elif kind == "shot":
                    self.ui.shot(os.path.join(HOME, "shot.png"))
                    self.ui.toast_msg("已截图 /root/phoneui/shot.png")
                else:
                    self.ui.restart()
                self.ui.dirty = True
                return True
            y0 += 140
        return False
    def drag(self, dy):
        if abs(dy) > 3:
            self.ui.set_brightness(self.ui.brightness - dy / 500.0)
        return True
    def tick(self): return False


class TouchApp(App):
    title = "触摸"; icon = "touch"; live = True
    def __init__(self, ui):
        super().__init__(ui)
        self.points = []
    def on_touch(self, x, y, kind):
        self.points.append((x, y, kind, time.time()))
        del self.points[:-60]
        self.ui.dirty = True
    def drag(self, dy):
        return True
    def draw(self, d):
        d.rectangle([0, CONTENT_Y0, W, CONTENT_Y1], fill=(6, 8, 14))
        appbar(d, "触摸测试")
        devs = cached("inp", 20, lambda: [ln.split("=", 1)[-1].strip('"') for ln in rd("/proc/bus/input/devices").splitlines() if ln.startswith("N: Name")])
        y = CONTENT_Y0 + 120
        d.text((50, y), "输入设备: %s" % (", ".join(devs)[:52] or "无"), font=fblib.font(34), fill=DIM)
        y += 70
        d.text((50, y), "屏幕任意处点按/拖动，轨迹会画出来", font=fblib.font(36), fill=TEXT)
        d.rounded_rectangle([30, CONTENT_Y1 - 100, 30 + 700, CONTENT_Y1 - 22], 20, fill=(0, 0, 0))
        d.text((52, CONTENT_Y1 - 86), "退出：点底部「返回/主页」，或长按电源键",
               font=fblib.font(32), fill=YELLOW)
        y += 70
        t = time.time()
        for x, yy, kind, ts in self.points:
            age = t - ts
            if age > 4:
                continue
            r = 40 + age * 25
            col = GREEN if kind == "down" else (ACCENT if kind == "move" else ACCENT2)
            d.ellipse([x - r, yy - r, x + r, yy + r], outline=col, width=5)
            d.ellipse([x - 12, yy - 12, x + 12, yy + 12], fill=col)
        if not self.points:
            d.rounded_rectangle([50, CONTENT_Y1 - 260, W - 50, CONTENT_Y1 - 70], 28, fill=SURF)
            d.text((90, CONTENT_Y1 - 230), "显示链路已打通 ✅", font=fblib.font(40), fill=GREEN)
            d.text((90, CONTENT_Y1 - 160), "触摸需要新 DTB（i2c17 + gpi_dma2）", font=fblib.font(34),
                   fill=YELLOW)
        return True
    def tick(self): return bool(self.points)


class AboutApp(App):
    title = "关于"; icon = "info"
    def draw(self, d):
        appbar(d, "关于")
        txt = [("设备", "小米9 cepheus / SM8150"), None,
               ("系统", "主线 Linux 6.17 + UEFI(edk2) 启动"), None,
               ("显示", "simplefb 1080x2340 BGRA (stride 4320)"), None,
               ("原理", "ABL 已配好 DSI 命令模式，面板持续从 framebuffer 取帧；"),
               (None, "只要显示电源域不断电，写 /dev/fb0 就即时上屏。"), None,
               ("已修", "1) genpd sync_state 关断引导电源域 → 整条显示链掉电（补丁 0008）"),
               (None, "2) logind 把电源键当 poweroff → 按一下就关机（HandlePowerKey=ignore）"),
               (None, "3) 触摸 i2c17 缺 gpi_dma2 → i2c 总线起不来（DTS 已修）"), None,
               ("输入", "触摸(协议B) + 音量± + 电源(长按=主页) + HOME 键"), None,
               ("GUI", "纯 Python + PIL 直写 /dev/fb0，无 X 无 DRM"), None,
               ("字体", "文泉驿正黑 WQY Zen Hei"), None,
               ("远程", "echo key down > /run/phoneui.fifo")]
        self.max_scroll = max(0, len(txt) * 54 + 100 - (CONTENT_Y1 - CONTENT_Y0))
        self.clamp()
        y = CONTENT_Y0 + 110 - self.scroll
        for k, v in txt:
            if CONTENT_Y0 + 92 < y < CONTENT_Y1:
                x = 50
                if k:
                    d.text((x, y), k, font=fblib.font(34), fill=ACCENT)
                    x = 170
                if v:
                    d.text((x, y), v, font=fblib.font(30), fill=TEXT)
            y += 54


# ---------------------------------------------------------------- UI
class UI:
    APPS = [ClockApp, SystemApp, DisplayApp, LogApp, NetApp, TermApp, FilesApp,
            SettingsApp, TouchApp, AboutApp]

    def __init__(self):
        self.apps = []
        for c in self.APPS:
            try:
                self.apps.append(c(self))
            except Exception as e:
                print("app init fail", c.__name__, e, flush=True)
        self.dirty = True
        self.running = True
        self.toast, self.toast_t = None, 0
        self.fps = 0.0
        self.frames = 0
        self.fps_t = time.time()
        self.auto = os.environ.get("PHONEUI_AUTO", "0") == "1"
        self.auto_dwell = 8.0
        self.auto_t = time.time()
        self.idle_clock = False
        self.brightness = float(os.environ.get("PHONEUI_BRIGHT", "1.0"))
        self.keys = []
        self.touch = []          # 触摸设备列表（真屏 + 需要时可挂虚拟设备）
        self.power_down = None
        self.home = Home(self)
        self.cur = self.home
        self.tap_origin = None
        self.drag_last = None
        self.moved = 0
        self.last_input = time.time()
        self._open_fifo()
        self._open_input()
        os.system("dmesg -n 1 2>/dev/null; echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null")
        print("phoneui: apps=%d keys=%d touch=%s fifo=%s auto=%s bright=%.2f" %
              (len(self.apps), len(self.keys), ",".join(t.name for t in self.touch) or None,
               self.fifo is not None, self.auto, self.brightness), flush=True)

    # ---- 设备初始化
    def _open_fifo(self):
        self.fifo = None
        try:
            if os.path.exists(FIFO):
                os.unlink(FIFO)
            os.mkfifo(FIFO, 0o600)
            self.fifo = os.open(FIFO, os.O_RDWR | os.O_NONBLOCK)
        except Exception as e:
            print("fifo fail:", e, flush=True)

    def _open_input(self):
        for i in range(10):
            p = "/dev/input/event%d" % i
            if not os.path.exists(p):
                continue
            try:
                nm = rd("/sys/class/input/event%d/device/name" % i, "?")
                low = nm.lower()
                # capabilities/abs 文件对任何设备都存在（值是十六进制位掩码，可能为 "0"）
                mask = 0
                try:
                    txt = rd("/sys/class/input/event%d/device/capabilities/abs" % i, "").strip()
                    mask = int(txt, 16) if txt else 0
                except Exception:
                    mask = 0
                want = (1 << ABS_X) | (1 << ABS_MT_SLOT) | (1 << ABS_MT_POSITION_X)
                is_key = any(k in low for k in ("pwrkey", "resin", "gpio_keys", "keyboard", "button"))
                is_touch = (not is_key) and bool(mask & want)
                fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK)
                if is_touch:
                    self.touch.append(TouchReader(fd, nm))
                    print("input: %s -> touch (%s abs=0x%x)" % (p, nm, mask), flush=True)
                    continue
                if is_key:
                    try:
                        fcntl.ioctl(fd, 0x40044590, 1)   # EVIOCGRAB 独占
                        print("input: %s -> key  (%s, grabbed)" % (p, nm), flush=True)
                    except Exception as e:
                        print("grab fail", nm, e, flush=True)
                    self.keys.append((fd, nm))
                else:
                    print("input: %s -> 忽略 (%s abs=0x%x)" % (p, nm, mask), flush=True)
                    os.close(fd)
            except Exception as e:
                print("input open fail", p, e, flush=True)

    # ---- 清理（重启前必须关掉所有 evdev fd，否则 EVIOCGRAB 不释放）
    def cleanup(self):
        for fd, nm in self.keys:
            try:
                os.close(fd)
            except Exception:
                pass
        self.keys = []
        for t in self.touch:
            try:
                os.close(t.fd)
            except Exception:
                pass
        self.touch = []
        if self.fifo is not None:
            try:
                os.close(self.fifo)
            except Exception:
                pass
            self.fifo = None

    # ---- 亮度
    def set_brightness(self, v):
        self.brightness = max(0.15, min(1.0, v))
        fblib.BRIGHTNESS = self.brightness
        self.dirty = True

    def toast_msg(self, msg):
        self.toast, self.toast_t = msg, time.time()
        self.dirty = True

    def restart(self):
        self.running = False
        self._restart = True

    # ---- 输入处理
    def _activity(self):
        self.last_input = time.time()
        self.idle_wake = time.time()

    def handle_key(self, name):
        self._activity()
        self.auto = False
        if name == "home":
            self.home.sel = 0
            self.cur = self.home
        elif name == "back":
            if self.cur is not self.home:
                self.cur = self.home
            else:
                self.home.sel = 0
        elif self.cur is self.home:
            self.home.key(name)
        else:
            if name == "back" and hasattr(self.cur, "view"):
                self.cur.view = None
            else:
                self.cur.key(name)
        self.dirty = True

    def handle_touch(self, kind, x, y):
        self._activity()
        self.auto = False
        print("touch %-4s x=%4d y=%4d" % (kind, x, y), flush=True)
        if kind == "down":
            self.tap_origin = (x, y, time.time())
            self.drag_last = (x, y)
            self.moved = 0
            if hasattr(self.cur, "on_touch"):
                self.cur.on_touch(x, y, "down")
        elif kind == "move":
            if hasattr(self.cur, "on_touch"):
                self.cur.on_touch(x, y, "move")
            if self.drag_last:
                dx = x - self.drag_last[0]
                dy = y - self.drag_last[1]
                self.moved += abs(dx) + abs(dy)
                if abs(dy) >= 4 and abs(dy) >= abs(dx):
                    self.cur.drag(dy)          # 手指上滑 → 内容上移（scroll 增大）
                self.drag_last = (x, y)
        elif kind == "up":
            if hasattr(self.cur, "on_touch"):
                self.cur.on_touch(x, y, "up")
            if self.tap_origin:
                ox, oy, ot = self.tap_origin
                if time.time() - ot < 0.7 and self.moved < 60:
                    self.tap(x, y)
            self.tap_origin = None
            self.drag_last = None
        self.dirty = True

    def tap(self, x, y):
        print("tap x=%d y=%d cur=%s" % (x, y, self.cur.title), flush=True)
        if y >= CONTENT_Y1:                      # 导航栏
            third = W / 3.0
            if x < third:
                self.toast_msg("返回 / 主页")
                self.handle_key("back")
            elif x < 2 * third:
                self.toast_msg("主页")
                self.handle_key("home")
            else:
                if self.cur is self.home:
                    # 主页上：移动磁贴选中框（看得见，再用电源键打开）
                    self.home.sel = (self.home.sel + 1) % max(1, len(self.apps))
                    self.toast_msg("已选: " + self.apps[self.home.sel].title)
                else:
                    nxt = (self.apps.index(self.cur) + 1) % len(self.apps) if self.cur in self.apps else 0
                    self.toast_msg("应用: " + self.apps[nxt].title)
                    self.open(nxt)
            return
        if y < STATUS_H:
            if x > W * 0.6:
                self.toast_msg("WiFi %s · 温度 %.0f℃" % (net_info()[0] or "-", temp() or 0))
            return
        self.cur.tap(x, y)
        self.dirty = True

    def read_keys(self):
        if not self.keys:
            return
        try:
            r, _, _ = select.select([k[0] for k in self.keys], [], [], 0)
        except Exception:
            return
        for fh in r:
            try:
                data = os.read(fh, FMT.size * 64)
            except Exception:
                continue
            for off in range(0, len(data) - FMT.size + 1, FMT.size):
                sec, usec, typ, code, val = FMT.unpack_from(data, off)
                if typ != EV_KEY:
                    continue
                name = KEYMAP.get(code)
                t = sec + usec / 1e6
                if name == "power":
                    if val == 1:
                        self.power_down = t
                    elif val == 0 and self.power_down is not None:
                        held = t - self.power_down
                        self.power_down = None
                        self.handle_key("home" if held >= 0.8 else "ok")
                    continue
                if val == 1 and name:
                    self.handle_key(name)

    def read_touch(self):
        if not self.touch:
            return
        try:
            r, _, _ = select.select([t.fd for t in self.touch], [], [], 0)
        except Exception:
            return
        for t in self.touch:
            if t.fd in r:
                for kind, x, y, ts in t.read():
                    self.handle_touch(kind, x, y)

    def read_fifo(self):
        if self.fifo is None:
            return
        try:
            if not select.select([self.fifo], [], [], 0)[0]:
                return
            data = os.read(self.fifo, 8192).decode("utf-8", "replace")
        except Exception:
            return
        for line in data.splitlines():
            p = line.strip().split(None, 1)
            if not p:
                continue
            c, arg = p[0], (p[1] if len(p) > 1 else "")
            try:
                if c == "key":
                    self.handle_key(arg)
                elif c == "app":
                    for i, a in enumerate(self.apps):
                        if (arg.isdigit() and int(arg) == i) or arg == a.title:
                            self.auto = False
                            self.open(i)
                            break
                elif c == "auto":
                    self.auto = ("off" not in arg)
                    self.auto_t = time.time()
                elif c == "bright":
                    self.set_brightness(float(arg))
                elif c == "toast":
                    self.toast_msg(arg)
                elif c == "tap":
                    x, y = [int(v) for v in arg.replace(",", " ").split()[:2]]
                    self.tap(x, y)
                elif c == "drag":
                    self.cur.drag(float(arg))
                elif c == "touch":
                    x, y, k = arg.replace(",", " ").split()
                    self.handle_touch(k, int(x), int(y))
                elif c == "shot":
                    self.shot(arg or os.path.join(HOME, "shot.png"))
                elif c == "idle":
                    self.idle_clock = ("on" in arg)
                elif c == "quit":
                    self.running = False
            except Exception as e:
                print("fifo cmd err", c, arg, e, flush=True)

    def open(self, i):
        if 0 <= i < len(self.apps):
            self.cur = self.apps[i]
            self.cur.scroll = 0
            self.dirty = True

    def shot(self, path):
        try:
            fblib.grab().save(path)
            print("shot ->", path, flush=True)
        except Exception as e:
            print("shot fail", e, flush=True)

    # ---- 绘制
    def render(self):
        img = fblib.new_surface(BG)
        d = ImageDraw.Draw(img)
        try:
            self.cur.draw(d)
        except Exception as e:
            d.text((60, CONTENT_Y0 + 40), "应用错误: %s" % e, font=fblib.font(34), fill=RED)
            print("draw err", self.cur.title, e, flush=True)
        self.draw_status(d)
        self.draw_nav(d)
        if self.toast and time.time() - self.toast_t < 4:
            f = fblib.font(40)
            w = d.textlength(self.toast, font=f)
            d.rounded_rectangle([(W - w) / 2 - 34, CONTENT_Y1 - 210, (W + w) / 2 + 34, CONTENT_Y1 - 130],
                                28, fill=(0, 0, 0), outline=ACCENT, width=4)
            d.text(((W - w) / 2, CONTENT_Y1 - 199), self.toast, font=f, fill=TEXT)
        fblib.blit(img, brightness=self.brightness)
        self.frames += 1
        if time.time() - self.fps_t >= 1.0:
            self.fps = self.frames / (time.time() - self.fps_t)
            self.frames, self.fps_t = 0, time.time()

    def draw_status(self, d):
        d.rectangle([0, 0, W, STATUS_H - 4], fill=(8, 9, 15))
        d.text((36, 26), time.strftime("%H:%M"), font=fblib.font(52), fill=TEXT)
        ip, linked, op = net_info()
        items = []
        t = temp()
        if t is not None:
            items.append(("%.0f℃" % t, YELLOW))
        items.append((ip if linked else "无网络", GREEN if linked else DIM))
        f = fblib.font(32)
        x = W - 36
        for txt, col in items:
            w = d.textlength(txt, font=f)
            d.text((x - w, 30), txt, font=f, fill=col)
            x -= w + 26
        icon(d, "wifi", x - 26, 50, 26, GREEN if linked else (88, 96, 112))
        d.text((36, 74), "%.0f fps" % self.fps, font=fblib.font(20), fill=(72, 82, 104))

    def draw_nav(self, d):
        d.rectangle([0, CONTENT_Y1, W, H], fill=(8, 9, 15))
        for i, (t, k) in enumerate([("返回", "back"), ("主页", "home"), ("应用", "menu")]):
            cx = W * (2 * i + 1) / 6.0
            col = ACCENT if (k == "home" and self.cur is self.home) else (198, 210, 234)
            ix, iy = cx - 66, CONTENT_Y1 + 60
            if k == "back":
                d.polygon([(ix + 16, iy - 17), (ix + 16, iy + 17), (ix - 15, iy)], fill=col)
            elif k == "home":
                d.ellipse([ix - 15, iy - 15, ix + 15, iy + 15], outline=col, width=5)
                d.ellipse([ix - 5, iy - 5, ix + 5, iy + 5], fill=col)
            else:
                for j in range(3):
                    d.line([ix - 17, iy - 13 + j * 13, ix + 17, iy - 13 + j * 13], fill=col, width=4)
            d.text((cx - 18, CONTENT_Y1 + 36), t, font=fblib.font(38), fill=col)
        d.rounded_rectangle([W / 2 - 90, H - 16, W / 2 + 90, H - 8], 4, fill=(70, 80, 104))

    # ---- 主循环
    def run(self):
        fblib.BRIGHTNESS = self.brightness
        fblib.message("小米9 · Linux\n正在启动图形界面…", size=60, bg=BG, fg=TEXT,
                      sub="触摸点按 / 音量± 选择 / 电源 确定(长按=主页)", sub_size=38)
        time.sleep(1.0)
        self.toast_msg("触摸点按 · 音量± 选择 · 电源 确定")
        last = 0.0
        self.idle_wake = time.time()
        while self.running:
            self.read_keys()
            self.read_touch()
            self.read_fifo()
            if self.auto and time.time() - self.auto_t > self.auto_dwell:
                self.auto_t = time.time()
                if self.cur is self.home:
                    self.home.sel = (self.home.sel + 1) % max(1, len(self.apps))
                else:
                    self.open((self.apps.index(self.cur) + 1) % len(self.apps))
            if self.idle_clock and self.cur is self.home and time.time() - self.last_input > 180:
                self.draw_idle()
                self.dirty = False
            elif self.cur.live and self.cur.tick():
                self.dirty = True
            if self.dirty and time.time() - last > 0.05:
                self.render()
                self.dirty = False
                last = time.time()
            time.sleep(0.01 if (self.auto or self.dirty) else 0.04)
        if self.fifo is not None:
            try:
                os.close(self.fifo)
            except Exception:
                pass
            self.fifo = None

    def draw_idle(self):
        img = fblib.new_surface((4, 5, 9))
        d = ImageDraw.Draw(img)
        t = time.strftime("%H:%M")
        f = fblib.font(240)
        d.text(((W - d.textlength(t, font=f)) / 2, H * 0.32), t, font=f, fill=(120, 150, 190))
        ds = time.strftime("%Y-%m-%d")
        f2 = fblib.font(52)
        d.text(((W - d.textlength(ds, font=f2)) / 2, H * 0.32 + 300), ds, font=f2, fill=(70, 90, 120))
        fblib.blit(img, brightness=max(0.4, self.brightness))


def main():
    if "--shot" in sys.argv:
        i = sys.argv.index("--shot")
        path = sys.argv[i + 1] if len(sys.argv) > i + 1 else os.path.join(HOME, "shot.png")
        fblib.grab().save(path)
        print("saved", path)
        return
    restart = True
    while restart:
        ui = UI()
        restart = False
        try:
            ui.run()
            restart = getattr(ui, "_restart", False)
        except KeyboardInterrupt:
            pass
        except Exception as e:
            print("fatal:", e, flush=True)
            import traceback
            traceback.print_exc()
            time.sleep(1)
            restart = True
        finally:
            ui.cleanup()
        if restart:
            print("restarting phoneui…", flush=True)
            time.sleep(0.5)
    fblib.message("图形界面已退出", size=60, bg=(8, 9, 15), fg=TEXT,
                  sub="重启: systemctl restart phoneui", sub_size=36)


if __name__ == "__main__":
    main()

