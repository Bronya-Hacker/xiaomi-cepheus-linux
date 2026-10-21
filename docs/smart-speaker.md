# 把小爱音响做出来（Mi 9 主线 Linux）

目标：把 cepheus 变成一个**语音音箱** —— 能外放、能听、能联网、能蓝牙。

## 现状盘点（2026-10-21）

| 能力 | 状态 | 说明 |
|---|---|---|
| 联网 | ✅ | WiFi（ath10k）正常，能跑服务 |
| 外放（扬声器） | 🟡 攻坚中 | 功放 CS35L41 已识别，卡在 PLL/时钟，见 `docs/audio.md` |
| 麦克风 | ❌ | WCD9340 采集全 0，SLIMbus 数据面没通 |
| 蓝牙 | ✅ 协议栈 / 🟡 音频 | `hci0` 正常；A2DP 需要装 `bluealsa` |
| 常驻运行 | ✅ | 看门狗 30s、充电守卫、zram 2G |
| 按键/LED | ✅ | 音量键、电源键可用（`mi9-pwrkey`） |

## 分阶段计划

### 阶段 0：先让"有声音"这件事成立（不依赖内置功放）

两条都能立刻用：

1. **USB 声卡**：内核 `CONFIG_SND_USB_AUDIO=m` 已支持，
   插 USB 音箱/耳麦 → 直接出现在 `/proc/asound/cards`
2. **蓝牙音箱**：`apt install bluealsa`，配对后
   `aplay -D bluealsa ...` 或通过 PulseAudio 输出

这样**软件（唤醒词/播放/服务）可以先写起来**，硬件通了再切回内置喇叭。

### 阶段 1：内置扬声器（正在做）

已确认硬件：音频走 **QUATERNARY MI2S**（GPIO136-140）→ CS35L41。
已修：PLL 配置缺失、codec DAI 格式没设置。待验证。

### 阶段 2：麦克风

难点：WCD9340 采集全 0（SLIMbus TX 方向不搬数据）。
排查方向见 `docs/audio.md` 追加 10：
- `0x10bdb` 命令响应未处理
- TX 通道映射与 vendor 不同
- codec ADC/TX 端口是否真的在出数据

替代方案：**USB 麦克风**或**蓝牙麦克风**（同阶段 0）。

### 阶段 3：语音交互

- 唤醒词：`openWakeWord` / `Porcupine`（ARM64 有预编译）/ 讯飞离线
- 语音识别：本地 `whisper.cpp`（SM8150 cpu 可跑小模型）或云端 API
- 播放：`mpv`/`aplay`，TTS 用 `espeak-ng` 或云端
- 整体框架：一个 systemd 服务 + 简单状态机

### 阶段 4：做成"音箱"的形态

- 常亮/息屏策略（已有 `mi9-screen-off.timer`）
- 音量键直连音量控制
- 网络断开自动重连（`NetworkManager`）
- 上电自启（systemd 已就绪）

## 立即可做的验证

```sh
# 看当前音频能力
cat /proc/asound/cards
mi9-doctor            # 会显示声卡/功放状态

# USB 声卡（插上后）
aplay -l              # 看有没有 USB Audio
speaker-test -D plughw:1,0 -t sine -f 440 -l 1

# 蓝牙音箱
apt install -y bluealsa
bluetoothctl           # pair/trust/connect
```
