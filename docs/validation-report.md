# 验证报告：NookVM Linux 6.12.114 客体构建

- 日期：2026-10-27（UTC 时间见各日志）
- 任务：Orca task `task_b271de5cda5b` / dispatch `ctx_22b404e9765d`
- 仓库：`/Users/lfld/code/rust/nookvm/linux_build`（尚无提交；`.gitmodules` 与 `vendor/linux` gitlink 已暂存，未创建 commit）

## 结论

`make clean`、`make build`、`make verify` 均以退出码 0 完成，产物在 `out/`。两次独立构建（增量构建与 clean 后的全新构建）产物逐字节一致。**没有**在 NookVM 自研 VMM（或任何 VMM/模拟器）中引导该内核；串口控制台、virtio-mmio block/net、DHCP 和 BusyBox init 作为真实 PID 1 的行为都**没有**经过运行验证。

## 环境

| 项目 | 值 |
| --- | --- |
| 宿主 | macOS（Darwin 27.0.0），`uname -m` = arm64，18 核 |
| Docker | OrbStack 2.2.5（启动前 `orb status` 为 Stopped，执行 `orb start` 后为 Running），context `orbstack`，引擎 29.8.2，`docker info` Architecture = `aarch64`，OSType = `linux` |
| 原生性 | 所有容器 `--platform linux/arm64`，容器内 `uname -m` = `aarch64`（build.log、verify.log 首段），没有使用 QEMU/binfmt 模拟 |
| 构建镜像 | `debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad`，apt 源为 snapshot `20261020T213255Z`；本地镜像 ID `sha256:387e1d50a2732e2d739ff911d66a5bb08476836542583ced3c8f00b6c2479b76` |
| 工具链 | GCC 14.2.0 (Debian 14.2.0-19)、binutils 2.44、make 4.4.1、bison 3.8.2、flex 2.6.4、cpio 2.15、gzip 1.13、git 2.47.3、GnuPG 2.4.7、Python 3.13.5（`out/toolchain.txt` 含全部 dpkg 包版本） |

## 输入来源核验

| 输入 | 核验 |
| --- | --- |
| Linux | 两个官方地址（git.kernel.org stable 与 GitHub gregkh/linux）上的 `git ls-remote` 都给出 `refs/tags/v6.12.114` = tag 对象 `94632db1ce2426a1018af806db3bd3d6f1d04e46`，peeled = commit `85d82e0d7c2dfd3e75d34f35b7ebbf41f45c9c4e`。从 kernel.org 浅取（depth 1）该 tag，`git submodule add` 后暂存的 gitlink 为同一 commit。每次构建在容器内检查 gitlink = HEAD = tag^{commit} = `versions.env`，并用 `git verify-tag` 验证签名：`GOODSIG 38DBBDC86092693E Greg Kroah-Hartman (Linux kernel stable release signing key)`、`VALIDSIG 647F28654894E3BD457199BE38DBBDC86092693E` |
| Alpine | `alpine-minirootfs-3.23.7-aarch64.tar.gz`，官方 `.sha256` 与 `latest-releases.yaml` 均给出 SHA256 `7dcc7420bcc426a615c0512cc85b4a52e9f89df9c600b93ce78d22e0e9234891`；构建时 `sha256sum -c` 与 `sha512sum -c` 均为 OK |

## 命令与退出码

以下为根目录 Makefile 时期的历史记录（Makefile 已移除，`make clean/build/verify` 不再是当前接口，当前入口见文末“根目录脚本验证”）。最终一轮（汇总见 `out/logs/commands.log` 中 06:38:56–06:39:19 的行；`out/logs/*.log` 单步日志已被之后的运行覆盖）：

| 时间 (UTC) | 命令 | 退出码 | 日志 |
| --- | --- | --- | --- |
| — | `make clean` | 0 | `out/logs/history/make-clean.txt`（之后 `out/`、`build/` 与卷均不存在，`vendor/linux` 无改动） |
| 06:38:56 | `make build` → `scripts/preflight.sh` | 0 | `out/logs/preflight.log` |
| 06:38:56 | `docker build --platform linux/arm64 …` | 0 | `out/logs/builder.log` |
| 06:38:56 | `docker run … /repo/scripts/build.sh` | 0 | `out/logs/build.log`（全量编译 868 个 CC 目标，`make build` 总耗时 22.8 s） |
| 06:39:19 | `make verify` → `docker run --network none … /repo/scripts/verify.sh` | 0 | `out/logs/verify.log`（`VERIFY PASSED`，79 条 `ok:`） |

此前各轮（保留在 `out/logs/history/`，均已修复）：

| 文件 | 结果 | 原因与处理 |
| --- | --- | --- |
| `make-build-1.txt` | `make build` 失败，exit 2 | 构建运行期间修改了 `build.sh`，bash 按旧偏移继续读取，报语法错误。已停止该次构建并重跑；该次已通过 gitlink、tag、GPG 与配置片段检查 |
| `make-build-2.txt` | exit 0 | 增量构建，其 SHA256SUMS 保存为 `SHA256SUMS.incremental` |
| `make-verify-1.txt`、`make-verify-2.txt` | exit 2 | 6.12 Image 的 `code0` 是 NOP、`code1` 才是 `b primary_entry`，检查改为按此判断；vmlinux 是 PIE（`RELOCATABLE`），`file` 匹配同时接受 pie |
| `make-verify-3.txt` | exit 2 | 页大小符号是 `CONFIG_PAGE_SHIFT=12`，不是 `ARM64_PAGE_SHIFT` |
| `make-verify-4.txt` | exit 2 | `mknod` 链接位于 `/bin` |
| `make-verify-5.txt` | exit 0 | 发现 `cmd && echo ok` 在 `set -e` 下失败时不会退出（apk 列表 diff 曾静默不一致，原因是 run() 的回显混入了 stdout），以及 `apk info` 会尝试联网。已改为失败即退出、回显走 stderr、`apk --repositories-file /dev/null`。最终一轮使用修正后的脚本 |
| `init-source-guard-test.txt` | 符合预期 | 大小写孪生文件处理：全新冲突检出 → exit 0 并恢复干净；编辑过的孪生文件 → exit 1 且保留修改；有暂存修改 → exit 1 |

## 产物哈希（`out/SHA256SUMS`）

```
ce5b0d9a4d71e13896df76f3ac1f5041b40cb88950adf4ebd5543fda315f7123  Image
ff41d2cdb2b28689181a9362a74094c19c3305461c69b20fbec87247535033bb  initramfs.cpio.gz
9cc29a217169355967147a4885a3a4c9640fdd6235f7033cc1e84e1bfb8eaef3  kernel.config
8e9a314e3057ff881df7a61a25fa1c2a09a82bab22eb0fa43ead7db27ce76b64  vmlinux
0a67406413de08fa68237713daab1c6179efdc45de6d61ce282b4b38b7e41e5b  System.map
0fc5036948dbac0dc582cf59c55885c918e0f80a8b5fc0c5ca7b16d9bfc30f26  VERSION
a14739896a84a453a26a6aa0b3b76da4853a21ec35c8c9abedc5c053ff4320ce  toolchain.txt
46fa18b04f3e3824d14e52e5448bf03b5c60cdbd36479d134960d8fbe76ab7c4  rootfs-packages.txt
0345b53dcfb127bd8db1c524bb41ea505b4d2b3cfe0f182d6e50ec24ffbf7254  initramfs.manifest
```

可复现性：`diff out/logs/history/SHA256SUMS.incremental out/SHA256SUMS` 无差异。

大小：Image 7,284,744 B（头部 `image_size` 0x780000）；initramfs.cpio.gz 4,027,946 B（解压后 8,727,040 B，520 个条目）；vmlinux 8,517,136 B；kernel.config 51,616 B。

## 检查项（摘自 `out/logs/verify.log`）

- **Image 头**：`code0=0xd503201f`（NOP）、`code1=0x14154c0d`（B）、`text_offset=0`、`image_size=0x780000` ≥ 文件大小、`flags=0xa`（LE、4 KiB 页、可任意放置）、魔数 `0x644d5241`、PE 偏移 0（无 EFI stub）；`file`：`Linux kernel ARM64 boot executable Image, little-endian, 4K pages`；版本串 `Linux version 6.12.114-nookvm (nookvm@nookvm-builder) (gcc (Debian 14.2.0-19) 14.2.0, GNU ld (GNU Binutils for Debian) 2.44) #1 SMP 2026-10-21 08:31:09 UTC`。
- **vmlinux / System.map**：`ELF 64-bit LSB pie executable, ARM aarch64`；`_text _stext primary_entry start_kernel _end` 均在 System.map 中；`_text=ffff800080000000` 与 `nm vmlinux` 一致。
- **配置**：`config/required.txt` 全部命中（ARM64、4K 页、SMP、OF、PSCI、GICv3、arch timer、8250/console/OF platform/earlycon、virtio-mmio/blk/net、initrd+gzip、devtmpfs、proc、sysfs、tmpfs、shmem、TTY、UNIX98 PTY、NET/UNIX/PACKET/INET/IPv6、ELF/script binfmt、MULTIUSER、FUTEX、EPOLL、`# CONFIG_MODULES is not set`）；不存在 `=m`；Image 内嵌 IKCONFIG 与 `kernel.config` 逐字节相同。构建时另外检查了 `config/nookvm.config` 的每一行都保留在最终配置中。
- **initramfs 结构**：`gzip -t` 通过；520 个条目全部为 newc `070701`，以 `TRAILER!!!` 结束，之后只有零填充；无重复路径、无绝对路径或 `..`；与 `initramfs.manifest` 逐条一致；mtime 全部为 `1792571469`。
- **文件与权限**：`/init` 为 0755 root:root 的普通文件，以 `#!/bin/sh` 开头并 `exec /sbin/init`；`/bin/sh`、`/sbin/init` → `/bin/busybox`；busybox、apk、`/lib/ld-musl-aarch64.so.1`、rc.sysinit、net-up、udhcpc default.script 均为 0755；`/dev/console` c 5:1 0600，`/dev/null` c 1:3 0666；`/tmp` 1777，`/root` 0700，`/etc/shadow` 0640 root:42；保留 apk repositories（v3.23）、CA bundle、apk 数据库；inittab 含 `ttyS0::respawn:`，没有 OpenRC、sshd、dropbear。
- **执行（原生 arm64 容器，chroot 到解包后的 rootfs）**：busybox 与 apk 的解释器为 `/lib/ld-musl-aarch64.so.1`；NEEDED 库 `libc.musl-aarch64.so.1`、`libapk.so.3.0.0`、`libz.so.1` 都在 rootfs 中；`BusyBox v1.37.0` 运行正常，304 个 applet，包含 sh/init/mount/mknod/mkdir/ip/udhcpc/getty/hostname/reboot/poweroff；`apk-tools 3.0.8-r0` 运行正常，已安装 16 个包（与 `rootfs-packages.txt` 一致）；`sh -n` 检查 `/init`、`rc.sysinit`、`net-up`、`default.script` 通过；没有 eth0 时运行 `net-up`，0 秒内 exit 0，日志为 `nookvm-net: no eth0, DHCP skipped`。

## 明确未验证

- 未在 NookVM VMM 中装载或引导 Image/initramfs。该 VMM 尚无 DTB 生成和内核装载实现，本任务也不包括 VMM 运行。
- 未验证串口控制台输入输出、ttyS0 控制终端/作业控制的实际行为、virtio-mmio block/net 驱动探测、DHCP 获取地址与超时路径、BusyBox init 作为真实 PID 1 时的回收和 respawn。
- 只在 chroot 中验证了"没有网卡时 net-up 立即退出"；DHCP 超时不阻塞 shell 的结论来自脚本结构（后台、脱离控制台、`-t/-T` 有界）推理，未实际运行。
- 未使用 QEMU，未推送，未发布。

## 根目录脚本验证（移除 Makefile 后）

根目录 `Makefile` 已删除，改为可执行脚本 `source.sh`、`build.sh`、`verify.sh`、`clean.sh`；宿主不再调用 `make`（Kbuild 的 `make` 仍只在容器内运行）。`docker build/run` 的参数、挂载与环境变量与原 Makefile 逐字相同（对比 `out/logs/commands.log` 中 06:45 与 06:48 的行）。

| 时间 (UTC) | 命令（cwd 为仓库外的临时目录，按绝对路径调用） | 退出码 | 日志 |
| --- | --- | --- | --- |
| 06:48 | `bash -n` 四个入口脚本 | 0 | — |
| 06:48:39 | `source.sh`（已填充，幂等：`vendor/linux at 85d82e0d…`） | 0 | `out/logs/history/script-run.txt` |
| 06:48:39 | `build.sh` → preflight、`docker build`、`docker run … scripts/build.sh` | 0 | `out/logs/{preflight,builder,build}.log` |
| 06:48:42 | `verify.sh` → preflight、`docker run --network none … scripts/verify.sh` | 0 | `out/logs/verify.log`（`VERIFY PASSED`，79 条 `ok:`） |

运行前后 `out/SHA256SUMS` 完全相同（Image `ce5b0d9a…`、initramfs.cpio.gz `ff41d2cd…` 未变）。`clean.sh` 未在真实产物上运行；在仓库外含空格路径的夹具中用记录参数的 `docker` 替身验证：无参数时删除 `out/`、`build/` 并执行 `docker volume rm -f nookvm-linux-build-work`，`--image` 另外执行 `docker image rm nookvm-linux-builder:debian13-20261020T213255Z`，未知参数 exit 2 且不删除任何文件，`vendor/` 与其他文件保留。
