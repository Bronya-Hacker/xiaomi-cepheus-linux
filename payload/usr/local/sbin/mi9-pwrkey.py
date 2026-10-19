#!/usr/bin/python3
# ---------------------------------------------------------------------------
# mi9-pwrkey.py —— 电源键短按 = 熄屏 / 亮屏
#
# 为什么不用 console blanking：fb0 是 simplefb，没有 fb_blank；consoleblank
# 参数只读且 cmdline 固定为 0（详见 mi9-screen.sh 文件头）。
#
# 这里直接读 evdev：/dev/input/event* 里名字是 "pm8941_pwrkey" 的那个设备。
# 只认 EV_KEY / KEY_POWER(116) / value=1（按下），0.4 秒内去重。
# 按下时看 /run/mi9-screen.state：
#   off -> 调 mi9-screen.sh on   （重启仪表盘，画面回来）
#   其它 -> 调 mi9-screen.sh off （熄屏）
#
# evdev 允许多个读者同时 open，systemd-logind 也读同一个设备并不影响我们
# （logind 的 HandlePowerKey 已经设成 ignore，不会关机）。
# ---------------------------------------------------------------------------
import glob
import struct
import subprocess
import time

EV_KEY = 1
KEY_POWER = 116
# aarch64 上 struct input_event:
#   struct timeval time  -> 2 * 8 字节
#   __u16 type, __u16 code, __s32 value -> 2 + 2 + 4
EVENT = struct.Struct("llHHi")
SCREEN = "/usr/local/sbin/mi9-screen.sh"
STATE = "/run/mi9-screen.state"


def find_device():
    for path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            with open(path) as f:
                name = f.read().strip()
        except OSError:
            continue
        if name == "pm8941_pwrkey":
            # /sys/class/input/event0/device/name -> /dev/input/event0
            return "/dev/input/" + path.split("/")[4]
    return "/dev/input/event0"


def is_off():
    try:
        with open(STATE) as f:
            return f.read().strip() == "off"
    except OSError:
        return False


def run(action):
    subprocess.run([SCREEN, action], check=False)


def main():
    dev = find_device()
    print("mi9-pwrkey: watching %s (KEY_POWER)" % dev, flush=True)
    last = 0.0
    while True:
        try:
            with open(dev, "rb", buffering=0) as f:
                while True:
                    data = f.read(EVENT.size)
                    if len(data) < EVENT.size:
                        time.sleep(0.2)
                        continue
                    _, _, etype, code, value = EVENT.unpack(data)
                    if etype != EV_KEY or code != KEY_POWER or value != 1:
                        continue
                    now = time.monotonic()
                    if now - last < 0.4:      # 去重（PMIC 偶尔会连发）
                        continue
                    last = now
                    if is_off():
                        print("mi9-pwrkey: wake", flush=True)
                        run("on")
                    else:
                        print("mi9-pwrkey: blank", flush=True)
                        run("off")
        except OSError as exc:
            print("mi9-pwrkey: %s, retrying" % exc, flush=True)
            time.sleep(2)


if __name__ == "__main__":
    main()
