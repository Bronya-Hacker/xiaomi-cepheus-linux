#!/usr/bin/python3
# ---------------------------------------------------------------------------
# mi9-screend（文件名沿用 mi9-pwrkey.py）—— 电源键切换 + 手机式息屏
#
# 需求：这是台服务器，屏幕只是"人凑过来看一眼"用的。
#   1) 开机后 60 秒（mi9-screen-off.timer）先熄一次；
#   2) 按电源键亮屏；
#   3) 亮屏后**一段时间没有输入就自动再熄**（和手机"息屏时间"一样），
#      任何按键 / 触摸都会把计时清零重来。
#
# 为什么不用内核的 console blanking：fb0 是 simplefb，没有 fb_blank；
# consoleblank 参数只读且 cmdline 固定为 0（详见 mi9-screen.sh 文件头）。
# 所以这里自己读 evdev，空闲到点就调 mi9-screen.sh off。
#
# 监听哪些设备：/dev/input/event* 全部（本机是 pm8941_pwrkey / pm8941_resin /
# gpio_keys / fts 触屏）。evdev 允许多个读者，systemd-logind 也读同一个设备
# 不影响我们（logind 的 HandlePowerKey 已设成 ignore，不会关机）。
#
# 配置：/etc/mi9-screen.conf 里的 SCREEN_TIMEOUT=<秒>，0 = 关闭空闲熄屏。
#
# 事件结构（aarch64）：
#   struct input_event { struct timeval time; __u16 type, code; __s32 value; }
#   timeval 两个 long = 16 字节，所以 fmt = "llHHi"
# ---------------------------------------------------------------------------
import glob
import os
import select
import struct
import subprocess
import time

EV_KEY = 1
EV_ABS = 3
KEY_POWER = 116
EVENT = struct.Struct("llHHi")

SCREEN = "/usr/local/sbin/mi9-screen.sh"
STATE = "/run/mi9-screen.state"
CONF = "/etc/mi9-screen.conf"
DEFAULT_TIMEOUT = 60
RESCAN_EVERY = 30.0


def idle_timeout():
    """秒数；0 表示关闭空闲熄屏。配置读不出来就用默认 60。"""
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("SCREEN_TIMEOUT"):
                    return int(line.split("=", 1)[1].strip() or 0)
    except (OSError, ValueError, IndexError):
        pass
    return DEFAULT_TIMEOUT


def screen_is_on():
    try:
        with open(STATE) as f:
            return f.read().strip() != "off"
    except OSError:
        return True


def run(action):
    subprocess.run([SCREEN, action], check=False)


def open_devices(handles):
    for path in sorted(glob.glob("/dev/input/event*")):
        if path in handles:
            continue
        try:
            handles[path] = open(path, "rb", buffering=0)
            print("mi9-screend: + %s" % path, flush=True)
        except OSError:
            pass
    return handles


def drop(handles, path):
    try:
        handles[path].close()
    except OSError:
        pass
    handles.pop(path, None)


def main():
    timeout = idle_timeout()
    handles = open_devices({})
    print("mi9-screend: watching %d input device(s), idle timeout %s"
          % (len(handles), ("%ds" % timeout) if timeout else "disabled"),
          flush=True)

    last_activity = time.monotonic()
    last_toggle = 0.0
    last_scan = time.monotonic()
    was_on = screen_is_on()

    while True:
        now = time.monotonic()
        wait = 5.0
        if timeout:
            wait = max(0.2, min(5.0, timeout - (now - last_activity)))

        fds = {h.fileno(): p for p, h in handles.items() if not h.closed}
        try:
            ready, _, _ = select.select(list(fds), [], [], wait)
        except (OSError, ValueError):
            for p in list(handles):
                drop(handles, p)
            time.sleep(1)
            handles = open_devices(handles)
            continue

        now = time.monotonic()

        # 屏幕被"别人"点亮（手动 mi9-screen.sh on、别的服务）也要重新计时，
        # 否则一次手动亮屏会被这里的空闲逻辑在几秒内又熄回去。
        on_now = screen_is_on()
        if on_now and not was_on:
            last_activity = now
        was_on = on_now
        for fd in ready:
            path = fds.get(fd)
            if path is None:
                continue
            try:
                data = handles[path].read(EVENT.size)
            except OSError:
                drop(handles, path)
                continue
            if len(data) < EVENT.size:
                continue
            _, _, etype, code, value = EVENT.unpack(data)
            if etype == EV_KEY and value == 1:
                last_activity = now
                if code == KEY_POWER and now - last_toggle > 0.4:
                    last_toggle = now
                    if screen_is_on():
                        print("mi9-screend: power key -> blank", flush=True)
                        run("off")
                    else:
                        print("mi9-screend: power key -> wake", flush=True)
                        run("on")
                    last_activity = time.monotonic()
            elif etype == EV_ABS:
                last_activity = now

        # --- 空闲到点：熄屏（只熄亮着的）---
        now = time.monotonic()
        if timeout and now - last_activity >= timeout and screen_is_on():
            print("mi9-screend: idle %ds -> blank" % timeout, flush=True)
            run("off")
            last_activity = now

        # --- 热插拔 / 设备重连：偶尔重新扫一遍 ---
        if now - last_scan > RESCAN_EVERY:
            last_scan = now
            handles = open_devices(handles)


if __name__ == "__main__":
    main()
