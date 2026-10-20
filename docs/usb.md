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

当前 `usb_role_switch` 类设备存在（`/sys/class/usb_role/a600000.usb-role-switch`），
但目录里没有 `role` 属性，说明 tcpm 还没真正接管切换。

**验证方法**：把电脑那根线拔掉，用 USB-C OTG 转接头接一个 U 盘/鼠标，然后看：

```sh
dmesg | tail            # 期望出现 "new high-speed USB device"
lsusb                   # 期望列出外设
cat /sys/class/typec/port0/power_role   # 期望变成 source
```

如果一直不切换，下一步查：
- `fwnode_usb_role_switch_get()` 没能把 connector 的 port 关联到 dwc3 的
  role switch（dwc3 注册时用的是 `usb@a600000` 节点，而 graph 连的是它下面的
  `usb_1_dwc3_hs` endpoint）—— 可能要显式加 `usb-role-switch` 连接属性，
  或改成用 `role-switch-default-mode = "host"` 强制。
- 也可以先用 `dr_mode = "host"` 单独验证 Host 控制器 + VBUS 是否真的能工作
  （注意：那样 USB 网卡会消失，改用 WiFi `192.168.31.177` 连）。
