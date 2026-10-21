# USB / OTG / Type-C（cepheus）

## 现状（2026-10-21）

| 项目 | 状态 |
|---|---|
| USB 设备模式（gadget / USB 网卡） | ✅ 正常（一直是靠它连手机） |
| USB 控制器双角色（dwc3 `dr_mode = "otg"`） | ✅ 已启用 |
| PM8150B Type-C 控制器（tcpm） | ✅ probe 成功，`/sys/class/typec/port0` 出现 |
| Type-C 角色识别 | ✅ `port_type = [dual] source sink`、`preferred_role = sink` |
| dwc3 角色切换（role switch） | ✅ 自动切换（插 OTG 设备 → host；插电脑 → device） |
| USB Host 实际枚举外设 | ✅ 实测：USB-C 扩展坞 + 游戏键盘，HID 键鼠可用 |
| OTG 对外 5V（`usb_vbus`） | ✅ `enabled` |
| U 盘 / 外接存储 | ⬜ `USB_STORAGE=y` 已内建，未实测挂载 |

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

## ✅ Host 模式已打通（2026-10-21 14:13）

**实测结果**（插 USB-C OTG 扩展坞 + SEMICO 游戏键盘）：

```
role = host                              ← dwc3 切到 Host
udc: （没有）                             ← 不在设备模式
typec data_role: [host] device
usb_vbus: enabled                        ← 对外 5V 正常
USB 设备: 1-1 (USB2.0 HUB) / 1-1.4 (USB Gaming Keyboard)
input: SEMICO USB Gaming Keyboard → 4 个输入节点（kbd + consumer + system）
```

拔掉键盘插回电脑线，`role` 会自动变回 `device`（USB 网卡随之恢复）。

### 为什么之前不切：一是时序，二是内核少了一个开关

1. **`tcpm_register_port()` 首次是 -517**：`pm8150b_vbus` 比 typec 晚注册，
   重试第二次才成功。日志里此时 `MI9DBG role_sw = none (-517)`，
   第二次变成 `MI9DBG role_sw = found (0)` —— **tcpm 确实通过 DT graph
   找到了 dwc3 的 role switch**，这条链路本身是通的。

2. **但 dwc3 的 role switch 默认不接受用户态控制**：
   `usb_role_switch_is_visible()` 只在 `allow_userspace_control` 为真时才导出
   `role` 属性，而 dwc3 的 `dwc3_role_switch` 描述符里没设这一项
   （只有 meson / rtl 那些驱动设了）。本地给 `drivers/usb/dwc3/drd.c`
   加了一行 `dwc3_role_switch.allow_userspace_control = true;`，
   `role` 就可读写了。

### 落地实现（三处）

1. `drivers/usb/dwc3/drd.c`：`allow_userspace_control = true`（本地补丁）
2. `payload/usr/local/sbin/mi9-usb-role.sh` + `mi9-usb-role.service`：
   一个轻量桥接服务，轮询 `/sys/class/typec/port0/data_role`，
   和 `/sys/class/usb_role/a600000.usb-role-switch/role` 不一致就写一次。
   即使将来 tcpm 那条自动链路在某些时序下没接上，这个服务也能兜底。
3. `mi9-usb` 工具：`mi9-usb` 看状态、`mi9-usb host|device` 手动切。

### 仍然待办

- **U 盘**：`CONFIG_USB_STORAGE=y` 已内建，理论上插上就会出 `/dev/sdb`，
  但还没实测；外接存储挂载（automount）也没做。
- **USB 网卡 + OTG 同时用**：Type-C 口只有一个，两者互斥，靠自动切换。
- 键盘已经能直接打字（`event5`，`kbd` handler），控制台可用。


