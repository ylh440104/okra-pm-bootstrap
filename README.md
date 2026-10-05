# okra-pm-bootstrap

OkraPM 驱动整条自举链路的验证仓库（x86_64）。

## 这是什么

方案 B：**包管理器管整个系统**。

自举出来的每一个文件都由一次安装事务写进去，包管理器自己也是这些包中的一个。

这条链路分五步，每步都要能独立验证：

1. 交叉工具链把 70 个自举包组装成一个可 chroot 的用户态
2. **OkraPM 用这个用户态里的 g++ 编译自己**，再用自己的 opsis 打包
3. 结果变成一个 Lunar 软件源——lunar 能 sync 的那种，含之前缺失的 `app.glibc`
4. 宿主机上的 lunar 把这整套用户态**装进一个空目录**，按依赖顺序，一次事务
5. 事务装进去的那个包管理器，在 chroot 里**再装一遍包**，只用事务放进去的东西

第 5 步是方案 B 与方案 A 的分界线：包管理器不是系统建好后补装的，它本来就是仓库里的一个包，由它所属的系统编译出来，再从系统内部管理这个系统。

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

## 目录

```
.github/workflows/scheme-b.yml   整条链路的执行与验证
scripts/fetch-toolchain.sh       取 x86_64-okra-linux-gnu 交叉工具链
scripts/fetch-packages.sh        取 70 个自举包
scripts/assemble-userland.sh     工具链 sysroot + 包 → rootfs
scripts/build-okrapm.sh          在 Okra 用户态里编译 OkraPM
scripts/make-glibc-package.sh    sysroot 合成 app.glibc 包
scripts/publish-repo.sh          打包成 Lunar 软件源
scripts/repo-server.py           提供软件源，生成 index.yaml
scripts/verify-scheme-b.sh       用 lunar 装整个系统并验证
```

## 两个关键设计

**app.glibc 是合成出来的，不是手写的。** 交叉工具链把 glibc 直接装进 `okra-sysroot/`，绕过了包系统。`make-glibc-package.sh` 把 70 个包的 `files:` 列表读出来，sysroot 里**没被任何包认领**的部分就是 glibc 基座。这样某个包以后多装一个文件，不会突然变成两个包都声称拥有它。

**归档按 lunar 的解析规则改名。** 自举产物叫 `make-4.4.1-1.x86_64.bootstrapped.oaa`，而 lunar 去仓库找的是 `<namespace>.<name>@<version>.oaa`，也就是 `GNU.make@4.4.1.oaa`。namespace 和 version 从 `meta.yaml` 里读，不从文件名猜——两者不总是一致的。

## 已知缺口

这些是脚本**明确补上并打印出来**的，不是藏起来的：

| 缺什么 | 为什么 | 现在怎么处理 |
|---|---|---|
| `base-files` 类包 | 没人提供 `/bin/sh`、`/etc/passwd` | `verify-scheme-b.sh` 建完并报告 |
| `cc`、`c++`、`pkg-config` 名字 | 在宿主上属于发行版，不属于任何软件包 | `assemble-userland.sh` 建符号链接 |
| `libgcc_s.so.1` 在 `/usr/lib64` | loader 只搜 `libc.so.6` 所在目录 | 建链接到 `/usr/lib` |

要真正干净，这些应该各自成为包（`app.base-files`、`app.toolchain-aliases`），让仓库里没有"脚本放进去的文件"。

## 种子

仍然是 Ubuntu 自带的 gcc——它编出了交叉工具链，这一步任何方案都绕不开。之后所有东西都来自交叉工具链。

## 运行

```bash
gh workflow run scheme-b.yml -f okrapm_ref=main
```

产物发到 `okra-repo` release：`index.yaml` + `Okra.okrapm.oaa`。

## 依赖

- 交叉工具链：`ylh440104/okra-oaa-packages-x86_64` 的 `okra-cross-toolchain` artifact
- 70 个自举包：同仓库 `okra-userland` release
- OkraPM 源码：`OkraLinux/okrapm`
- OAA 格式与 lunar 的仓库协议：`OkraLinux/okrapm`（`oaatools/`、`repo-server/`）
