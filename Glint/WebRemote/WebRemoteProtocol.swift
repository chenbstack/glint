import Darwin
import Foundation
import Security

enum WebRemoteTerminalSnapshotResult {
    case success(Data)
    case failure(String)
}

enum WebRemoteOpenProjectResult {
    case success(UUID)
    case failure(String)
}

enum WebRemoteCreateTerminalResult {
    case success(String)
    case failure(String)
}

struct WebRemoteTerminalSize: Equatable {
    static let columnRange = 20 ... 500
    static let rowRange = 5 ... 200

    let columns: Int
    let rows: Int

    static func parse(_ object: [String: Any]) -> WebRemoteTerminalSize? {
        guard let columns = object["columns"] as? Int,
              let rows = object["rows"] as? Int,
              columnRange.contains(columns),
              rowRange.contains(rows)
        else { return nil }
        return WebRemoteTerminalSize(columns: columns, rows: rows)
    }
}

enum WebRemoteSnapshotPayload {
    private static let resetScreen = "\u{1b}[0m\u{1b}[2J\u{1b}[H"

    static func make(ansi: String?) -> Data {
        let terminalANSI = ansi?.replacingOccurrences(of: "\n", with: "\r\n") ?? ""
        return Data((resetScreen + terminalANSI).utf8)
    }
}

enum WebRemoteProjectPath {
    static func resolveExistingDirectory(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard standardized.hasPrefix("/"),
              FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return standardized
    }
}

struct WebRemoteAccessToken {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max)
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ provided: String?, expected: String) -> Bool {
        guard let provided else { return false }
        let lhs = Array(provided.utf8)
        let rhs = Array(expected.utf8)
        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        let count = max(lhs.count, rhs.count)
        for index in 0 ..< count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}

enum WebRemoteAccessKeyStore {
    private static let defaultsKey = "glint.webRemoteAccessKey"

    static func loadOrCreate(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), isValid(existing) {
            return existing
        }
        return reset(defaults: defaults)
    }

    @discardableResult
    static func reset(defaults: UserDefaults = .standard) -> String {
        let key = WebRemoteAccessToken.generate()
        defaults.set(key, forKey: defaultsKey)
        return key
    }

    private static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

enum WebRemoteAccessURL {
    static func token(from value: String) -> String? {
        guard let fragment = URLComponents(string: value)?.fragment else { return nil }
        return URLComponents(string: "?\(fragment)")?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value
    }
}

struct WebRemoteHTTPRequest: Equatable {
    enum Method: String {
        case get = "GET"
        case head = "HEAD"
    }

    let method: Method
    let path: String

    static func parse(_ data: Data) -> WebRemoteHTTPRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              let method = Method(rawValue: String(parts[0])),
              parts[2].hasPrefix("HTTP/1.")
        else { return nil }
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? rawPath
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return WebRemoteHTTPRequest(method: method, path: path)
    }
}

struct WebRemoteAsset: Equatable {
    let resource: String
    let fileExtension: String
    let contentType: String
    let cacheControl: String
}

enum WebRemoteAssets {
    static func asset(for path: String) -> WebRemoteAsset? {
        switch path {
        case "/", "/index.html":
            WebRemoteAsset(
                resource: "web-remote-index",
                fileExtension: "html",
                contentType: "text/html; charset=utf-8",
                cacheControl: "no-store"
            )
        case "/app.css":
            WebRemoteAsset(
                resource: "web-remote",
                fileExtension: "css",
                contentType: "text/css; charset=utf-8",
                cacheControl: "no-cache"
            )
        case "/app.js":
            WebRemoteAsset(
                resource: "web-remote",
                fileExtension: "js",
                contentType: "text/javascript; charset=utf-8",
                cacheControl: "no-cache"
            )
        case "/xterm.css":
            WebRemoteAsset(
                resource: "xterm",
                fileExtension: "css",
                contentType: "text/css; charset=utf-8",
                cacheControl: "public, max-age=31536000, immutable"
            )
        case "/xterm.mjs":
            WebRemoteAsset(
                resource: "xterm",
                fileExtension: "mjs",
                contentType: "text/javascript; charset=utf-8",
                cacheControl: "public, max-age=31536000, immutable"
            )
        case "/addon-fit.mjs":
            WebRemoteAsset(
                resource: "addon-fit",
                fileExtension: "mjs",
                contentType: "text/javascript; charset=utf-8",
                cacheControl: "public, max-age=31536000, immutable"
            )
        case "/symbols-nerd-font-mono.ttf":
            WebRemoteAsset(
                resource: "SymbolsNerdFontMono-Regular",
                fileExtension: "ttf",
                contentType: "font/ttf",
                cacheControl: "public, max-age=31536000, immutable"
            )
        default:
            nil
        }
    }
}

enum WebRemoteHTTPResponse {
    static func make(
        status: Int,
        reason: String,
        contentType: String,
        cacheControl: String = "no-store",
        body: Data,
        includeBody: Bool = true
    ) -> Data {
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: \(cacheControl)\r
        Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r
        Cross-Origin-Opener-Policy: same-origin\r
        Referrer-Policy: no-referrer\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        if includeBody {
            response.append(body)
        }
        return response
    }
}

/// A non-loopback, up, IPv4 interface this Mac can bind the web remote to.
/// The BSD name (e.g. "en0") is the stable identity; `address` is its current
/// IPv4 and may change across DHCP/sleep — re-resolve at bind time.
struct WebRemoteInterface: Hashable, Identifiable {
    var id: String { name }
    let name: String
    let displayName: String
    let address: String
}

enum WebRemoteAddressResolver {
    /// All non-loopback IPv4 addresses, priority-sorted and de-duplicated by
    /// address. Used to populate the "All interfaces" access URLs.
    static func localIPv4Addresses() -> [String] {
        sortedEntries()
            .map(\.address)
            .reduce(into: [String]()) { result, address in
                if !result.contains(address) { result.append(address) }
            }
    }

    /// One entry per interface (first IPv4 wins), priority-sorted. Drives the
    /// "Listen on" picker.
    static func interfaces() -> [WebRemoteInterface] {
        var seen = Set<String>()
        return sortedEntries().compactMap { entry in
            guard !seen.contains(entry.interface) else { return nil }
            seen.insert(entry.interface)
            return WebRemoteInterface(
                name: entry.interface,
                displayName: entry.interface,
                address: entry.address
            )
        }
    }

    /// Current IPv4 of a named interface, if it is up and non-loopback.
    static func currentIPv4(forInterface name: String) -> String? {
        interfaces().first { $0.name == name }?.address
    }

    /// Raw getifaddrs walk: every (interface, IPv4) pair that is up and not
    /// loopback, sorted by the URL/picker display priority. Single source for
    /// `localIPv4Addresses()` (dedup by address) and `interfaces()` (dedup by
    /// interface name).
    private static func sortedEntries() -> [(priority: Int, interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var values: [(priority: Int, interface: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let addressPointer = current.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }

            let interface = String(cString: current.pointee.ifa_name)
            var address = UnsafeRawPointer(addressPointer)
                .assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            values.append((priority(for: interface), interface, String(cString: buffer)))
        }

        return values.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.interface != $1.interface { return $0.interface < $1.interface }
            return $0.address < $1.address
        }
    }

    private static func priority(for interface: String) -> Int {
        if interface == "en0" { return 0 }
        if interface.hasPrefix("en") { return 1 }
        if interface.hasPrefix("utun") { return 2 }
        return 3
    }
}

/// Persisted choice of which local address the web remote binds to.
/// Stored as a string key in UserDefaults: `loopback`, `any`, or an interface
/// name (e.g. `en0`) resolved to its current IPv4 at bind time.
enum WebRemoteListenTarget {
    static let loopback = "loopback"
    static let any = "any"

    /// The IPv4 to bind, or `nil` for a wildcard listener (all interfaces).
    static func bindAddress(for key: String) -> String? {
        switch key {
        case Self.loopback: return "127.0.0.1"
        case Self.any: return nil
        default: return WebRemoteAddressResolver.currentIPv4(forInterface: key)
        }
    }
}
