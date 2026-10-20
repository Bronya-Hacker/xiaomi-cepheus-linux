# WIP: camss SM8150 (M2 已达成)

**状态（2026-10-20 13:00）：真机 probe 成功，media 拓扑完整，0 oops。**

```
/media0: msm_csiphy0..3 -> msm_csid0/1 -> msm_vfe0/1 (rdi0..2 + pix)
/dev/video0..7, /dev/v4l-subdir* 全部出现
dmesg: vfe0/vfe1 各 6 clocks ok、IRQ 183/184，无 oops
```

## 改了什么（两个文件，直接覆盖内核树对应文件）

- `camss.c`
  - `csiphy_res_8150[]` / `csid_res_8150[]` / `vfe_res_8150[]` + `sm8150_resources`
    - 复用 SDM845 的 ops：`csiphy_ops_3ph_1_0`、`csid_ops_gen2`、`vfe_ops_170`
    - 地址/中断取自设备上的下游 DT：
      csiphy `ac65000/ac66000/ac67000/ac68000`（IRQ 477/478/479/448）、
      csid `acb3000/acba000`（464/466）、vfe `acaf000/acb6000`（465/467）
    - 时钟名换成 SM8150 camcc 导出的（**没有** `ife_*_areg/ahb`）
  - `camss_dt_match` 加 `qcom,sm8150-camss`
- `camss-vfe.c`
  - 加了 3 条 `dev_info` 调试打印（stage0 / irq / clocks），可保留也可删

## 踩过的坑（都很隐蔽）

1. `struct clk_alpha_pll` / `clk_alpha_pll_postdiv` 少了 `.regs` → 段错误（M1 的坑，同样适用于 camss 里引用的时钟）
2. `struct vfe_subdev_resources` 的字段叫 **`hw_ops`** 不是 `ops`；漏了会在 `vfe->res->hw_ops->subdev_init()` 处 NULL 解引用
3. `pd_name`/`has_pd=true` 会让 VFE 再 attach 一个电源域，而 DT 上 camss 节点已经挂了 MMCX → `-EEXIST`。**SM8150 上先设 `has_pd=false`、不写 pd_name**（运行时电源管理以后再做）
4. DT 节点不能引用板级 regulator（`vreg_l1a_0p75`），否则共享的 `sa8155p-adp.dtb` 编不过

## 复现

```sh
insmod camcc-sm8150.ko          # 96 个 cam_cc 时钟
modprobe -i qcom-camss          # 探针 + 建 media 图
media-ctl -d /dev/media0 -p
```

注意：DT 里的 camss 节点必须 `status = "okay"`，且 **boot 分区**里的 DTB 要更新
（DTB 在 edk2 的 boot.img 里，不是 Image 尾巴那个）。

## 下一步（M3）

接传感器：IMX586（主摄）/ IMX481 / S5K3M5 / IMX471 主线都没有驱动。
先做一颗：需要 sensor 的 i2c 地址、电源时序、PLL/模式寄存器表（下游 `techpack/camera` 里有）。
