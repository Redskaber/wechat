# WeChat for NixOS / Nix

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Daily update](https://github.com/redskaber/wechat/actions/workflows/daily-update.yml/badge.svg)](.github/workflows/daily-update.yml)
[![Maintainer: redskaber](https://img.shields.io/badge/maintainer-redskaber-blue.svg)](https://github.com/redskaber)

自动从腾讯官方 CDN 拉取最新版微信（WeChat）二进制并生成可重现的 Nix 包，覆盖 **Linux x86_64 / arm64** 与 **macOS universal** 全平台。

> **Author**: [@redskaber](https://github.com/redskaber)  
> 该项目仅提供 Nix 打包胶水代码，不重新分发上游微信二进制；微信及其商标归腾讯所有，下载即视为接受腾讯 EULA。

## 支持的平台

| 平台            | 来源                                              | 当前版本   | Nix 系统         |
| --------------- | ------------------------------------------------- | ---------- | ---------------- |
| `x86_64-linux`  | `WeChatLinux_x86_64.deb`                          | 4.1.1.8    | ✅ supported     |
| `aarch64-linux` | `WeChatLinux_arm64.deb`                           | 4.1.1.8    | ✅ supported     |
| `aarch64-darwin`| `WeChatMac_<ver>.dmg` (universal)                | 4.1.12     | ✅ supported     |
| `x86_64-darwin` | `WeChatMac_<ver>.dmg` (universal)                 | 4.1.12     | ⚠️ dropped by nixpkgs 26.11 |

## 项目结构

```
wechat/
├── flake.nix            # Flake 定义（全平台 outputs）
├── sources.nix          # 自动生成的源 URL 与 SHA256（update.sh 维护）
├── package-linux.nix    # Linux derivation（基于 .deb + autoPatchelf）
├── package-darwin.nix   # macOS derivation（基于 .dmg + 7zip/hdiutil）
├── update.sh            # 自动探测官方最新版本并刷新 sources.nix
├── .github/workflows/
│   └── daily-update.yml # 每日凌晨 03:00 (Asia/Shanghai) 自动检查并提 PR
├── README.md
└── LICENSE
```

## 快速开始

```bash
# 0. 进入项目目录
cd wechat

# 1. 刷新到最新版本（自动下载 deb/dmg 并更新 sources.nix）
nix run .#update-sources
# 或直接执行
./update.sh

# 2. 构建当前平台的包
nix build .#wechat
# 构建结果在 ./result

# 3. 直接运行
nix run .#wechat
# 或
./result/bin/wechat

# 4. 跨平台构建（例如在 macOS 上构建 Linux 版本 — 需要相应支持）
nix build .#packages.x86_64-linux.wechat

# 5. 调试时也可访问未包 FHS 的中间产物
nix build .#wechat-unwrapped
```

## Linux 平台

Linux 微信来自官方 `.deb` 包，采用 **两层构建** 结构：

### Layer 1: `wechat-unwrapped`
- 通过 `autoPatchelfHook` 修补所有 ELF（`wechat` 主程序 + `*.so`）的解释器与 RPATH
- ✅ 完整的运行时依赖清单（X11 / XCB / PulseAudio / NSS / Kerberos / DBus / 字体等）
- ✅ 自动安装 desktop entry 与 hicolor 图标
- ✅ `--no-sandbox` 与 `--enable-features=UseOzonePlatform` 启动参数（兼容 Wayland）
- ✅ 字体补丁：内置 Noto CJK 字体（解决中文显示方块问题）

### Layer 2: `wechat` (FHS namespace)
- WeChat 内部通过 `popen()` 调用 `/usr/bin/lsblk`、`/usr/bin/udevadm`、
  `/usr/bin/ps` 等绝对 FHS 路径的命令（字符串藏在加密资源中）
- NixOS 默认无 `/usr/bin/`，会报 `sh: line 1: /usr/bin/lsblk: No such file or directory`
- 用 `buildFHSEnv` 包裹一层 bubblewrap namespace，在内部提供真实的 `/usr/bin/`：
  - `util-linux` 提供 `lsblk` / `mount` / `umount`
  - `systemd` 提供 `udevadm`
  - `procps` 提供 `ps` / `top` / `free`
  - `iproute2` / `iputils` 提供 `ip` / `ping`
  - `coreutils` / `findutils` / `gnugrep` / `gnused` / `gawk` / `which`
  - `pciutils` / `usbutils` 提供 `lspci` / `lsusb`
  - 共 610+ 个标准 FHS 命令

## macOS 平台

macOS 微信来自官方 universal `.dmg`，无 root 即可解包：

- 在 macOS 上构建：使用系统自带 `hdiutil` 挂载并复制 `.app`
- 在 Linux 上交叉检查：使用 `p7zip` 两段式解压 HFS+ 镜像

构建产物：
```
result/
├── Applications/
│   └── WeChat.app/
└── bin/
    └── wechat -> ../Applications/WeChat.app/Contents/MacOS/WeChat
```

## CI/CD 自动更新

`.github/workflows/daily-update.yml` 配置了 GitHub Actions，每日凌晨 03:00 (Asia/Shanghai) 自动：

1. 拉取最新 `nixpkgs-unstable`
2. 运行 `./update.sh` 刷新 `sources.nix`
3. 如有变化，运行 `nix flake check` 验证
4. 创建 PR（或直接提交到 `main` 分支，取决于配置）

本地也可以手动触发：

```bash
gh workflow run daily-update.yml
```

## 验证与测试

```bash
# 1. flake 元数据校验
nix flake check

# 2. 在 nix-shell 中检查依赖
nix develop .#wechat

# 3. 构建并查看 closure 大小
nix build .#wechat --print-out-paths
nix path-info -Sh $(readlink ./result)
```

## 维护说明

- **更新触发**: `update.sh` 由 CI/CD 或本地手动运行；幂等可重复。
- **版本策略**: Linux 版本来自 `.deb` 的 `control` 文件；macOS 版本来自 `.dmg` 文件名。
- **回滚**: `sources.nix` 受 git 版本控制，任何一次更新都可回滚到历史版本。
- **缓存**: 推荐配置 `cachix` 或自建二进制缓存以加速 CI。

## 许可

打包胶水代码遵循 [MIT](LICENSE)；微信二进制本身归腾讯所有，使用受腾讯 EULA 约束。

## 相关链接

- 官方下载页：<https://linux.weixin.qq.com> / <https://mac.weixin.qq.com>
- Tencent CDN：<https://dldir1v6.qq.com/weixin/Universal/>
- Nix 文档：<https://nix.dev/manual/nix/2.33/>
