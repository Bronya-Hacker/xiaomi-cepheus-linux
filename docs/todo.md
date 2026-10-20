# 这台机器还差什么（2026-10-20 体检）

真机体检结果 + 待办优先级。已完成项的细节见 `docs/ir-nfc.md`、`docs/camera-port.md`。

## 当前健康状态

| 项 | 状态 |
|---|---|
| 服务 | 0 failed unit，无 deferred 设备 |
| CPU 调频 | schedutil，8 核 |
| 温度 | 23 个 thermal zone，正常 33–44 °C |
| 电池 | 82%，充电中，4.0 V |
| 看门狗 | ✅ qcom_wdt，systemd 30 秒喂狗（本次完成） |
| ADSP / Modem | ✅ 两个 remoteproc 都 running |

## 已完成（本轮）

### 硬件看门狗

- `/dev/watchdog0`（qcom_wdt）；
- 配置 `/etc/systemd/system.conf.d/watchdog.conf`：
  `RuntimeWatchdogSec=30s`、`RebootWatchdogSec=60s`；
- systemd 日志确认：`Using hardware watchdog 'qcom_wdt' ... timeout of 30s`；
- 已放进 payload，随系统一起发布。

## 待攻克

### 1. 音频（扬声器 / 麦克风）—— 大工程

好消息：主线**已经有**这两块：
- `sound/soc/qcom/sm8150.c`，compatible `qcom,sm8150-sndcard`（machine driver）；
- `sound/soc/codecs/wcd934x.c`（`CONFIG_SND_SOC_WCD934X=m`）；
- `sm8150.dtsi` 里有 SLIMbus 控制器 `slim: slim-ngd@171c0000`。

缺的是 DT 和板级接线：
1. `&slim` 使能 + 挂 WCD9340 codec 子节点（地址 `1,0`）；
2. WSA881x 功放（走 SoundWire，需要在 DT 加 swr 节点）；
3. `sound` 卡节点（`compatible = "qcom,sm8150-sndcard"`）+ dai-link 子节点；
4. 音频通路（audio-routing / widgets）要按 cepheus 的实际接线写。

预计：2–4 天（和相机同量级，但风险低得多——不涉及高压/锁总线）。

### 2. 蜂窝数据（Modem 上网）—— 大工程，价值低

modem 固件已经跑起来（`remoteproc0: running qcom/sm8150/modem.mdt`），
但数据通路需要 rmnet / QMI / IPA 一套，主线对 SM8150 的支持很有限。
服务器用途一般不需要，建议不做。

### 3. 运动传感器 / 环境光 —— 中等

现在只有 PMIC 的 ADC（`iio:device0..2`），加速度计、光线传感器都没驱动：
- 需要先把对应的 QUP I2C 总线打开（现在只开了 NFC 和触摸两条）；
- 芯片型号要从原厂 DT 里挖（大概率是 BMI160/LSM6DS 之类）；
- 主线大多有现成驱动，主要是 DT 接线。

预计：半天到一天。

### 4. 休眠省电 —— 小，但要真机验证

`/sys/power/state` 支持 `freeze mem`，没测过唤醒是否可靠。
风险：测挂了需要你按电源键。对服务器（常插电）价值一般。

### 5. 直供电适配 —— 等硬件改完

你打算用直供模块接电池保护板（没有真电池）。要注意：
- `qcom-battery` 可能报 0% 或 no battery，某些服务（如 UPS 逻辑）会误判；
- 充电驱动在“无电池”状态下可能拒绝启动或反复重试，届时看 dmesg 的
  `pm8150b-charger` 报错再定；
- 建议改完后先跑一次 `mi9-doctor`，确认没有异常单元。

## 建议顺序

1. **运动传感器**（半天，风险低，对监控类用途有用）；
2. **音频**（2–4 天，风险低，但需要你有明确用途）；
3. 直供电适配（等硬件到位）；
4. 蜂窝、休眠（按需）。

## 事故记录：一次性打开全部 QUP I2C 总线导致无法启动（2026-10-20 22:05）

想用 i2cdetect 找传感器，于是在 DT 里把 i2c0/2/3/4/5/6/7/8/10/11/12/16/18/19
全部设成 `status = "okay"`。刷完开机后**系统起不来**（USB 和 WiFi 都不通）。

### 原因

有几条 QUP SE 的引脚和其它外设**共用**（相机、显示、USB 等），
把它们当 I2C 打开会把那些引脚重新复用，导致必需外设失效。

### 恢复

- 长按电源强制关机 → fastboot；
- 刷回（从 dtsi 里删掉整块 `SENSOR SCAN`）重建的 boot 镜像；
- 恢复后一切正常。

### 教训

★ **不能一次性打开所有 QUP 总线**，只能一条一条试，且每次都要准备回退镜像。

### 已确认的总线现状

| 总线 | 地址 | 设备 |
|---|---|---|
| i2c-0 (a84000) | 0x28 | NFC（驱动占用） |
| i2c-1 (c80000) | 0x49 | 触摸屏 fts |

两条总线上都没有其它设备，所以传感器不在这两条上。

## 构建改进：payload 版本号改成「内容指纹」（2026-10-20 22:30）

### 问题

`payload/etc/wifi-cfg.ver` 是**手写字符串**。initramfs 拿它和 rootfs 上的
`/etc/wifi-cfg.ver` 比较，一样就跳过解压。所以改了 `.ko` 但忘了改版本号时，
刷 kernelfat 根本不会更新模块——今天救砖时就吃了这个亏。

### 改法

`scripts/02-build-kernel.sh` 现在把版本号拼成：

```
<手动标记>+m<模块内容指纹>+p<payload内容指纹>
```

- 模块指纹：`$INST/lib/modules/$KVER` 下所有 `.ko` 的内容哈希；
- 载荷指纹：`payload/` 下所有文件（排除版本号文件本身）的内容哈希；
- **只对内容取哈希**：`touch` 一下 mtime 变了但内容没变 → 指纹不变（不会
  每次构建都强制解压）；
- 内容一改 → 指纹必变 → 设备上一定会重新解压。

实测：`touch` 后 `953c5306` 不变；改一个字符后变 `4a479812`。

## 传感器重新评估：不在 AP 侧，挂在 SLPI 上（2026-10-20 22:40）

原厂 DT 里有这些节点：

```
qcom,slpi_qrtr          （SLPI 的 QRTR 通道）
qcom,slpi_glink_ssr     （SLPI 的 glink 重启通知）
qcom,slpi-pinctrl       （SLPI 的引脚控制器）
```

说明小米 9 的传感器（加速度计、陀螺仪、光线、霍尔等）由 **SLPI
（Sensor Low Power Island，传感器低功耗岛）** 这颗 DSP 管理，I2C 总线
也归 SLPI 控制——**AP 侧（主内核）根本访问不到那些总线**。

这就解释了：

- 把 i2c0/2/3/… 全打开也扫不到任何传感器；
- 现有两条总线（NFC 0x28、触摸 0x49）上没有任何传感器。

### 结论：传感器是「大工程」，不是半天

要在主线用上传感器，需要：

1. 让 SLPI remoteproc 起来（加载 `slpi.mdt` 固件）；
2. 实现 / 移植 **SSC（Snapdragon Sensor Core）协议**（QRTR + sensor
   service），这是 vendor 私有的一大套；
3. 或者反过来：把 SLPI 的 I2C 抢过来由 AP 直接驱动——需要知道每条总线
   上具体是什么芯片（厂商只写在 SLPI 的配置里，DT 里没有）。

难度和相机相当，**不建议短期投入**。

### 修正后的优先级

| 方向 | 结论 |
|---|---|
| 红外 / NFC 节点 / 看门狗 | ✅ 已完成 |
| 音频数据面 | 🟡 卡在 SLIMbus 数据通路，需要 vendor 资料或抓波形 |
| NFC 协议层 | 🟡 疑似固件问题，需要厂商固件文件 |
| 传感器 | 🔴 需要 SLPI + SSC，等于重做一个子系统 |
| 直供电适配 | ⏸ 等硬件改完 |
