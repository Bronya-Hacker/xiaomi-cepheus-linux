# 踩坑清单（cepheus 主线移植）

按"再踩一次会浪费多少时间"排序。每条都有现象 → 根因 → 正确做法。

---

## 一、会让手机变砖/起不来的

### 1. NFC 的 IRQ 绝不能用电平触发
- 现象：改成 `IRQ_TYPE_LEVEL_HIGH` 后开机，**SSH（USB + 局域网）全部连不上**，整机卡死。
- 根因：这颗 NXP NQ 芯片数据没被读走时会**一直把 IRQ 拉高**，电平触发 → 中断风暴，CPU 被占死。
- 正确做法：**保持边沿触发**（主线驱动本来就硬编码 `IRQF_TRIGGER_RISING`）。
- 恢复：长按电源强制关机 → 音量下+电源进 fastboot → 刷回镜像。

### 2. QUP 的 I2C 总线不能一次全开
- 现象：把 i2c0/2/3/… 十来条全部 `status = "okay"`，开机黑屏、SSH 不通。
- 根因：有些 QUP SE 的引脚**和其它外设复用**（相机、显示、USB 等），全开会把那些外设的引脚抢走。
- 正确做法：**一次只开一条**，确认引脚没被别的 dtsi 占用（查原厂 DT 里该引脚的 function）再开。

---

## 二、"改了却没生效"类（最浪费时间的）

### 3. 改内核模块必须走 payload
- 现象：`cp *.ko /lib/modules/...` + `depmod` + `modprobe` 看着生效，**重启就回原样**。
- 根因：开机时 initramfs 解 `mods.tar.gz`（payload）到 `/lib/modules`，把手动放的覆盖掉。
- 正确做法：重跑 **02（重打 mods.tar.gz）→ 06（kernelfat）→ 刷 kernelfat**。
- 配套：payload 版本号已改成**内容指纹**（改了模块版本号必变，刷了才会重新解压）。

### 4. 板级 DTS 的改动必须改仓库 `dts/` 下那份
- 现象：改了仓库 `dts/sm8150-xiaomi-cepheus.dts`，编出来的 DTB 却是旧的。
- 根因：`apply-dts5.sh` 以前**只同步 dtsi，不同步板级 DTS 本体**。
- 正确做法：改 `dts/` 下那份，由 `apply-dts5.sh` 同步进内核树（脚本已改进）。今天就是因为这个，
  `gpio-reserved-ranges` 的修复没进 DTB，多刷了两次机。

### 4b. ★ 不要把仓库的板级 DTS 覆盖到内核树
- 现象：我"顺手"让 `apply-dts5.sh` 把仓库 `dts/sm8150-xiaomi-cepheus.dts` 同步进内核树，
  结果编出来的 DTB **校验大面积失败**：`ufshc 不是 okay`、`charger@1000 不是 okay`、
  触摸/蓝牙节点全丢 —— 刷进去就是砖。
- 根因：**仓库那份是干净的主线板级 DTS，没有 UFS / 充电 / 触摸 / 蓝牙补丁**；
  内核树那份才是 `apply-dts.sh`…`apply-dts4.sh` 打过补丁的完整版。一覆盖全没了。
- 正确做法：`apply-dts5.sh` 现在**只同步 dtsi**，板级 DTS 不一致时只警告不覆盖。
  **要改板级 DTS 就直接改内核树那份**（改完可以复制回 `dts/` 留档）。
- 教训：想"修一个不同步的小毛病"之前，先搞清楚两份文件的真实关系，别想当然。

### 5. 改设备上的脚本（/usr/sbin/mi9-doctor 等）也会被 payload 覆盖
- 同第 3 条：要改就改 `payload/` 下那份，下次刷 payload 才持久。

---

## 三、外设调试类

### 6. 先挂载原厂 vendor 分区再猜硬件
- `/dev/sde53`（vendor）、`/dev/sde54`（system）**还在**，只读挂载即可：
  `mount -o ro /dev/sde53 /mnt/vendor`
- 今天靠它一次性搞清楚了三件事：
  - 扬声器功放是 **CS35L41**（不是折腾半天的 WSA881x）——主线有驱动；
  - NFC 芯片是 **NXP SN100U**（不是 PN5xx，主线 `nxp-nci` 不支持）；
  - 传感器挂在 **SLPI**（`qcom,slpi_qrtr`），AP 侧根本访问不到。
- 结论：**遇到认不出来的外设，先去 vendor 分区翻，别猜。**

### 7. 驱动里"复位极性"要按驱动的语义，不是按原厂 DT
- 现象：CS35L41 报 `Failed waiting for OTP_BOOT_DONE (-ENXIO)`。
- 根因：主线驱动的复位是**高有效**（先拉低 2ms 再拉高释放）；我们照原厂语义写成
  `GPIO_ACTIVE_LOW`，逻辑 1 变成物理低 → **一直按着复位**。
- 正确做法：改成 `GPIO_ACTIVE_HIGH` 后立刻 probe 成功（`35a40`, Rev B0）。

### 8. 检查"引脚能不能申请"要用 gpioget 反查
- 现象：pinctrl 状态一应用就 `-EINVAL: pin-126`。
- 根因：我们自己的 DTS 里 `gpio-reserved-ranges = <0 4>, <126 4>` 把 126-129 保留掉了
  （照抄主线 sm8150 板子——**那些板子不用 secondary MI2S，但小米 9 的功放就用它**）。
- 排查手法：`gpioget gpiochip3 <n>` —— 能读=可用，`Invalid argument`=被保留/不可用。
- 正确做法：去掉 `<126 4>`。

---

## 四、构建/发布类

### 9. `=m` 改成 `=y` 后要删掉旧的 .ko
- 现象：`modprobe` 报 `Exec format error`，但 `insmod` 正常。
- 根因：`make modules` **不会删除**配置由 `=m` 改成 `=y` 后遗留的旧 `.ko`，它跟着 payload 进了系统，
  和内建代码冲突。
- 正确做法：改完配置顺手删掉对应的旧 `.ko`（今天 `rc-core.ko` 就是这么中招的）。

### 10. 改 DTB 要刷 boot，改模块/内核要刷 kernelfat
- DTB 在 edk2 的 boot 镜像里（FdtBlob）→ **刷 boot**。
- 模块/Image/payload 在 kernelfat → **刷 kernelfat**（`fastboot flash recovery`）。
- 两个都改了就都要刷。
- ★ 千万别 `fastboot erase dtbo/vbmeta`。

---

## ⚠️ 扫 `CDC_IF_ROUTER_TX_MUX_CFG0`(0x0d3a) 会让整机卡死（2026-10-22 05:35）

给 TX0 端口扫描 `0x0d3a` 的取值（0/1/2/3/4/5/6/7/8/15）时，
`arecord` 进程进入 **D 状态（不可中断）**，`kill -9` 无效，
连 `systemctl reboot` 都推不动 —— 只能长按电源 10 秒强制重启。

### 建议

- **不要**再盲扫这个寄存器。已知安全值只有 `0x01`（RX_MIX_TX0）和 `0x02`（DEC0）。
- 扫 codec 寄存器一律遵守：
  1. 一次只改一个寄存器
  2. 每次捕获都加 `timeout`（我们用的是 `timeout -k 3 8`）
  3. 发现 `arecord` 卡住就**立刻停止**，别继续往下试
  4. 出现 D 状态进程时直接断电重启，别指望 kill

### 同类风险

之前 SLIMbus 那次卡死（`INIT_LIST_HEAD` 破坏链表）也是 D 状态不可中断。
凡是"改完寄存器后音频通路直接没有数据"的情况，都可能把内核拖死在
驱动里的等待上。
