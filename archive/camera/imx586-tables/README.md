# IMX586 寄存器表来源（M3 的"数据墙"已破）

## 结论

小米公开的内核（`cepheus-q-oss` / `cepheus-p-oss`）**不含**传感器驱动；
官方 ROM 里只有 `com.qti.sensormodule.*.bin`（"Parameter Parser V1.3.1" 私有容器），
解析成本高。

**改用 Rockchip 的公开内核**：

```
https://gh-proxy.com/https://raw.githubusercontent.com/rockchip-linux/kernel/develop-5.10/drivers/media/i2c/imx586.c
```

55 KB、2366 行，标准 v4l2 结构（`v4l2_subdev` + `v4l2_ctrl` + media entity），自带完整表：

| 表 | 内容 |
|---|---|
| `imx586_linear_10bit_global_regs[]` | 全局初始化 |
| `imx586_linear_10bit_4000x3000_30fps_nopd_regs[]` | 4000x3000 30fps |
| `imx586_linear_10bit_full_raw_6fps_regs[]` | 全尺寸 RAW 6fps |
| `imx586_linear_10bit_full_remosaic_6fps/10fps_regs[]` | 48MP remosaic |

已存为同目录的 `imx586-rockchip.c`。

## 移植到主线要做的

1. 去掉 Rockchip 私有依赖：`<linux/rk-camera-module.h>`、`rk_sensor_*`，
   换成主线标准写法（参考 `drivers/media/i2c/imx412.c`）；
2. 加 `sony,imx586` 的 of_match 与 DT binding；
3. DT 节点（i2c 0x1A）：clocks（MCLK 24 MHz）、regulators（VANA/VDIG/VIO/VAF）、
   reset/pwdn GPIO、port/endpoint 接到 `&camss` 的 csiphy；
4. 电源时序与 GPIO 极性参考下游 `cepheus-camera-sensor.dtsi`
   （在 MiCode `cepheus-q-oss` 的 `arch/arm64/boot/dts/vendor/qcom/` 下）。

## 现状

- M1 时钟 ✅、M2 采集管线 ✅（真机验证）
- M3 数据 ✅（本文）
- 剩下是纯编码：驱动移植 + DT + 出帧调试

## 移植进度（2026-10-20 13:57）

`imx586-mainline.c` = Rockchip 版去掉私有依赖后的主线版，**已编译成 `imx586.ko`**。

已做的修改：

- 删掉 `rk-camera-module.h` / `rk-preisp.h` / `otp_eeprom.h` 依赖；
- 删掉 Rockchip 私有功能：`RKMODULE_*` ioctl、module info、OTP、SPD、HDR AE 初始化；
- 补 `PAD0/PAD_MAX/NO_HDR/V4L2_MBUS_CSI2_CHANNEL_0` 等定义；
- V4L2 API 升级到 6.17：
  - `v4l2_subdev_pad_config` → `v4l2_subdev_state`
  - `v4l2_subdev_get_try_format(sd,cfg,pad)` → `v4l2_subdev_state_get_format(cfg,pad)`
  - `v4l2_async_register_subdev_sensor_common` → `..._sensor`
  - `probe(client, id)` → `probe(client)`，`remove` 返回 void
  - 去掉 `.get_mbus_config` / `.g_frame_interval` / `.s_frame_interval` 旧接口
- Kconfig：`CONFIG_VIDEO_IMX586`（注意 `select MEDIA_CONTROLLER` 那几行会让 olddefconfig
  把符号丢掉，改成就 `depends on I2C && VIDEO_DEV` 后正常）

## 还差什么才能出图

1. **CCI**：主线 `i2c-qcom-cci` 支持 sdm845/sm8250/sm8450（都是 `cci_v2_data`），
   SM8150 的 CCI 同代，加一条 `qcom,sm8150-cci → cci_v2_data` 即可；
2. **DT**：`sm8150.dtsi` 里目前没有 cci 节点，需要加（`0xac4a000`/`0xac4b000`，
   时钟用 camcc 的 `cam_cc_cci_0/1_clk`），再加 imx586 的 i2c 节点（地址 0x1A）；
3. 传感器电源：VANA/VDIG/VIO/VAF + MCLK 24 MHz + reset/pwdn GPIO
   （参考下游 `cepheus-camera-sensor.dtsi`）；
4. 然后 `media-ctl -p` 应出现 `imx586` 实体，接 `csiphy0` → `csid0` → `vfe0` 出第一帧。

## CCI + DT 进度（2026-10-20 14:09）

- `i2c-qcom-cci` 加了 `qcom,sm8150-cci → cci_v2_data`（和 sdm845/sm8250 同代）；
- `sm8150.dtsi` 加了 CCI 节点：
  - `cci@ac4a000`，IRQ 460（下游 DT 的 `0x1cc`），
    时钟用 camcc 的 `CAM_CC_CPAS_AHB_CLK` / `CAM_CC_CCI_0_CLK_SRC` / `CAM_CC_CCI_0_CLK`；
  - 子节点 `i2c-bus@0`。
- DTB 编译通过。

### 还差

1. 传感器节点 `camera@1a`（`sony,imx586`）：
   - `xvclk = <&camcc CAM_CC_MCLK0_CLK>`；
   - `avdd/dovdd/dvdd` 三路电源 —— **真实 PMIC 轨还没确认**（下游 DT 不在公开仓库里，
     需要从 `dtbo.img` 或 vendor kernel 的 `cepheus-camera-sensor.dtsi` 里挖）；
   - `reset-gpios` / `pwdn-gpios`（TLMM 引脚号同样是下游数据）。
2. camss 的 sensor→csiphy 链路：camss 的 csiphy 子设备没有 of_graph 端口，
   要看 camss-core 的 async notifier 期望什么形式的 endpoint。
