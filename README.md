# NookVM Linux 客体内核与 initramfs 构建

本仓库在**原生 linux/arm64 Docker 容器**（macOS 上的 OrbStack，无架构模拟）中，可复现地构建 NookVM 使用的 ARM64 客体：

| 产物（`out/`） | 说明 |
| --- | --- |
| `Image` | 未压缩 ARM64 内核 Image（arm64 boot 协议头，4 KiB 页，小端） |
| `initramfs.cpio.gz` | gzip 压缩的 newc cpio，Alpine 3.23.7 minirootfs + NookVM `/init` |
| `kernel.config` | 最终内核 `.config`（与 Image 内嵌的 `/proc/config.gz` 一致） |
| `vmlinux`、`System.map` | 带符号 ELF 与符号表，用于调试/符号化 |
| `VERSION` | 内核版本、源码 commit/tag、Alpine 版本与哈希、构建镜像、时间戳等 |
| `toolchain.txt` | 编译器/工具版本及构建容器内全部 Debian 包版本 |
| `rootfs-packages.txt` | rootfs 内 apk 已安装包及版本 |
| `initramfs.manifest` | initramfs 每个条目的类型、权限、属主、大小、sha256/链接目标/设备号 |
| `SHA256SUMS` | 以上文件的 SHA256 |
| `logs/` | 每个构建/校验步骤的命令、完整输出与退出码（`logs/commands.log` 为汇总） |

## 固定输入

全部固定在 [`versions.env`](versions.env)（根目录脚本与容器脚本共用的唯一来源）：

| 输入 | 固定方式 |
| --- | --- |
| Linux 源码 | `vendor/linux` git 子模块，gitlink = `85d82e0d7c2dfd3e75d34f35b7ebbf41f45c9c4e`，即 kernel.org 官方 stable 仓库 `v6.12.114` tag（tag 对象 `94632db1…`）。构建时校验 gitlink、HEAD、tag 三者一致，并用 [`keys/`](keys) 中 Greg Kroah-Hartman 的 stable 签名公钥（指纹 `647F28654894E3BD457199BE38DBBDC86092693E`）验证 tag 的 GPG 签名 |
| Alpine rootfs | 官方 `alpine-minirootfs-3.23.7-aarch64.tar.gz`，校验官方发布的 SHA256 与 SHA512 |
| 构建镜像 | `debian:trixie-slim@sha256:62bd423a…`（OCI index digest，使用其中 linux/arm64 镜像） |
| Debian 包 | apt 源固定到 `snapshot.debian.org` 时间点 `20261020T213255Z`（即该基础镜像的快照时间），包集合不随上游更新漂移；实际版本记录在 `out/toolchain.txt` |

当前工具链：GCC 14.2.0（Debian 14.2.0-19）、GNU binutils 2.44、GNU Make 4.4.1、GNU cpio 2.15、gzip 1.13（完整列表见 `out/toolchain.txt`）。

## 前置条件

- Apple Silicon（arm64）macOS，已安装 OrbStack。
- `scripts/preflight.sh`（`./build.sh`、`./verify.sh` 自动执行）会在 Docker 引擎不可达时执行 `orb start`，并要求 `docker info` 报告 `linux/aarch64`。容器内再次检查 `uname -m` 为 `aarch64`。所有 `docker build/run` 都显式指定 `--platform linux/arm64`，不使用 QEMU/binfmt 模拟。如果引擎无法启动或架构不符，preflight 以 `BLOCKER:` 开头输出具体原因并失败，不会改用其他构建路线。

## 使用

```sh
git clone <本仓库> linux_build && cd linux_build
./source.sh          # 浅克隆 vendor/linux 到固定 gitlink，并取回签名 tag（可重复执行）
./build.sh           # preflight → 构建镜像 → 容器内构建全部产物到 out/
./verify.sh          # preflight → 离线（--network none）容器内校验 out/
./clean.sh           # 只删除生成物：out/（含 out/logs/）、build/、Docker 卷 nookvm-linux-build-work
./clean.sh --image   # 另外删除当前构建镜像标签 nookvm-linux-builder:debian13-<DEBIAN_SNAPSHOT>（只删 versions.env 对应的这一个标签，不按通配符删除其他镜像）
```

四个脚本都会先切换到自身所在的仓库根目录，因此可以从任意当前目录调用（如 `/path/to/linux_build/build.sh`）。宿主上不需要也不调用 `make`；Linux 内核自身的 Kbuild 必须用 `make` 驱动，这只发生在构建容器内部（`scripts/build.sh`，GNU Make 由构建镜像提供）。

构建在本机（18 核）约 25 秒完成（不含首次构建镜像时的 apt 下载）。

## 目录与"源码 / 生成物"分离

```
versions.env            固定版本与哈希
source.sh build.sh      宿主入口：取源码 / 构建 / 校验 / 清理（不依赖宿主 make）
verify.sh clean.sh
docker/Dockerfile       构建镜像（digest + snapshot 固定）
config/nookvm.config    内核配置片段（allnoconfig 之上）
config/required.txt     verify 要求的配置项（验收清单）
rootfs/                 initramfs 覆盖文件：/init、/etc/inittab、/etc/nookvm/*
scripts/                build.sh / verify.sh（容器内）、preflight.sh / init-source.sh /
                        logged.sh（宿主）、artifact_check.py（Image/cpio 结构检查）
keys/                   内核 stable tag 签名公钥
vendor/linux            Linux 源码子模块（只读使用，构建从不写入）
out/  build/            生成物与下载缓存（.gitignore，./clean.sh 删除）
```

- 容器内仓库以**只读**方式挂载到 `/repo`，只有 `out/`、`build/` 可写。
- macOS 默认文件系统大小写不敏感，而 Linux 源码中有 13 对仅大小写不同的路径（如 `net/netfilter/xt_DSCP.c` 与 `xt_dscp.c`），在 macOS 上检出必然有一方内容错误。因此：
  - 构建**不读取**宿主上的工作树，而是在容器内用 `git archive <固定 commit>` 从子模块对象库导出源码到大小写敏感的 Docker 卷 `nookvm-linux-build-work`（`/work/src/linux`），内核以 `O=/work/kbuild` 树外构建。
  - `./source.sh` 检测到大小写不敏感时，用 sparse-checkout 把这 26 个"孪生"路径排除出宿主工作树，使 `git status` 干净且不含错误内容。
  - 修改保护只在**需要转换**时执行，即 sparse 排除尚未生效时（如全新检出或 sparse 被关闭）。此时若子模块有已暂存修改、孪生之外的修改、或孪生文件内容不等于固定 commit 中任一大小写版本，脚本拒绝执行，不会丢弃任何修改。
  - 转换已完成后，`./source.sh` 是幂等的：不再改动工作树，也不做上述检查，因此 `vendor/linux` 中现有的本地修改会被原样保留，脚本不会因此拒绝执行。
- `./clean.sh` 只删除 `out/`、`build/` 和上述 Docker 卷，不触碰 `vendor/linux` 与任何受版本控制的文件。

## 可复现性

- `SOURCE_DATE_EPOCH` 取固定 commit 的提交时间（`1792571469`，即 2026-10-21 08:31:09 UTC），并据此设置 `KBUILD_BUILD_TIMESTAMP`；`KBUILD_BUILD_USER=nookvm`、`KBUILD_BUILD_HOST=nookvm-builder`、`KBUILD_BUILD_VERSION=1`；`LOCALVERSION=`（空）避免 setlocalversion 追加 git 后缀。内核版本串为 `6.12.114-nookvm`。
- initramfs：所有条目 mtime 归一到 `SOURCE_DATE_EPOCH`，按 `LC_ALL=C` 排序后 `cpio -H newc --reproducible` 打包，`gzip -n -9` 压缩（不记录文件名和时间）。
- 实测：一次增量构建与清理（`out/`、`build/`、Docker 卷全部删除）后的全新构建，`SHA256SUMS` 中全部文件逐字节一致（见 `docs/validation-report.md`）。

## 内核配置

容器内执行 Kbuild 的 `make allnoconfig KCONFIG_ALLCONFIG=config/nookvm.config`：从最小配置出发，只启用所需功能，全部内置（`CONFIG_MODULES` 关闭，首次启动不需要任何外部模块）。构建时检查片段中每一行都保留在最终 `.config` 中（防止依赖缺失导致选项被静默丢弃），且不存在 `=m`。

| 类别 | 选项 |
| --- | --- |
| 平台 | `ARM64`、`ARM64_4K_PAGES`（`PAGE_SHIFT=12`）、48 位 VA、`SMP`、`OF`（设备树）、`ARM_PSCI_FW`、`ARM_GIC_V3`、`ARM_ARCH_TIMER` |
| 串口 | `SERIAL_8250`、`SERIAL_8250_CONSOLE`、`SERIAL_OF_PLATFORM`（DT `ns16550a`）、`SERIAL_EARLYCON` |
| virtio | `VIRTIO_MMIO`（及 `VIRTIO_MMIO_CMDLINE_DEVICES`）、`VIRTIO_BLK`、`VIRTIO_NET` |
| initrd | `BLK_DEV_INITRD`、`RD_GZIP` |
| 文件系统 | `DEVTMPFS`(+`_MOUNT`)、`PROC_FS`、`SYSFS`、`TMPFS`、`UNIX98_PTYS`（devpts）、`EXT4_FS`（供 virtio-blk 磁盘使用） |
| 网络 | `NET`、`UNIX`、`PACKET`（udhcpc 需要）、`INET`、`IPV6` |
| 其他 | `BINFMT_ELF`、`BINFMT_SCRIPT`（`/init` 是脚本）、`IKCONFIG_PROC`、`PRINTK_TIME`、`MAGIC_SYSRQ` |

未启用 EFI stub、ACPI、PCI、KASLR（`RANDOMIZE_BASE`）：Image 只用于 VMM 直接引导。

## initramfs 设计

基于官方 Alpine minirootfs，保留 BusyBox、apk-tools、CA 证书（`/etc/ssl/certs/ca-certificates.crt`）、`/etc/apk/repositories`（v3.23 main/community）及 apk 数据库，因此联网后可直接 `apk add`。没有 OpenRC、SSH。根文件系统就是内核解包 initramfs 的 tmpfs，只在内存中，重启后修改丢失。

- cpio 内预置 `/dev/console`（c 5:1，0600）与 `/dev/null`（c 1:3，0666）：内核在执行 `/init` 前就需要打开 `/dev/console`，此时 devtmpfs 尚未挂载。
- [`/init`](rootfs/init)（PID 1）：挂载 `proc`、`sysfs`、`devtmpfs`（失败时用 mknod 补建 null/ttyS0/ptmx）、`devpts`、`/dev/shm` 与 `/run`（tmpfs），然后 `exec /sbin/init`。`exec` 后 BusyBox init 仍是 PID 1，负责回收孤儿进程和按 inittab 重启进程。
- [`/etc/inittab`](rootfs/etc/inittab)：`::sysinit:/etc/nookvm/rc.sysinit`；`ttyS0::respawn:-/bin/sh`：BusyBox init 为该条目 `setsid()` 后打开 `/dev/ttyS0`，使其成为 shell 的控制终端（支持作业控制和 Ctrl-C），shell 退出后自动重启。
- [`rc.sysinit`](rootfs/etc/nookvm/rc.sysinit)：设置主机名 `nookvm`，启用 `lo`，把网络脚本放到后台后立即返回。
- [`net-up`](rootfs/etc/nookvm/net-up)：没有 `eth0` 时记录日志后立即退出；有则 `udhcpc -i eth0 -b -t 5 -T 3 -A 20`，使用 Alpine 自带的 `/usr/share/udhcpc/default.script` 配置地址、路由和 `resolv.conf`。前台最多尝试 5 次、每次 3 秒，之后转入后台每 20 秒重试。整个脚本与控制台脱离，所以缺少网卡或 DHCP 超时都不会阻塞 shell。日志在 `/run/nookvm-net.log`。

## VMM 接入（ARM64 Linux 启动协议）

以下要求来自官方 ARM64 启动协议 [Booting AArch64 Linux](https://docs.kernel.org/arch/arm64/booting.html)（源码中的 `Documentation/arch/arm64/booting.rst`）及本构建的实际配置。**本仓库不提供 DTB，也不规定地址**：DTB 必须由 VMM 按其实际机器布局（RAM、GIC、UART、virtio-mmio 的真实地址与 INTID）生成。截至本文撰写时，`vmm` 仓库中负责布局、装载和 DTB 的 `impl/src/machine` 模块仍标注为未实现（"Not implemented yet"），因此下面只给出必须满足的约束和节点结构，`<…>` 处须由 VMM 填入真实值。

### 1. 装载 Image

- 读取 Image 头（偏移 0：`code0` `code1` `text_offset` `image_size` `flags` …，偏移 56 为魔数 `ARM\x64`）。本 Image 的 `text_offset = 0`、`image_size = 0x780000`（7.5 MiB，大于文件本身 0x6f2808，因为包含 BSS），`flags = 0xa`：小端、4 KiB 页、bit3=1（可放在任意物理地址）。
- 把 Image 复制到 RAM 中**2 MiB 对齐**的地址 `K` 上，再加 `text_offset`（即 `K`）。从 `K` 起 `image_size` 字节必须都是 RAM，且不与 DTB、initrd 重叠。VMM 应在运行时从头部读取 `image_size`，不要写死。
- 入口就是 Image 第一个字节（`K + text_offset`）。本 Image 没有 EFI/PE 头（`code0` 为 NOP，`code1` 为 `b primary_entry`），只能直接引导。
- **Image 与 initrd 必须位于同一窗口**：启动协议要求 initrd/initramfs 完整位于一个 **1 GiB 对齐、大小不超过 32 GiB** 的物理内存窗口内，且该窗口同时完整覆盖内核 Image。选择 `K` 和 initrd 地址时须同时满足这一条（见下文第 3 节）。

### 2. DTB

- 放在 RAM 中，8 字节对齐，大小不超过 2 MiB，不与内核（含 BSS）和 initrd 重叠。
- 必需节点（结构示意，非可用 DTB）：

```dts
/ {
    #address-cells = <2>; #size-cells = <2>;
    interrupt-parent = <&gic>;
    chosen {
        bootargs = "console=ttyS0,115200 rdinit=/init";
        stdout-path = "<uart 节点路径>";                 // 可配合 earlycon
        // 64 位物理地址，两种等价写法任选其一，高 32 位按实际地址填写（不要固定为 0）：
        linux,initrd-start = /bits/ 64 <INITRD_START>;          // 例：/bits/ 64 <0x48000000>
        linux,initrd-end   = /bits/ 64 <INITRD_END>;            // 结束地址（不含）
        // 或两个 32 位 cell：<INITRD_START_HI INITRD_START_LO> / <INITRD_END_HI INITRD_END_LO>
    };
    memory@<base> { device_type = "memory"; reg = <… 每个 RAM 区间 …>; };
    cpus {
        #address-cells = <1>; #size-cells = <0>;
        cpu@<n> { device_type = "cpu"; compatible = "arm,armv8";
                  reg = <vCPU 的 MPIDR 亲和值>; enable-method = "psci"; };
    };
    psci { compatible = "arm,psci-1.0", "arm,psci-0.2"; method = "hvc"; /* 或 "smc"，须与 VMM 处理的陷入一致 */ };
    gic: interrupt-controller@<GICD> {
        compatible = "arm,gic-v3"; interrupt-controller; #interrupt-cells = <3>;
        reg = <GICD 基址 大小>, <GICR 区域基址 大小>;
    };
    timer { compatible = "arm,armv8-timer";
            // 4 个 PPI：安全物理、非安全物理、虚拟、hyp；PPI 号 = 客体实际看到的计时器 INTID − 16
            // （按 VMM 为客体配置/呈现的 GIC 中断号逐项确定，不要不加核对地照搬宿主数值）
            interrupts = <GIC_PPI …>, <GIC_PPI …>, <GIC_PPI …>, <GIC_PPI …>; };
    serial@<base> { compatible = "ns16550a"; reg = <基址 大小>;
                    clock-frequency = <UART 模型的输入时钟>;  // 8250 驱动据此计算分频
                    reg-shift = <REG_SHIFT>; reg-io-width = <REG_IO_WIDTH>;
                    // 必须与 VMM UART 模型的实际寄存器步长与访问宽度一致；
                    // 例：寄存器按字节紧密排列、按 1 字节访问时为 reg-shift = <0>, reg-io-width = <1>
                    interrupts = <GIC_SPI (INTID − 32) IRQ_TYPE_LEVEL_HIGH>; };
    virtio_mmio@<base> { compatible = "virtio,mmio"; reg = <基址 0x200>;
                         interrupts = <GIC_SPI (INTID − 32) …>; };   // 每个 block/net 设备一个
};
```

- 中断号：设备树里 GIC SPI 写 `INTID − 32`，PPI 写 `INTID − 16`，这里的 INTID 都是客体实际看到的 INTID。计时器 PPI 应取 VMM 实际为客体配置的 INTID（例如由 HVF 查询得到后，确认就是客体 GIC 呈现的值），而不是笼统地套用宿主数值。串口在 DT 中必须描述为 16550（`ns16550a`），不能写成 PL011。
- 也可以用内核命令行 `virtio_mmio.device=<size>@<base>:<irq>` 声明 virtio 设备（已启用 `VIRTIO_MMIO_CMDLINE_DEVICES`），但在 GIC 系统上 `<irq>` 是 Linux 内部 IRQ 号而不是 INTID，推荐用 DT 节点。

### 3. initrd

- 把 `out/initramfs.cpio.gz` 原样（不解压）放在 RAM 中，不与内核（含 `image_size` 范围）和 DTB 重叠（建议页对齐，放在内核 `image_size` 之后）。
- initrd 必须**完整**位于一个 1 GiB 对齐、大小不超过 32 GiB 的物理窗口内，且该窗口同时完整覆盖内核 Image（[booting.html 第 3 节](https://docs.kernel.org/arch/arm64/booting.html)）。最简单的做法是把 Image 与 initrd 放在同一个 1 GiB 对齐区间内的连续 RAM 中。
- 在 `/chosen` 写入 `linux,initrd-start` / `linux,initrd-end`（结束地址不含），写成完整 64 位地址（`/bits/ 64` 或高/低两个 cell）。内核检测到 gzip，以 newc 格式解包到 tmpfs 根文件系统。

### 4. 命令行

`console=ttyS0,115200 rdinit=/init`

- `console=ttyS0,115200`：内核控制台和 `/dev/console` 指向 8250 驱动的第一个端口（由 DT `ns16550a` 节点探测得到）并设为 115200 波特。用户态 shell 由 inittab 在 `ttyS0` 上启动。
- `rdinit=/init`：解包 initramfs 后执行 `/init`（显式写出，与默认值相同）。不要写 `root=`：没有 `root=` 时根文件系统保持为内存中的 initramfs。
- 调试可加 `earlycon`（配合 `stdout-path`）或 `earlycon=uart8250,mmio,<UART 基址>`，在驱动加载前输出日志。

### 5. 入口 CPU 状态（主 vCPU）

- `X0` = DTB 物理地址，`X1 = X2 = X3 = 0`，PC = Image 入口。
- 在 EL1（或 EL2）进入；MMU 关闭，D-cache 关闭（被装载区域须已与内存一致），`PSTATE.DAIF` 全部屏蔽。
- `CNTFRQ_EL0` 已设为计时器频率，各 vCPU 的虚拟计数器偏移一致。
- GICv3：须启用系统寄存器接口（从 EL1 进入时要求 `ICC_SRE_EL2.Enable=1`、`ICC_SRE_EL2.SRE=1`，由 VMM/HVF 保证）。
- 只启动主 vCPU，其余 vCPU 保持关闭，等待内核通过 PSCI `CPU_ON` 启动（`enable-method = "psci"`）；`CPU_ON` 的入口地址和上下文参数由 VMM 按 PSCI 规范设置。

## 验证范围（`./verify.sh`）

在 `--network none` 的原生 arm64 容器中执行：SHA256SUMS 校验；`VERSION` 与 `versions.env` 一致；Image 头（魔数、`text_offset`、`image_size`、小端、4 KiB 页、入口指令）与 `Linux version 6.12.114-nookvm` 版本串；vmlinux 为 aarch64 ELF，System.map 与 vmlinux `_text` 一致；`config/required.txt` 全部命中、无 `=m`，且 Image 内嵌配置与 `kernel.config` 完全相同；initramfs gzip 完整、全部条目为 newc `070701` 并以 `TRAILER!!!` 结束、无重复/越界路径、关键文件权限/属主/设备号、`/init`、musl 动态加载器、所需 applet 链接、无 OpenRC/SSH，与 `initramfs.manifest` 逐条一致。然后解包 initramfs，用 `readelf` 检查 busybox/apk 的解释器与依赖库都在 rootfs 中，并在 chroot 中**实际运行**解包出的 BusyBox（applet 列表）和 apk（`--version`、读取已安装包数据库），对 `/init`、`rc.sysinit`、`net-up`、udhcpc 脚本做 `sh -n` 语法检查，并实际运行 `net-up` 验证没有网卡时立即退出（exit 0）。

**未验证**：尚未在 NookVM（或任何 VMM/模拟器）中引导这个内核，因此串口控制台交互、virtio-mmio block/net、DHCP 以及 BusyBox init 作为真实 PID 1 的行为均未经实际运行验证。验证记录见 [`docs/validation-report.md`](docs/validation-report.md) 与 `out/logs/`。
