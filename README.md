# okra-pm-bootstrap

OkraPM 驱动整条自举链路的验证仓库（x86_64）。

## 这是什么

方案 B：**包管理器管整个系统**。

自举出来的每一个文件都由一次安装事务写进去，包管理器自己也是这些包中的一个。

链路分六步，每步都能独立验证：

1. 交叉工具链把 70 个自举包组装成一个可 chroot 的用户态
2. **系统用自己的 gcc 原生重编 binutils 和 gcc**
3. **系统用自己的 gcc 原生重编 libxcrypt 和 glibc**
4. OkraPM 用这个用户态里的 g++ 编译自己，再用自己的 opsis 打包
5. 结果变成一个 Lunar 软件源——lunar 能 sync 的那种，含之前缺失的 `app.glibc`、`app.lz4`、`app.libxcrypt`
6. 宿主机上的 lunar 把这整套用户态装进一个空目录，一次事务；然后 chroot 进去，用里面的 lunar **再装一个包**

第 6 步是方案 B 与方案 A 的分界线：包管理器不是系统建好后补装的，它本来就是仓库里的一个包，由它所属的系统编译出来，再从系统内部管理这个系统。

## 为什么之前的链路不够

上一轮打通的是 **方案 A**：

```
交叉工具链 → 70 个包 → 组装 rootfs → chroot 编内核
```

问题在于 rootfs 是脚本 `cp -a` 拼出来的：

- 70 个包各自声明 `dependencies: [app.glibc]`，但 **release 里没有 glibc 包**
- `/bin/sh`、`/etc/passwd`、`cc`、`pkg-config`、`libgcc_s.so.1` 的位置，全靠 `assemble-rootfs.sh` 手工补
- 系统里没有"这个文件是谁装的"的记录
- 包管理器从来没在这个系统里跑过
- 工具链和 C 库都是交叉编译器产的，系统离开宿主工具链就跑不起来

## 目录

```
.github/workflows/scheme-b.yml     整条链路的执行与验证
scripts/fetch-toolchain.sh         取 x86_64-okra-linux-gnu 交叉工具链
scripts/fetch-packages.sh          取 70 个自举包（带 sha256 校验）
scripts/assemble-userland.sh       工具链 sysroot + 包 → rootfs
scripts/rebuild-native.sh          chroot 内用系统自己的 gcc 重编 binutils + gcc
scripts/rebuild-libc.sh            chroot 内原生重编 libxcrypt + glibc
scripts/build-okrapm.sh            在 Okra 用户态里编译 OkraPM
scripts/make-glibc-package.sh      sysroot 合成 app.glibc 包
scripts/make-missing-packages.sh   编用户态缺的两个库：app.lz4、app.libxcrypt
scripts/make-sample-package.sh     编一个用户态里还没有的包，供 chroot 内安装测试
scripts/patch-okrapm.sh            修 OkraPM 的符号链接处理 bug
scripts/publish-repo.sh            打包成 Lunar 软件源
scripts/repo-server.py             提供软件源，生成 index.yaml
scripts/lib-oaa.sh                 从 .oaa 归档里读 meta.yaml
scripts/verify-scheme-b.sh         用 lunar 装整个系统并验证
```

## 自举到了哪一步

| 组件 | 谁编的 |
|---|---|
| binutils 2.44 | **系统自己**（chroot 内原生） |
| gcc 16.2.0 | **系统自己**（chroot 内原生） |
| libxcrypt 4.4.36 | **系统自己**（chroot 内原生） |
| glibc 2.43 | **系统自己**（chroot 内原生） |
| 73 个用户态包 | 交叉编译器 |

`rebuild-native.sh` 和 `rebuild-libc.sh` 都会打印**前后指纹**（`Configured with:` 行、`libc.so.6` 的 sha256），所以"真的换了编译器/库"是日志里的证据，不是声明。

## 几个关键设计

**app.glibc 是合成出来的，不是手写的。** 交叉工具链把 glibc 直接装进 `okra-sysroot/`，绕过了包系统。`make-glibc-package.sh` 把 70 个包的 `files:` 列表读出来，sysroot 里**没被任何包认领**的部分就是 glibc 基座。这样某个包以后多装一个文件，不会突然变成两个包都声称拥有它。程序目录（`/sbin` 等）不在跳过列表里——`/sbin/ldconfig` 正是因为被跳过才丢过一次。

**归档按 lunar 的解析规则改名。** 自举产物叫 `make-4.4.1-1.x86_64.bootstrapped.oaa`，而 lunar 去仓库找的是 `<namespace>.<name>@<version>.oaa`，也就是 `GNU.make@4.4.1.oaa`。namespace 和 version 从 `meta.yaml` 里读，不从文件名猜——两者不总是一致的。版本还要过一遍 `LunarVersion` 归一化，因为 lunar 的 `Version::parse` 用 `std::stoi`，会把 `1.07.1` 读成 `1.7.1`。

**下载校验。** 每个归档在 release 里都有配套 `.sha256`，`fetch-packages.sh` 下载后比对，不匹配就重试三次。不这么做的话，一次截断的下载要到很久以后的解压才暴露，而那时错误信息指向的是 tar 而不是网络。

**app.lz4 和 app.libxcrypt 是审计出来的，不是猜出来的。** 用户态里每个二进制都查了一遍它请求的共享库：1022 个二进制，6 个 soname 未解析，其中 4 个其实在子目录里（误报）。真正缺的是 `liblz4.so.1`（zstd 要它）和 `libcrypt.so.1`（perl/shadow/sudo 要它）。

`liblz4` 这一条是关键：**tar 通过外部 `zstd` 读 zstd 归档**，所以 zstd 一坏，仓库里每个 `.oaa` 在系统内部都解不开——而"系统内部能装包"正是方案 B 要证明的事。第一次事务之所以没发现，是因为它跑在宿主上，用的是宿主的 zstd。

## 已修的 bug

**OkraPM 的符号链接处理（`patch-okrapm.sh`）。** OkraPM 用 `fs::relative` 算 payload 条目的目标路径，而它会解析符号链接。所以任何带 `libfoo.so.6 -> libfoo.so.6.5` 这种链的包，装完后实体文件被替换成指向自己的链接，另外两个名字根本没建出来。bash 因此找不到 `libtinfo.so.6`。补丁把三处调用改成 `lexically_relative`，模式找不到就报错，避免上游修好后这个补丁悄悄留在原地。

## 已知缺口

**卸载不删文件。** lunar 的 remove 只把包从数据库移除，文件删除交给包自己的 `remove.opsis`。这批自举包的 `scripts/` 目录是空的，所以卸载是空操作、但报告成功。正确修法是让 `system.db` 记录已安装文件清单——那是改存储格式，不是改调用点，所以这里没做。

**73 个用户态包仍是交叉编译的。** 工具链和 C 库已经原生，但这 73 个包还没在系统内部重编一遍。严格自举的完成标志（在系统内 `make` 再编一遍工具链、得到同样的结果）还没做。

**没做 QEMU 启动。** 产出是 rootfs 目录，不是可引导镜像。

这些是脚本**明确补上并打印出来**的，不是藏起来的：

| 缺什么 | 为什么 | 现在怎么处理 |
|---|---|---|
| `base-files` 类包 | 没人提供 `/bin/sh`、`/etc/passwd` | `verify-scheme-b.sh` 建完并报告 |
| `cc`、`c++`、`pkg-config` 名字 | 在宿主上属于发行版，不属于任何软件包 | `assemble-userland.sh` 建符号链接 |
| `ld.so.cache` | 需要跑 `ldconfig`，它属于 glibc 包 | 两棵树都写 `ld.so.conf` 并跑 `ldconfig` |

要真正干净，前两项应该各自成为包（`app.base-files`、`app.toolchain-aliases`），让仓库里没有"脚本放进去的文件"。

## 种子

仍然是 Ubuntu 自带的 gcc——它编出了交叉工具链，这一步任何方案都绕不开。之后所有东西都来自交叉工具链。

## 运行

```bash
gh workflow run scheme-b.yml -f okrapm_ref=main
```

约 55 分钟：交叉工具链取包几分钟，两轮原生重编（binutils+gcc，然后 libxcrypt+glibc）各占大头。

产物发到 `okra-repo` release：`index.yaml` + `Okra.okrapm@*.oaa` + `Okra.hello@*.oaa` + `app.lz4@*.oaa` + `app.libxcrypt@*.oaa`。

## 依赖

- 交叉工具链：`ylh440104/okra-oaa-packages-x86_64` 的 `okra-cross-toolchain` artifact
- 70 个自举包：同仓库 `okra-userland` release
- OkraPM 源码：`OkraLinux/okrapm`
- OAA 格式与 lunar 的仓库协议：`OkraLinux/okrapm`（`oaatools/`、`repo-server/`）
