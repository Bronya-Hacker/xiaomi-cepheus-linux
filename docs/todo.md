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
