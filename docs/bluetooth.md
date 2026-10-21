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

---

## 追加：真正的稳定性根因是「音频栈重复」（2026-10-22 02:35）

### 症状

反复出现「连上一两秒就断开」「没有声音」，但偶尔又能正常出声。极不稳定。

### 根因

设备上同时跑了两套音频栈：

- root 的登录会话（`user@0.service`）自带一套 pipewire/wireplumber
- 我们的 `mi9-bt-speaker` 守护又在 fallback 里自己起一套

于是出现：

```
sco_listen: listen(): Address already in use
register_profile_reply: RegisterProfile() failed: org.bluez.Error.NotPermitted
```

两个 wireplumber 抢着向 BlueZ 注册 A2DP profile，第二个必然失败，
结果 A2DP sink 建不出来 —— BlueZ 的 ACL 连上了但没有任何音频传输，
音箱等一会儿没数据就自己断开。

### 解决

**保证全局只有一份 pipewire / wireplumber / pipewire-pulse**。
`mi9-bt-speaker` 里加了健康判据，不满足就整体重建：

```sh
npw=$(pgrep -xc pipewire)
nwp=$(pgrep -xc wireplumber)
npl=$(pgrep -xc pipewire-pulse)

# 连得上、wireplumber 只有一份、pulse 兼容层在 → 健康
if wpctl status >/dev/null 2>&1 && [ "$nwp" = "1" ] && [ "$npl" -ge 1 ]; then
	return 0
fi

# 否则：停掉会话单元 + 杀光残留，再各起一份
systemctl --user stop pipewire-pulse wireplumber pipewire pipewire.socket
pkill -x pipewire-pulse; pkill -x wireplumber; pkill -x pipewire
nohup pipewire       >/var/log/mi9-pipewire.log       2>&1 &
nohup pipewire-pulse >/var/log/mi9-pipewire-pulse.log 2>&1 &
nohup wireplumber    >/var/log/mi9-wireplumber.log    2>&1 &
```

改完后：连接稳定、出声正常、重启后自动就绪。

### 第三个坑：`pipewire-pulse` 也要有

普通应用（mpg123、各类播放器）走的是 PulseAudio 接口。只起 `pipewire` +
`wireplumber` 时：

```
mpg123: No PulseAudio running. I will not accidentally trigger starting one.
```

必须把 `pipewire-pulse` 也拉起来（它就是 PulseAudio 兼容层）。

### 第四个坑：播放结束就被断开

A2DP 传输在流结束后会被回收，音箱随即断开 —— 表现为"放完一首就没了"。
解法就是常驻一路静音流保活（`BT_KEEPALIVE=1`，循环播
`/usr/share/mi9/silence-60s.wav`）。实测播完歌后空闲 25 秒连接仍在。

### 最终实测结论

| 场景 | 结果 |
|---|---|
| 连续播放 60 秒 | 连接稳定，音乐正常 |
| 播放结束再空闲 25 秒 | 连接保持（靠保活流） |
| 重启后 | 服务自动启动、音箱自动连接、自动设为默认输出 |

### 用法

```sh
mi9-bt-speaker status    # 看状态（含保活流、wireplumber 进程数）
mi9-bt-speaker once      # 手动连一次
mi9-bt-speaker start     # 守护（systemd 已在跑）
```

配置 `/etc/mi9-bt-speaker.conf`：

```
BT_MAC=40:31:3C:81:D6:DA
BT_VOLUME=0.9
BT_KEEPALIVE=1     # 强烈建议开：播放间隙不会断
```

播放音乐：

```sh
mpg123 -o pulse /path/to/music.mp3
```

---

## 追加：v2 设计 —— 哪些是主流、哪些是不得已（2026-10-22 02:45）

### 先回答一个关键问题：纯主流机制够不够？

**不够。** 实测：

| 机制 | 作用范围 | 我们需要的场景 |
|---|---|---|
| BlueZ `[Policy] ReconnectUUIDs` | 只在**链路超时**（link supervision timeout）时重连 | 音箱自己关机再开、被别的设备抢走 → **不触发** |
| WirePlumber `bluez5.auto-connect` | 主要在**监视器启动时**对已在范围/已连接的设备建立 profile | 运行期掉线 → **不覆盖** |
| BlueZ `AutoEnable=true` | 只负责开适配器 | 与设备连接无关 |

实测：手动 `disconnect` 之后，上面三条**都不会**把音箱连回来（观察 60 秒无动作）。
所以要有一个"监督者"在需要时发起 `Device1.Connect`。

### v2 的做法：事件驱动 + 慢兜底（不是盲轮询）

```
busctl monitor --match "type='signal',interface='org.bluez.Device1'" org.bluez
        ↓ 收到 Connected/Disconnected/Powered 信号
        立刻触发一次 健康检查 -> 连接 -> 设置默认输出
        ↓ 另外每 30 秒兜底一次（防止漏信号）
```

实测：手动断开后 **6 秒**自动恢复（v1 的 5 秒盲轮询是每 5 秒无脑调一次
`bluetoothctl connect`，既吵又慢）。

### 各项措施的性质对照

| 措施 | 性质 | 说明 |
|---|---|---|
| 单实例 `pipewire`/`wireplumber`/`pipewire-pulse` | ✅ **主流正确做法** | 多份会抢注册 A2DP profile |
| `session.suspend-timeout-seconds = 0` | ✅ 主流配置 | 避免空闲挂起断开 transport |
| `bluez5.auto-connect` + BlueZ `ReconnectUUIDs` | ✅ 主流配置 | 覆盖"启动时"和"链路超时"两种情况 |
| 事件驱动监督 + 30s 兜底 | ⚠️ 必要的补充 | 覆盖"设备自己关机/被抢占" |
| 手工造 `XDG_RUNTIME_DIR` + 会话 D-Bus | ⚠️ 环境所迫 | root 无 logind 会话；正常桌面自动有 |
| 静音 WAV 保活流 | ⚠️ 打补丁 | 本音箱空闲会自己断；正常 A2DP 不需要 |

### 依赖的软件包（重新装机要装）

```sh
apt-get install -y pipewire pipewire-pulse wireplumber \
                   libspa-0.2-bluetooth mpg123
```

- `libspa-0.2-bluetooth`：**没有它就没有 A2DP 端点**（连接报 br-connection-profile-unavailable）
- `pipewire`/`pipewire-pulse`/`wireplumber`：rootfs 原本只有库，没有守护进程
- `mpg123`：放 mp3 用（或任意走 PulseAudio 接口的播放器）

### 命令

```sh
mi9-bt-speaker status        # 状态（含音频栈进程数、保活流）
mi9-bt-speaker once          # 连一次并设为默认输出
mi9-bt-speaker test          # 放测试音
mi9-bt-speaker volume 0.9    # 设音量
mpg123 -o pulse 音乐.mp3      # 放音乐
```

### 配置项固化位置（重刷不丢）

```
payload/usr/local/sbin/mi9-bt-speaker.sh          v2 主脚本
payload/etc/systemd/system/mi9-bt-speaker.service 开机自启（已 enable）
payload/etc/mi9-bt-speaker.conf                    MAC/音量/保活开关
payload/etc/wireplumber/bluetooth.lua.d/51-no-suspend-bluez.lua
payload/etc/wireplumber/bluetooth.lua.d/52-autoconnect-a2dp.lua
payload/etc/bluetooth/main.conf                    ReconnectUUIDs/Attempts/Intervals
payload/usr/share/mi9/silence-60s.wav              保活流音源（11MB→gzip 11KB）
```
