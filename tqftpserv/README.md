# tqftpserv（ADSP 的 TFTP 服务端）

真正的构建脚本在 `../scripts/04-build-tqftpserv.sh`。
这里放的是说明和 systemd 单元的位置索引。

## 为什么必须要有它

WCN3990 的网络固件 `wlanmdsp.mbn` 是 **ADSP 里的 WLAN 子系统**加载的，
ADSP 通过 **QRTR 上的 TFTP 协议**向 userspace 请求这个文件。
内核里没有任何 TFTP 服务端驱动 → 必须有一个用户态守护进程应答。

**交接包里从来没部署过这一步，这是 `wlan0` 不出现的直接原因之一。**

流程：

```
ADSP 启动
  └─ WLAN 子系统启动
      └─ QRTR/TFTP 请求 "qcom/sm8150/wlanmdsp.mbn"
          └─ tqftpserv 应答（文件来自 /lib/firmware/qcom/sm8150/wlanmdsp.mbn）
              └─ WLAN 子系统运行
                  └─ 广播 QMI 服务 "WLFW"
                      └─ ath10k_snoc 的 lookup 命中 → wlan0
```

## 单元文件

* 单元：`../payload/etc/systemd/system/tqftpserv.service`
* 启动顺序编排：`../payload/etc/systemd/system/wifi-up.service`
  + `../payload/usr/sbin/wifi-up.sh`
* 这些都是 `05-make-payload.sh` 打进 `wifi-cfg.tar.gz`，由 initramfs 解包到 rootfs 的 `/`

## 编译

```bash
bash ../scripts/04-build-tqftpserv.sh        # → out/tqftpserv（aarch64）
```

脚本会依次尝试：

1. 从 postmarketOS 的 aarch64 仓库直接取预编译 `tqftpserv.apk`，解出二进制（最快）；
2. 用 meson 交叉编译 `libqrtr` + `tqftpserv`（需要 arm64 的 glib-2.0 开发包）；
3. 都不行会打印手工办法。

## ⚠️ 待确认：命令行参数

`tqftpserv.service` 里写的是 `-r /lib/firmware`。
拿到二进制后**务必**先跑一次：

```sh
./out/tqftpserv --help
```

如果参数名不是 `-r`，改 `payload/etc/systemd/system/tqftpserv.service` 的 `ExecStart`
后重跑 `05-make-payload.sh`。

## 固件准备

tqftpserv 按相对路径应答，所以：

* `/lib/firmware/qcom/sm8150/wlanmdsp.mbn` ← 必须有（`05-make-payload.sh --wlanmdsp <文件>`）
* 手机原生的那一份在 `/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn`，
  如果 ADSP 请求的就是这个路径，把它也放一份到 `qcom/sm8150/` 更保险。
