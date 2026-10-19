# WIP: camss SM8150 (M2)

**状态：代码能编译、DTB 能编过，但还没在真机上探针过。**

## 做了什么

- `0001-camss-sm8150-resources.patch`：`sm8150_resources` 资源表
  - 复用 SDM845 的 ops（CSID175/VFE175 同一代：`csid_ops_gen2` + `csiphy_ops_3ph_1_0`）
  - 4×CSIPHY / 2×CSID / 2×VFE，地址与中断来自设备上的下游 DT：
    csiphy `ac65000/ac66000/ac67000/ac68000`（IRQ 477/478/479/448）、
    csid `acb3000/acba000`（IRQ 464/466）、vfe `acaf000/acb6000`（IRQ 465/467）
  - 时钟名按 SM8150 camcc 改过（注意：**没有** `ife_*_areg` / `ife_*_ahb`，845 有、8150 没有）
- DT 节点（当前 `status = "disabled"`）：`camss@acb3000`，clocks 全部映射到 `CAM_CC_*`。
  构建时它会编进 `sm8150.dtsi`；因为共享给 sa8155p-adp，节点里**不能**引用板级 regulator（如 `vreg_l1a_0p75`）—— 已经踩过一次。

## 为什么还没测

DTB 是打包进 **edk2 的 boot.img** 的，`07-rebuild-all-wsl.sh` 不会重新打 boot 镜像。
要测必须先重建 edk2 boot 镜像 + `fastboot flash boot`，这是又一次有风险的写入，
今晚已经刷了太多次，先停下跟你确认。

## 测的时候做什么

1. 重建 boot 镜像（edk2 里把 `sm8150-xiaomi-cepheus.dtb` 换新的），`fastboot flash boot`；
2. DT 里把 camss 改成 `status = "okay"`；
3. 开机后 `insmod qcom-camss.ko`（或 `modprobe qcom-camss`）；
4. 看 `dmesg` 有没有 probe 成功、`media-ctl -p` 里有没有 CSIPHY→CSID→VFE 的实体图；
5. 再往后才是传感器驱动（IMX586 等，主线都没有）。
