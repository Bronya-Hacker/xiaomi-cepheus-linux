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
