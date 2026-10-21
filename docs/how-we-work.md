# 工作方式（用户明确要求，2026-10-21）

**除非用户明确喊停，否则我要一直干活，不要主动停下来。**

- 不要问"要继续吗"、"要不要收工"、"先到这？"这类问题。
- 不要因为时间晚（凌晨）、已经连续干了很多小时而主动建议暂停。
- 需要用户配合的操作（比如让手机进 fastboot 刷机），直接说明要做什么、请他操作即可；**不要用"要不要继续"来结束一轮**。
- 卡住时自己换思路继续找活干（查代码、翻原厂分区、改驱动、补文档、改进构建脚本等），不要把"要不要继续"抛回给用户。

用户原话：
> "除非要我重启手机之类的，不然不能停"
> "我说了 除非我喊停不然你就继续，把这个记住"

唯一可以等他的时候：确实需要他动手（进 fastboot、按电源键等），或者他喊停。

## 需要用户动手时的提醒方式

- **发声音提示**（Windows TTS 中文女声，比蜂鸣好认）：
  ```powershell
  Add-Type -AssemblyName System.Speech
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $s.SelectVoice('Microsoft Huihui Desktop'); $s.Rate = 2
  $s.Speak('需要你操作一下啦，请把手机进入 fastboot 哦')
  ```
- 然后**停下来等他**，明确说明要按什么键。
- 他做完会说一声（"好了"），我立刻继续，不要反复确认。

---

## ★ 远程刷机：不用再进 fastboot（2026-10-21 23:10）

本机的 `by-partlabel` 可用（99 个分区都能按名字访问），所以可以
**在 Linux 系统里直接 dd 写 boot/recovery 分区**，写完重启即可生效：

```sh
mi9-flash status                  # 看分区 / 备份
mi9-flash boot     <img>          # boot 分区（128MB）：DTB / edk2
mi9-flash recovery <img>          # recovery 分区（64MB）：内核 + 模块
```

实测一次（kernelfat r3.44）：

```
写入 recovery (/dev/sda28)：67108864 字节 / 分区 67108864 字节
备份 -> /var/backups/mi9-flash/recovery.20261021-231018.img
写入中... 校验通过 md5=2fcc36ed...
重启生效... 设备回来 = r3.44
```

镜像传输 14 MB/s，64MB 约 4.6 秒。

### 分区对照

| 分区 | 设备 | 大小 |
|---|---|---|
| `boot` | /dev/sde49 | 128 MB |
| `recovery` | /dev/sda28 | 64 MB |
| `dtbo` | /dev/sde45 | 32 MB（不动） |
| `vbmeta` | /dev/sde10 | 极小（不动） |

### 安全设计

1. **白名单**：只允许 `boot` / `recovery`，其它分区直接拒绝
2. 镜像大小必须 ≤ 分区大小
3. 默认先备份原分区到 `/var/backups/mi9-flash/`
4. 写完**回读 md5 校验**

### 这意味着

- 迭代循环：`PC 编译 → scp 镜像 → mi9-flash → 自动重启 → 回 WiFi`，全程无需接触手机
- 只有「刷坏了起不来」才需要物理进 fastboot（用 `fastboot flash recovery RECOVERY-kernelfat.img` 救）

**注意**：`mi9-flash` 只在系统能起来时可用；如果系统起不来，仍需 fastboot。
