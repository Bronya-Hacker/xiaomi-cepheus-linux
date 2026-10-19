#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# uitap.py -- 用 uinput 造一个虚拟多点触摸设备，从 stdin 读命令注入事件
#   命令：
#     tap X Y [ms]               点按
#     swipe X1 Y1 X2 Y2 [ms]     滑动
#     hold X Y MS                长按
#   用法： mkfifo /run/uitap.fifo; setsid python3 uitap.py < /run/uitap.fifo &
#          echo "tap 270 700" > /run/uitap.fifo
import os, sys, time, struct, fcntl

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
SYN_REPORT = 0
BTN_TOUCH = 330
ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x2F, 0x35, 0x36
ABS_MT_TRACKING_ID, ABS_MT_PRESSURE = 0x39, 0x3A

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_SET_PROPBIT = 0x4004556E
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
FMT = struct.Struct("llHHi")

ABS_CNT = 0x40
NAME_MAX = 80


def legacy_setup(name="virtual-touch", xmax=1079, ymax=2339):
    """传统 uinput 接口：必须先 write() 这个结构，内核才允许 UI_DEV_CREATE"""
    buf = bytearray(NAME_MAX + 8 + 4 + 4 * ABS_CNT * 4)
    nm = name.encode()[:NAME_MAX - 1]
    buf[0:len(nm)] = nm
    off = NAME_MAX + 8 + 4          # 跳过 name / input_id / ff_effects_max
    struct.pack_into("<I", buf, off + ABS_MT_POSITION_X * 4, xmax)     # absmax
    struct.pack_into("<I", buf, off + ABS_MT_POSITION_Y * 4, ymax)
    struct.pack_into("<I", buf, off + ABS_MT_PRESSURE * 4, 255)
    struct.pack_into("<I", buf, off + ABS_MT_SLOT * 4, 9)
    return bytes(buf)


def main():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for t in (EV_SYN, EV_KEY, EV_ABS):
        fcntl.ioctl(fd, UI_SET_EVBIT, t)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH)
    for c in (ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID, ABS_MT_PRESSURE):
        fcntl.ioctl(fd, UI_SET_ABSBIT, c)
    fcntl.ioctl(fd, UI_SET_PROPBIT, 1)      # INPUT_PROP_DIRECT
    os.write(fd, legacy_setup())            # 传统接口：必须先写 uinput_user_dev
    fcntl.ioctl(fd, UI_DEV_CREATE, 0)
    time.sleep(0.8)
    print("uitap: virtual touch ready", flush=True)

    def ev(typ, code, val):
        os.write(fd, FMT.pack(0, 0, typ, code, val))

    def sync():
        ev(EV_SYN, SYN_REPORT, 0)

    tid = [100]

    def down(x, y):
        tid[0] += 1
        ev(EV_KEY, BTN_TOUCH, 1)
        ev(EV_ABS, ABS_MT_SLOT, 0)
        ev(EV_ABS, ABS_MT_TRACKING_ID, tid[0])
        ev(EV_ABS, ABS_MT_POSITION_X, int(x))
        ev(EV_ABS, ABS_MT_POSITION_Y, int(y))
        ev(EV_ABS, ABS_MT_PRESSURE, 60)
        sync()
        return tid[0]

    def move(x, y):
        ev(EV_ABS, ABS_MT_POSITION_X, int(x))
        ev(EV_ABS, ABS_MT_POSITION_Y, int(y))
        sync()

    def up():
        ev(EV_ABS, ABS_MT_TRACKING_ID, -1)
        ev(EV_ABS, ABS_MT_PRESSURE, 0)
        ev(EV_KEY, BTN_TOUCH, 0)
        sync()

    for line in sys.stdin:
        p = line.split()
        if not p:
            continue
        try:
            if p[0] == "tap":
                x, y = int(p[1]), int(p[2])
                hold = int(p[3]) / 1000.0 if len(p) > 3 else 0.08
                down(x, y)
                time.sleep(hold)
                up()
                print("uitap: tap %d %d" % (x, y), flush=True)
            elif p[0] == "hold":
                x, y, ms = int(p[1]), int(p[2]), int(p[3])
                down(x, y)
                time.sleep(ms / 1000.0)
                up()
                print("uitap: hold %d %d %dms" % (x, y, ms), flush=True)
            elif p[0] == "swipe":
                x1, y1, x2, y2 = (int(v) for v in p[1:5])
                dur = int(p[5]) / 1000.0 if len(p) > 5 else 0.4
                n = 12
                down(x1, y1)
                for i in range(1, n + 1):
                    move(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n)
                    time.sleep(dur / n)
                up()
                print("uitap: swipe %d,%d -> %d,%d" % (x1, y1, x2, y2), flush=True)
            elif p[0] == "quit":
                break
            else:
                print("uitap: unknown %r" % (p,), flush=True)
        except Exception as e:
            print("uitap: err %s (%r)" % (e, p), flush=True)
    try:
        fcntl.ioctl(fd, UI_DEV_DESTROY, 0)
    except Exception:
        pass
    os.close(fd)


if __name__ == "__main__":
    main()
