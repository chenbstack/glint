# Glint

English · [中文](README.md)

A polished macOS terminal made for AI agents. SwiftUI + AppKit, with [Ghostty](https://ghostty.org) under the hood.

![Glint screenshot](docs/screenshot.png)

![Workspace state overview](docs/screenshot-sidebar.png)

## Install

### Homebrew (recommended)

```bash
brew tap chenbstack/glint
brew install --cask glint
```

### Manual download

Grab the latest `Glint-x.y.z.dmg` from the [Releases](https://github.com/chenbstack/glint/releases) page, mount it, and drag `Glint.app` into `/Applications`.

If macOS refuses to open it with "developer cannot be verified", run once:

```bash
xattr -dr com.apple.quarantine /Applications/Glint.app
```

The Homebrew Cask does this automatically.

## External control CLI

In Settings → Terminal → External control, **Install CLI** creates `~/.local/bin/glint`. Add `~/.local/bin` to `PATH` if needed. The native CLI ships with Glint and requires no Node.js, Python, or MCP. **Copy Agent instructions** includes the full executable path and works without installing the link.

Settings shows the installed state and disables repeat installation. Use **Uninstall** or `glint uninstall` to remove its command link. Uninstalling preserves the bundled CLI and the control preference. After moving Glint, dangling links to a missing Glint installation can be repaired by installing again, or removed with uninstall. A valid link to another existing Glint is shown separately and left unchanged by install and uninstall. Other tools’ files and links are also preserved.

Installing the CLI does not grant control. **Allow external control** must be enabled for reads, input, and focus. Turning it off revokes access immediately; old connections and tokens remain invalid after re-enabling it. The CLI never launches Glint or enables control automatically.

```sh
glint --help
glint panes list
glint pane read '<pane-id>' --scrollback --max-lines 1000
glint pane send '<pane-id>' --text 'pwd' --enter
glint pane key '<pane-id>' down enter
```

Use the full pane handle from the list. Reads and input preserve local workspace selection; only explicit `glint pane focus '<pane-id>'` switches focus. Reads return plain text unless `--json` is supplied; other commands return JSON. Use `glint --debug …` for a development build. You can also run `/Applications/Glint.app/Contents/Helpers/glint` directly, or use its `install` subcommand to install the link.

The CLI can read and write background terminals that are already ready, and wake terminals with no pending history or startup tasks, without changing the local workspace.

**Background access after restarting Glint:** scrollback restoration is enabled by default. If a background pane has an archive awaiting restoration after an app restart, both CLI reads and input return `pane-requires-local-open`. Open that terminal in Glint and let restoration complete before retrying; this also applies to reads without `--scrollback`. This version therefore cannot directly wake every archived background terminal after a restart through the CLI. Web Remote can still restore history at the browser’s explicit grid size.

For pending startup or agent restore commands, both the CLI and Web prompt you to open the terminal in Glint first; remote access does not run those commands without a local view.

Custom `--socket` endpoints require a user-owned private directory (0700) and user-owned socket/token files (0600); token symlinks are rejected. Encoded requests are limited to 1 MiB, with explicit errors for oversized requests.

## Upgrade & uninstall

```bash
brew upgrade --cask glint
brew uninstall --cask glint
```

## License

MIT — see [LICENSE](LICENSE).
