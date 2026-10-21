# 蓝牙音频（含：绕开卡死的 ADSP 音频通路）

## 结论先行

内部喇叭/麦克风都卡在 ADSP 固件层，**蓝牙音频是唯一能真正出声的路**：

```
应用 -> PipeWire -> bluez5(A2DP) -> hci_uart -> QCA wcn3990 -> 音箱
```

这条路不经过 ADSP，实测 **小爱音箱能正常出声**（880Hz/1320Hz 交替音可听）。

## 硬件/驱动

- 芯片与 WiFi 共用 **QCA wcn3990**，蓝牙走 **UART**（`hci_uart` + `btqca`）
- 内核自带支持：开机就自动下载固件并建好 hci0

```
[    4.684665] Bluetooth: hci0: QCA Downloading qca/crbtfw21.tlv
[    4.808684] Bluetooth: BNEP (Ethernet Emulation) ver 1.3
[    5.477697] Bluetooth: hci0: QCA Downloading qca/crnv21.bin
[    5.621819] Bluetooth: hci0: QCA setup on UART is completed   ← 这里就好了
```

需要的内核选项（我们已开）：

```
CONFIG_BT=m  CONFIG_BT_QCA=m  CONFIG_BT_HCIUART=m
CONFIG_BT_HCIUART_SERDEV=y  CONFIG_BT_HCIUART_H4=y
```

## 用户态要补的两件东西

1. **`libspa-0.2-bluetooth`**
   只有 `libspa-0.2-modules` 时，连接音箱会报：

   ```
   Failed to connect: org.bluez.Error.Failed br-connection-profile-unavailable
   ```

   装上它才有 A2DP 端点（SBC/aptX/LDAC/LC3 都在里面）。

2. **PipeWire 守护进程本身**（`pipewire` / `pipewire-pulse` / `wireplumber`）
   rootfs 里原来只有库没有可执行文件。

## ★ 三个踩过的坑

### 1. root 没有登录会话 → 必须自己起音频栈

我们是 SSH 直接 root 登录，没有 logind 会话，PipeWire 不会自启。脚本里先：

```sh
mkdir -p /run/user/0; chmod 700 /run/user/0
export XDG_RUNTIME_DIR=/run/user/0
nohup pipewire     >/var/log/mi9-pipewire.log     2>&1 &
nohup wireplumber  >/var/log/mi9-wireplumber.log  2>&1 &
```

### 2. WirePlumber 空闲挂起 → 音箱秒断

默认 `session.suspend-timeout-seconds = 5`：节点一挂起，BlueZ 就关 A2DP transport，
音箱随即断开（表现为"连上 1~2 秒就断"）。解法是禁用蓝牙节点的空闲挂起：

`etc/wireplumber/bluetooth.lua.d/51-no-suspend-bluez.lua`

```lua
if bluez_monitor then
	table.insert(bluez_monitor.rules, {
		matches = { { { "node.name", "matches", "bluez_output.*" } } },
		apply_properties = { ["session.suspend-timeout-seconds"] = 0 },
	})
end
```

实测：装上后 **90 秒纯空闲连接不丢**。

### 3. 拿 /dev/zero 当静音流保活 → 不行

```
sndfile: failed to open audio file "/dev/zero": Format not recognised.
```

`pw-cat` 走 sndfile，必须是真 WAV。
payload 里放了 `/usr/share/mi9/silence-60s.wav`（11.5MB 裸数据，gzip 后仅 11KB），
需要时 `BT_KEEPALIVE=1` 就循环播它。（有了 no-suspend 规则后默认不需要。）

## 常驻服务

`mi9-bt-speaker.service`（已加入开机启用）：

- 保证 pipewire/wireplumber 在跑
- 自动连接配对过的音箱，断线 5 秒内重连（实测 6 秒自愈）
- 把蓝牙 sink 设为默认输出并把音量拉到配置值

```sh
mi9-bt-speaker once     # 只连一次、设默认输出
mi9-bt-speaker start    # 常驻守护
mi9-bt-speaker status   # 看状态
mi9-bt-speaker stop
```

配置写在 `/etc/mi9-bt-speaker.conf`：

```
BT_MAC=40:31:3C:81:D6:DA   # 小爱音箱-3418
BT_VOLUME=0.8
BT_KEEPALIVE=0
```

## 换音箱怎么操作

```sh
bluetoothctl scan on                       # 找到设备
bluetoothctl pair <MAC>                    # 配对
bluetoothctl trust <MAC>                   # 信任（自动重连更顺）
# 把 MAC 写进 /etc/mi9-bt-speaker.conf 的 BT_MAC
mi9-bt-speaker once
```

## 已知现象

- 播完一段音频后音箱有时会自己断开，守护会在几秒内自动连回来
- 内置喇叭仍无声（CS35L41 保护 DSP 引导不了），蓝牙是目前的出声方案
