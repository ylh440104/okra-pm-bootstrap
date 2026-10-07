# okra-pm-bootstrap

OkraPM 驱动整条自举链路的验证仓库（x86_64）。

## 这是什么

**包管理器管整个系统**。

自举出来的每一个文件都由一次安装事务写进去，包管理器自己也是这些包中的一个。

链路分八步，每步都能独立验证：

1. 交叉工具链把 70 个自举包组装成一个可 chroot 的用户态
2. **系统用自己的 gcc 原生重编 binutils 和 gcc**
3. **系统用自己的 gcc 原生重编 libxcrypt 和 glibc**
4. OkraPM 用这个用户态里的 g++ 编译自己，再用自己的 opsis 打包
5. 结果变成一个 Lunar 软件源——lunar 能 sync 的那种，含之前缺失的 `app.glibc`、`app.lz4`、`app.libxcrypt`
6. **用户态里剩下的包也由系统自己重编**（这一轮 66 个，0 失败），用的还是产出交叉包的那同一套配方，唯一变的是编译器（`iputils`、`systemd` 要 meson/ninja，显式跳过）
7. **原生编出来的工具链被打回成包**，替换仓库里的交叉编译版本，索引重建
8. 宿主机上的 lunar 把这整套用户态装进一个空目录，一次事务；然后 chroot 进去，用里面的 lunar **再装一个包**

包管理器不是系统建好后补装的，它本来就是仓库里的一个包，由它所属的系统编译出来，再从系统内部管理这个系统。

第 2、6 步合在一起就是文档说的完成标志：**整套用户态不再是交叉编译出来的**，而是系统自己从源码编的。重编之后仓库里每一份归档都换成了原生的那一份，所以发布时是整份仓库一起换（见「已知缺口」）。

第 7 步是那半截容易被漏掉的部分：用工具链重编自己之后，**把产物重新打包**。少了它，树里跑的是原生工具链，而数据库和仓库记的还是交叉编译的那一份。


## 目录

```
.github/workflows/scheme-b.yml     整条链路的执行与验证
scripts/fetch-toolchain.sh         取 x86_64-okra-linux-gnu 交叉工具链
scripts/fetch-packages.sh          取 70 个自举包（带 sha256 校验）
scripts/assemble-userland.sh       工具链 sysroot + 包 → rootfs
scripts/rebuild-native.sh          chroot 内用系统自己的 gcc 重编 binutils + gcc
scripts/rebuild-libc.sh            chroot 内原生重编 libxcrypt + glibc
scripts/repack-native-toolchain.sh 把原生工具链打回成包，替换仓库里的交叉版本
scripts/build-okrapm.sh            在 Okra 用户态里编译 OkraPM
scripts/make-glibc-package.sh      sysroot 合成 app.glibc 包
scripts/make-missing-packages.sh   编用户态缺的两个库：app.lz4、app.libxcrypt
scripts/make-sample-package.sh     编一个用户态里还没有的包，供 chroot 内安装测试
scripts/patch-okrapm.sh            修 OkraPM 的符号链接处理 bug
scripts/publish-repo.sh            打包成 Lunar 软件源
scripts/build-index.sh             由仓库里的归档生成 index.yaml
scripts/repo-server.py             提供软件源，生成 index.yaml
scripts/lib-oaa.sh                 从 .oaa 归档里读 meta.yaml
scripts/verify-scheme-b.sh         用 lunar 装整个系统并验证
```

## 自举到了哪一步

| 组件 | 谁编的 | 仓库里是哪一份 |
|---|---|---|
| binutils 2.44 | **系统自己**（chroot 内原生） | 原生，35 项 |
| gcc 16.2.0 | **系统自己**（chroot 内原生） | 原生，885 项 |
| libxcrypt 4.4.36 | **系统自己**（chroot 内原生） | 原生，19 项 |
| glibc 2.43 | **系统自己**（chroot 内原生） | 原生，2443 项 |
| 其余 65 个包（含包管理器） | **系统自己**（chroot 内原生） | 65 个原生 |

`rebuild-native.sh`、`rebuild-libc.sh` 会打印**前后指纹**（`Configured with:` 行、`libc.so.6` 的 sha256），`repack-native-toolchain.sh` 会把原生产物按老包的 `files:` 清单从树里逐条取出——三个包分别取出 35、885、2443 项，**没有一项是清单里有而树里没有的**。所以"工具链是系统自己编的"是日志里的证据，不是声明。

## 几个关键设计

**app.glibc 是合成出来的，不是手写的。** 交叉工具链把 glibc 直接装进 `okra-sysroot/`，绕过了包系统。`make-glibc-package.sh` 把 70 个包的 `files:` 列表读出来，sysroot 里**没被任何包认领**的部分就是 glibc 基座。这样某个包以后多装一个文件，不会突然变成两个包都声称拥有它。程序目录（`/sbin` 等）不在跳过列表里——`/sbin/ldconfig` 正是因为被跳过才丢过一次。

**归档按 lunar 的解析规则改名。** 自举产物叫 `make-4.4.1-1.x86_64.bootstrapped.oaa`，而 lunar 去仓库找的是 `<namespace>.<name>@<version>.oaa`，也就是 `GNU.make@4.4.1.oaa`。namespace 和 version 从 `meta.yaml` 里读，不从文件名猜——两者不总是一致的。版本还要过一遍 `LunarVersion` 归一化，因为 lunar 的 `Version::parse` 用 `std::stoi`，会把 `1.07.1` 读成 `1.7.1`、把 `2.44` 补成 `2.44.0`。**重打包走的是同一条规则**——否则原生的 `GNU.gcc@16.2.0.oaa` 会和交叉的 `GNU.gcc@16.2.0.oaa` 撞名、或者写成 `16.2` 让解析器去取旧包。

**下载校验，且校验文件跟着归档一起改名。** 每个归档在 release 里都有配套 `.sha256`，`fetch-packages.sh` 和 `publish-repo.sh` 都会比对，不匹配就重试。`publish-repo.sh` 改名时会连 `.sha256` 一起改，最后还有一道守卫：**仓库里任何归档缺校验文件就直接失败**。这道守卫上线时立刻抓到了两个真问题——70 个自举包的校验文件从来没被下载进仓库，以及包管理器自己的校验文件在拷贝时被漏掉。

**app.lz4 和 app.libxcrypt 是审计出来的，不是猜出来的。** 用户态里每个二进制都查了一遍它请求的共享库：1022 个二进制，6 个 soname 未解析，其中 4 个其实在子目录里（误报）。真正缺的是 `liblz4.so.1`（zstd 要它）和 `libcrypt.so.1`（perl/shadow/sudo 要它）。

`liblz4` 这一条是关键：**tar 通过外部 `zstd` 读 zstd 归档**，所以 zstd 一坏，仓库里每个 `.oaa` 在系统内部都解不开——而"系统内部能装包"正是方案 B 要证明的事。第一次事务之所以没发现，是因为它跑在宿主上，用的是宿主的 zstd。

## 已修的 bug

**OkraPM 的符号链接处理（`patch-okrapm.sh`）。** OkraPM 用 `fs::relative` 算 payload 条目的目标路径，而它会解析符号链接。所以任何带 `libfoo.so.6 -> libfoo.so.6.5` 这种链的包，装完后实体文件被替换成指向自己的链接，另外两个名字根本没建出来。bash 因此找不到 `libtinfo.so.6`。补丁把三处调用改成 `lexically_relative`，模式找不到就报错，避免上游修好后这个补丁悄悄留在原地。

## 已知缺口

**卸载不删文件。** lunar 的 remove 只把包从数据库移除，文件删除交给包自己的 `remove.opsis`。这批自举包的 `scripts/` 目录是空的，所以卸载是空操作、但报告成功。正确修法是让 `system.db` 记录已安装文件清单——那是改存储格式，不是改调用点，所以这里没做。

**用户态已经没有交叉编译的包了，除了 `iputils` 和 `systemd`。** 仓库里 71 个配方，其中 binutils/gcc/glibc 由更早的两步重编，其余 66 个在这一步由系统自己的编译器、在系统内部、用当初产出交叉包的那同一套配方重编——一共 66 个编成、0 个失败。剩下的 `iputils` 和 `systemd` 要 meson 和 ninja，这两个不是本系统的包、装不进用户态，所以被显式跳过（`OKRA_SKIP`）并在日志里点名，而不是让整轮失败。这两个包的交叉编译版本仍在仓库里。

重编用的还是当初产出交叉包的那套配方，只是编译器换成了系统自己的。有几处配方对宿主的假设在这条路上不成立，它们集中在一个脚本里改（`patch-recipes-for-native.sh`），每条改动都要能匹配上原文，匹配不上就停下来报错——而不是悄悄不生效。

**没做 QEMU 启动。** 产出是 rootfs 目录，不是可引导镜像。

**发布的仓库是整个仓库，不是子集。** `okra-repo` 现在有 151 个资产、约 893 MB：索引加上每个包的 `.oaa` 和 `.sha256`。以前只上传本次运行产出的那几个，剩下的靠上一次运行留着；现在重编把仓库里每一份归档都换成了系统自己编的，所以要么整份发布、要么索引和内容对不上。守卫也在这里——文件数少于 60 就直接失败。

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

约 70 分钟。两轮原生重编（binutils+gcc，然后 libxcrypt+glibc）和 gcc 的重打包（682 MB）各占一块，66 个包的重编是最大的一块（包里 gcc 最贵）。几处噪声大的编译输出写进单独文件，只把摘要打给 job 日志：GitHub 会截断超过几 MB 的日志，而被截掉的恰好是最后出错那一步。

产物发到 `okra-repo` release：**整个仓库**，151 个资产、约 893 MB——`index.yaml`，加上每个包的 `.oaa` 和配套 `.sha256`。其中 `GNU.gcc@*.oaa`、`GNU.binutils@*.oaa`、`app.glibc@*.oaa` 和其余 66 个包都是**系统自己编的**；只有 `iputils` 和 `systemd` 还是交叉编译版本，因为它们要的 meson/ninja 不是本系统的包。

## 依赖

- 交叉工具链：`ylh440104/okra-oaa-packages-x86_64` 的 `okra-cross-toolchain` artifact
- 70 个自举包：同仓库 `okra-userland` release
- OkraPM 源码：`OkraLinux/okrapm`
- OAA 格式与 lunar 的仓库协议：`OkraLinux/okrapm`（`oaatools/`、`repo-server/`）
