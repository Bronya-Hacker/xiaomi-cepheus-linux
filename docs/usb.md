# USB / OTG / Type-C（cepheus）

## 现状（2026-10-21）

| 项目 | 状态 |
|---|---|
| USB 设备模式（gadget / USB 网卡） | ✅ 正常（一直是靠它连手机） |
| USB 控制器双角色（dwc3 `dr_mode = "otg"`） | ✅ 已启用 |
| PM8150B Type-C 控制器（tcpm） | ✅ probe 成功，`/sys/class/typec/port0` 出现 |
| Type-C 角色识别 | ✅ `port_type = [dual] source sink`、`preferred_role = sink` |
| dwc3 角色切换（role switch） | 🟡 设备已注册，但 `role` 属性缺失，切换未验证 |
| USB Host 实际枚举外设 | ⬜ 待插 OTG 设备验证 |

## 硬件接线

USB 口接在 **PM8150B** 的 Type-C 上（不是独立 Type-C 控制器）：

- Type-C 检测/PD：`pm8150b_typec`（SPMI `pmic@2`，reg `0x1500` + PD PHY `0x1700`）
- OTG 对外 5V：`pm8150b_vbus`（`usb-vbus-regulator@1100`）
- USB 控制器：`usb_1`（wrapper `a6f8800`）/ `usb_1_dwc3`（`a600000`）
- PHY：`usb_1_hsphy`（`88e2000`，USB2）+ `usb_1_qmpphy`（USB3，本机只用 USB2）

## 关键改动（都在 `dts/cepheus-usb.dtsi`）

```dts
&usb_1        { qcom,select-utmi-as-pipe-clk; status = "okay"; };
&usb_1_dwc3   { dr_mode = "otg"; usb-role-switch;
                phys = <&usb_1_hsphy>; phy-names = "usb2-phy"; };
&usb_1_dwc3_hs { remote-endpoint = <&pm8150b_hs_in>; };
&pm8150b_vbus { status = "okay"; };
&pm8150b_typec {
	vdd-vbus-supply = <&pm8150b_vbus>;
	vdd-pdphy-supply = <&vreg_l2a_3p1>;
	status = "okay";
	connector {
		compatible = "usb-c-connector";
		power-role = "dual"; data-role = "dual"; try-power-role = "sink";
		sink-pdos = <PDO_FIXED(5000, 3000, PDO_FIXED_USB_COMM)>;
		source-pdos = <PDO_FIXED(5000, 1500, PDO_FIXED_USB_COMM)>;
		op-sink-microwatt = <500000>;
		ports { #address-cells = <1>; #size-cells = <0>;
			port@0 { reg = <0>;
				pm8150b_hs_in: endpoint {
					remote-endpoint = <&usb_1_dwc3_hs>;
				};
			};
		};
	};
};
```

## 踩过的三个坑（都很隐蔽）

1. **追加到 `.dts` 末尾的东西会被 `apply-dts*.sh` 冲掉**
   —— 每次跑 `02-build-kernel.sh` 都会重写板级 DTS。表现是"改了没生效"，以及
   DTC 报 `Reference to non-existent node or label "pm8150b_hs_in"`。
   **正确做法：放进 `dts/cepheus-usb.dtsi`，由 `apply-dts5.sh` 同步并 `#include`。**
   同理，看 DTB 是否真的更新了，别只看 `make` 没报错 —— 编译失败时旧的 .dtb 还在。

2. **`tcpm_register_port()` 返回 -22 但没有任何日志**
   逐个加打印才确认：port_probe / pdphy_probe / connector / 9 个回调全都正常，
   真凶是 `tcpm_fw_get_caps()`：**给了 `sink-pdos` 就必须给 `op-sink-microwatt`**，
   否则直接 -EINVAL。补上 500000 后立刻通过。

3. **首次 probe 会是 -517（EPROBE_DEFER）**
   正常现象：`vdd-vbus`（pm8150b_vbus）比 typec 晚注册，重试即成功。
   日志里看到 `-517` 不用管。

## 待验证：Host 模式

当前 `usb_role_switch` 类设备存在（`/sys/class/usb_role/a600000.usb-role-switch`）。

★ **别被 "没有 role 属性" 误导**：dwc3 注册 role switch 时没有把
`allow_userspace_control` 设为 true（只有 meson/rtk 那些驱动才设），而
`usb_role_switch_is_visible()` 只在 `allow_userspace_control` 为真时才导出
`role` 属性。所以 **dwc3 的 role switch 天生就没有 role 属性**，
不能据此判断切换有没有接上。

要看切换有没有真的发生，看这两个更靠谱：
- `cat /sys/class/udc/a600000.usb/state`（`configured` = 还在设备模式）
- 插上 OTG 设备后 `ls /sys/bus/usb/devices/` 是否出现新设备

**验证方法**：拔掉连电脑的线，用 USB-C OTG 转接头接 U 盘/鼠标，看：

```sh
mi9-usb                 # 一体式状态
dmesg | tail            # 期望 "new high-speed USB device"
ls /sys/bus/usb/devices/ # 期望有设备
cat /sys/class/typec/port0/data_role
```

如果一直不切换，下一步：
- 试 `HOST-boot-cepheus.img`（`dr_mode = "host"` 写死），单独验证
  「Host 控制器 + VBUS 供电」这条链路。刷它之后 USB 网卡消失，改用 WiFi
  `192.168.31.177`（已验证可连）；要回退就长按电源 → fastboot → 刷
  `OTG-boot-cepheus.img`。
- 若 host 模式能看到 xhci 并枚举出设备，说明硬件没问题，问题只在
  tcpm→dwc3 的角色联动（graph 连接 / fwnode 匹配）。

