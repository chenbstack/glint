# Glint

中文 · [English](README.en.md)

为 AI 代理打造的精致 macOS 终端。底层基于 [Ghostty](https://ghostty.org),界面用 SwiftUI + AppKit。

## 安装

### Homebrew(推荐)

```bash
brew tap chenbstack/glint
brew install --cask glint
```

Tap 仓库在 `github.com/chenbstack/homebrew-glint`,Cask formula 由 release 工作流自动生成,详见下文 [发布流程](#发布流程)。

### 手动下载

从 [Releases](https://github.com/chenbstack/glint/releases) 页面下载最新的 `Glint-x.y.z.dmg`,双击挂载后把 `Glint.app` 拖进 `/Applications` 即可。

如果系统提示"无法打开,因为无法验证开发者",这是因为 Glint 当前还未做苹果公证。在终端里跑一次:

```bash
xattr -dr com.apple.quarantine /Applications/Glint.app
```

之后正常打开即可。Cask 安装方式会自动帮你做这一步。

## 升级

```bash
brew upgrade --cask glint
```

如果在 Glint 设置里开启了自动检查更新(Sparkle),app 启动时会自己提示新版本,点击安装即可。

## 卸载

```bash
brew uninstall --cask glint
```

会一并清理 `~/Library/Application Support/Glint` 和偏好设置。

## 从源码构建

需要 Xcode 16+、macOS 14+、[zig](https://ziglang.org)(版本必须跟 `ghostty/build.zig.zon` 里的 `minimum_zig_version` 一致,当前是 **0.15.2**;Homebrew 的 `zig` 默认装最新版会编译失败)。

```bash
git clone --recurse-submodules https://github.com/chenbstack/glint.git
cd glint

# 装对版本的 zig(以 mise 为例,或者从 ziglang.org/download/ 下对应 tarball)
mise use zig@0.15.2

# 从 ghostty submodule 编译 GhosttyKit.xcframework(首次 10-20 分钟,后续基于 SHA 缓存)
bash scripts/setup-ghosttykit.sh

open Glint.xcodeproj
```

Ghostty 作为 git submodule 锁在 `ghostty/` 目录,版本由 submodule 的 commit SHA 决定。要升级 ghostty:

```bash
cd ghostty
git fetch --tags
git checkout v1.4.0     # 切到目标 tag
cd ..
git add ghostty && git commit -m "bump ghostty to v1.4.0"
bash scripts/setup-ghosttykit.sh   # 重新编译
```

## 发布流程

在 `main` 上打 `vX.Y.Z` 标签后,`.github/workflows/release.yml` 会:

1. 把版本号写入 `Info.plist`
2. 编译 Release 配置,导出 `Glint.app`
3.(可选)用 Developer ID 签名 + `notarytool` 公证
4. 打成 `.dmg`
5.(可选)用 Sparkle 的 EdDSA 私钥签名,把新 `<item>` 追加进 `appcast.xml`
6. 发布 GitHub Release,带上 dmg 和 appcast
7. 把更新后的 `appcast.xml` 回推到 `main`

### 必需 secret

无 —— GhosttyKit 从 ghostty submodule 直接 build,版本绑定 submodule SHA。

### 可选 secret —— 启用签名 + Sparkle

不配这些就出 ad-hoc 包,用户照样能通过 Cask 安装(postinstall 会自动去除 quarantine)。等你买了 Apple 开发者账号($99/年)再加。

| Secret | 用途 |
|---|---|
| `APPLE_CERT_P12_BASE64` | Developer ID Application `.p12` 的 base64 |
| `APPLE_CERT_PASSWORD` | 导出 `.p12` 时设的密码 |
| `APPLE_NOTARY_ID` | 用于公证的 Apple ID |
| `APPLE_NOTARY_PASSWORD` | 从 appleid.apple.com 申请的 app-specific password |
| `APPLE_NOTARY_TEAM_ID` | 10 位字符的 team identifier |
| `SPARKLE_ED_PRIV_KEY` | Sparkle `generate_keys` 生成的 EdDSA 私钥;对应的公钥写到 `Info.plist` 的 `SUPublicEDKey` |

### Sparkle 密钥初始化

```bash
# 本地跑一次:
curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz | tar -xJ
./Sparkle-2.6.4/bin/generate_keys
# 私钥存进 Keychain,会打印对应的公钥。
# 把私钥复制进仓库 secret SPARKLE_ED_PRIV_KEY,
# 把公钥粘进 Glint/Resources/Info.plist 的 SUPublicEDKey。
```

## 协议

MIT — 详见 [LICENSE](LICENSE)。
