import Foundation
import Darwin
import MachO

private let help = """
Glint CLI — local terminal control / 本地终端控制

Usage / 用法:
  glint [--debug | --socket PATH] panes list
  glint [--debug | --socket PATH] pane read PANE [--scrollback] [--max-lines N] [--json]
  glint [--debug | --socket PATH] pane send PANE --text TEXT [--enter]
  glint [--debug | --socket PATH] pane key PANE KEY [KEY ...]
  glint [--debug | --socket PATH] pane focus PANE
  glint install [--directory DIR]
  glint uninstall [--directory DIR]
  glint --help

Enable Settings > Terminal > External control in Glint first.
请先在 Glint 设置 > 终端 > 外部控制中开启控制开关。
The CLI never enables control or launches Glint. / CLI 不会开启控制或启动 Glint。
Custom sockets require a private directory (0700) and socket/token files (0600), owned by your user.
自定义 socket 的目录须为 0700，socket 与 token 文件须为 0600，且均归当前用户所有。
Encoded requests are limited to 1 MiB. / 编码后的请求最多 1 MiB。
Default: ~/.glint/run/control.sock; --debug selects control-debug.sock.
默认连接正式版；--debug 连接开发版。--socket selects an explicit socket / 指定 socket。
PANE is the full handle returned by `panes list` / PANE 使用列表返回的完整标识。
List/send/key/focus return JSON; read returns text unless --json is supplied.
列表和操作返回 JSON；读取默认返回纯文本，--json 返回完整 JSON。
Read defaults to viewport, max 1000 lines (allowed: 1–10000).
读取默认只含可见内容，默认最多 1000 行（范围 1–10000）。
Keys / 按键: enter, return, esc, escape, tab, space, up, down, left, right, A-Z, a-z, 0-9.
Reads and input keep local focus; only explicit focus switches workspace.
读取和输入不切换本地工作区，只有显式 focus 才切换。
Install creates ~/.local/bin/glint; add ~/.local/bin to PATH if needed.
安装创建 ~/.local/bin/glint 链接；必要时将 ~/.local/bin 加入 PATH。
Reinstall is refused; uninstall removes only this CLI's link.
已安装时拒绝重复安装；uninstall 只移除此 CLI 的命令链接。
Exit / 退出码: 0 success / 成功; 1 unavailable or rejected / 不可用或拒绝; 2 usage / 参数错误。
"""

private struct CLIError: Error {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
}

private struct Invocation {
    var socketPath: String
    var request: [String: Any]
    var plainText = false
}

private func parseSocketOptions(_ args: inout ArraySlice<String>) throws -> String {
    var socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".glint/run/control.sock").path
    var selectedSocket = false
    while let first = args.first, first.hasPrefix("--"), first != "--help" {
        args.removeFirst()
        guard !selectedSocket else { throw CLIError("Choose only one socket / 只能指定一个 socket", code: 2) }
        selectedSocket = true
        switch first {
        case "--debug":
            socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".glint/run/control-debug.sock").path
        case "--socket":
            guard let value = args.first, !value.isEmpty else {
                throw CLIError("--socket requires a path / 需要路径", code: 2)
            }
            socketPath = (value as NSString).expandingTildeInPath
            args.removeFirst()
        default: throw CLIError("Unknown option / 未知选项: \(first)", code: 2)
        }
    }
    return socketPath
}

private func parse(_ arguments: [String], socketPath: String) throws -> Invocation {
    var args = arguments[...]
    if Array(args) == ["panes", "list"] {
        return Invocation(socketPath: socketPath, request: ["cmd": "list"])
    }
    guard args.count >= 3, args.removeFirst() == "pane" else {
        throw CLIError("Expected a command; use glint --help / 请输入命令，使用 glint --help 查看用法", code: 2)
    }
    let command = args.removeFirst()
    let pane = args.removeFirst()
    let parts = pane.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
          UInt32(parts[1]) != nil else {
        throw CLIError("Invalid pane handle; use panes list / 窗格标识不合法，请先运行 panes list", code: 2)
    }
    var request: [String: Any] = ["pane": pane]
    var plainText = false
    switch command {
    case "read":
        request["cmd"] = "read-text"
        plainText = true
        var seen = Set<String>()
        while let option = args.first {
            args.removeFirst()
            guard seen.insert(option).inserted else { throw CLIError("Repeated option / 重复选项: \(option)", code: 2) }
            switch option {
            case "--scrollback": request["scrollback"] = true
            case "--json": plainText = false
            case "--max-lines":
                guard let value = args.first, let lines = Int(value), (1...10_000).contains(lines) else {
                    throw CLIError("--max-lines must be 1–10000 / 行数必须为 1–10000", code: 2)
                }
                args.removeFirst()
                request["maxLines"] = lines
            default: throw CLIError("Unknown read option / 未知读取选项: \(option)", code: 2)
            }
        }
    case "send":
        request["cmd"] = "send-text"
        var seen = Set<String>()
        while let option = args.first {
            args.removeFirst()
            guard seen.insert(option).inserted else { throw CLIError("Repeated option / 重复选项: \(option)", code: 2) }
            switch option {
            case "--text":
                guard let text = args.first else { throw CLIError("--text requires text / 需要文字", code: 2) }
                args.removeFirst()
                request["text"] = text
            case "--enter": request["enter"] = true
            default: throw CLIError("Unknown send option / 未知输入选项: \(option)", code: 2)
            }
        }
        guard request["text"] != nil else { throw CLIError("--text is required / 必须指定 --text", code: 2) }
    case "key":
        request["cmd"] = "send-key"
        let specials: Set<String> = ["enter", "return", "esc", "escape", "tab", "space", "up", "down", "left", "right"]
        guard !args.isEmpty, args.allSatisfy({ key in
            specials.contains(key) || (key.utf8.count == 1 && key.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            })
        }) else { throw CLIError("Unknown or missing key; use --help / 按键为空或不支持，请查看 --help", code: 2) }
        request["keys"] = Array(args)
    case "focus":
        guard args.isEmpty else { throw CLIError("focus accepts only PANE / focus 只接受窗格标识", code: 2) }
        request["cmd"] = "focus"
    default: throw CLIError("Unknown pane command / 未知窗格命令: \(command)", code: 2)
    }
    return Invocation(socketPath: socketPath, request: request, plainText: plainText)
}

private func validateControlSocket(_ path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
    var parent = stat(), endpoint = stat()
    guard lstat(path, &endpoint) == 0 else {
        throw CLIError("Glint is unavailable or external control is off. Enable External control in Glint Settings. / Glint 未运行或外部控制已关闭，请在设置中开启。")
    }
    guard stat(directory, &parent) == 0, parent.st_uid == getuid(),
          parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o077 == 0,
          endpoint.st_uid == getuid(), endpoint.st_mode & S_IFMT == S_IFSOCK,
          endpoint.st_mode & 0o077 == 0 else {
        throw CLIError("Unsafe control socket: use a private directory (0700) and socket (0600) owned by your user. / 控制 socket 不安全：目录须为 0700，socket 须为 0600，且均归当前用户所有。")
    }
}

private func readControlToken(socketPath: String) throws -> String {
    let path = URL(fileURLWithPath: socketPath).deletingPathExtension().appendingPathExtension("token").path
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw CLIError("Control token is unavailable or unsafe. Re-enable External control in Glint. / 控制令牌不可用或不安全，请重新开启外部控制。") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
          info.st_size > 0, info.st_size <= 4096 else {
        throw CLIError("Unsafe control token: use a regular file (0600) owned by your user. / 控制令牌不安全：须为归当前用户所有的 0600 普通文件。")
    }
    let token = String(decoding: file.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw CLIError("Control token is empty / 控制令牌为空") }
    return token
}

private func transact(_ invocation: Invocation) throws -> [String: Any] {
    try validateControlSocket(invocation.socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CLIError("Cannot create socket / 无法创建 socket") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard invocation.socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw CLIError("Socket path too long / socket 路径过长", code: 2)
    }
    invocation.socketPath.withCString { source in
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            _ = strlcpy(target.baseAddress!.assumingMemoryBound(to: CChar.self), source, target.count)
        }
    }
    var request = invocation.request
    if ["send-text", "send-key", "read-text"].contains(request["cmd"] as? String ?? "") {
        request["token"] = try readControlToken(socketPath: invocation.socketPath)
    }
    var payload = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    guard payload.count <= 1 << 20 else {
        throw CLIError("request-too-large: encoded requests must not exceed 1 MiB / 编码后的请求不得超过 1 MiB", code: 2)
    }
    payload.append(0x0A)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        throw CLIError("Glint is unavailable or external control is off. Open Glint and enable External control in Settings. / Glint 未运行或外部控制已关闭，请在设置中开启。")
    }
    try payload.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw CLIError("Control connection closed or timed out / 控制连接已关闭或超时") }
            offset += n
        }
    }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw CLIError("Control connection closed or timed out / 控制连接已关闭或超时") }
        let chunkStart = response.count
        response.append(buffer, count: n)
        // Earlier chunks contain no delimiter; scan only the bytes just received.
        if let newline = response[chunkStart...].firstIndex(of: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: response.prefix(upTo: newline)) as? [String: Any],
                  object["ok"] is Bool else { throw CLIError("Invalid Glint response / Glint 响应不合法") }
            return object
        }
        guard response.count <= 64 * 1024 * 1024 else { throw CLIError("Response too large / 响应过大") }
    }
}

private func run() throws {
    var remaining = CommandLine.arguments.dropFirst()
    let socketPath = try parseSocketOptions(&remaining)
    let args = Array(remaining)
    let helpPrefixes = [[], ["panes"], ["pane"], ["pane", "read"], ["pane", "send"],
                        ["pane", "key"], ["pane", "focus"], ["install"], ["uninstall"]]
    if args.isEmpty || args == ["help"]
        || (args.last == "--help" && helpPrefixes.contains(Array(args.dropLast()))) {
        print(help)
        return
    }
    if args.first == "install" || args.first == "uninstall" {
        let directory: URL
        if args.count == 1 {
            directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        } else if args.count == 3, args[1] == "--directory" {
            directory = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath, isDirectory: true)
        } else { throw CLIError("Usage / 用法: glint install|uninstall [--directory DIR]", code: 2) }
        // Bundle.main refers to the enclosing GUI app when this helper lives
        // in Contents/Helpers. dyld identifies the actual CLI, including PATH links.
        var pathSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &pathSize)
        var pathBuffer = [CChar](repeating: 0, count: Int(pathSize))
        guard _NSGetExecutablePath(&pathBuffer, &pathSize) == 0 else {
            throw CLIError("Cannot locate CLI executable / 无法定位 CLI 可执行文件")
        }
        let executable = URL(fileURLWithPath: String(cString: pathBuffer)).resolvingSymlinksInPath()
        if args.first == "uninstall" {
            try CLIInstallation.uninstall(executable: executable, directory: directory)
            print("CLI link removed / CLI 命令链接已移除: \(directory.appendingPathComponent("glint").path)")
        } else {
            let installed = try CLIInstallation.install(executable: executable, directory: directory)
            print("Installed / 已安装: \(installed.path)\nAdd its directory to PATH if needed / 必要时将该目录加入 PATH")
        }
        return
    }
    let invocation = try parse(args, socketPath: socketPath)
    let response = try transact(invocation)
    guard response["ok"] as? Bool == true else {
        // Never echo requests or token values in errors.
        let error = response["error"] as? String ?? "unknown-error"
        if error == "pane-requires-local-open" {
            throw CLIError("Open this terminal in Glint first (or explicitly use pane focus PANE), then retry. Pending history, startup and agent restoration require a local view. / 请先在 Glint 中打开此终端（或明确使用 pane focus PANE），再重试；待恢复历史、待启动和 agent 恢复命令须先在本地视图中处理。")
        }
        throw CLIError("Glint rejected the command / Glint 拒绝命令: \(error)")
    }
    if invocation.plainText {
        guard let text = response["text"] as? String else { throw CLIError("Missing terminal text / 响应缺少终端文字") }
        FileHandle.standardOutput.write(Data(text.utf8))
        if !text.isEmpty && !text.hasSuffix("\n") { FileHandle.standardOutput.write(Data([0x0A])) }
    } else {
        var output = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .withoutEscapingSlashes])
        output.append(0x0A)
        FileHandle.standardOutput.write(output)
    }
}

do { try run() }
catch let error as CLIError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(error.code)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
