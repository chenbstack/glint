# Glint

中文 · [English](README.en.md)

为 AI 代理打造的精致 macOS 终端。底层基于 [Ghostty](https://ghostty.org),界面用 SwiftUI + AppKit。

## 安装

### Homebrew(推荐)

```bash
brew tap chenbstack/glint
brew install --cask glint
```

### 手动下载

从 [Releases](https://github.com/chenbstack/glint/releases) 页面下载最新的 `Glint-x.y.z.dmg`,挂载后把 `Glint.app` 拖进 `/Applications`。

如果提示"无法打开,因为无法验证开发者",在终端里跑一次:

```bash
xattr -dr com.apple.quarantine /Applications/Glint.app
```

Cask 安装方式会自动帮你做这一步。

## 升级与卸载

```bash
brew update && brew upgrade --cask glint
brew uninstall --cask glint
```

## 协议

MIT — 详见 [LICENSE](LICENSE)。
