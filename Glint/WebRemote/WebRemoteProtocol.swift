import CryptoKit
import Darwin
import Foundation
import Security

enum WebRemoteTerminalSnapshotResult {
    case success(WebRemoteTerminalSnapshot)
    case failure(String)
}

struct WebRemoteTerminalSnapshot {
    let payload: Data
    let outputSequence: UInt64
}

enum WebRemoteOpenProjectResult {
    case success(UUID)
    case failure(String)
}

enum WebRemoteCreateTerminalResult {
    case success(String)
    case failure(String)
}

enum WebRemoteCloseTerminalResult: Equatable {
    case success
    case confirmationRequired
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

    static func make(ansi: String?, state: WebRemoteTerminalState? = nil) -> Data {
        let terminalANSI = ansi?.replacingOccurrences(of: "\n", with: "\r\n") ?? ""
        guard let state else { return Data((resetScreen + terminalANSI).utf8) }

        var payload = state.activeScreen == .alternate ? "\u{1b}[?1049h" : ""
        payload += resetScreen
        payload += terminalANSI

        for mode in state.modes where mode.code > 0 {
            payload += "\u{1b}["
            if !mode.ansi { payload += "?" }
            payload += "\(mode.code)\(mode.on ? "h" : "l")"
        }

        let region = state.scrollingRegion
        if let region, region.isValid(columns: state.columns, rows: state.rows) {
            if region.top != 0 || region.bottom != state.rows - 1 {
                payload += "\u{1b}[\(region.top + 1);\(region.bottom + 1)r"
            }
            if region.left != 0 || region.right != state.columns - 1 {
                payload += "\u{1b}[\(region.left + 1);\(region.right + 1)s"
            }
        }

        let originMode = state.modes.contains { !$0.ansi && $0.code == 6 && $0.on }
        let cursorRow = originMode ? state.cursor.row - (region?.top ?? 0) : state.cursor.row
        let cursorColumn = originMode ? state.cursor.column - (region?.left ?? 0) : state.cursor.column
        payload += "\u{1b}[\(max(cursorRow, 0) + 1);\(max(cursorColumn, 0) + 1)H"
        payload += state.cursor.style.sequence(blinking: state.cursor.blinking)
        payload += state.cursor.visible ? "\u{1b}[?25h" : "\u{1b}[?25l"
        return Data(payload.utf8)
    }
}

struct WebRemoteTerminalState: Equatable {
    enum Screen: String {
        case primary
        case alternate
    }

    struct Mode: Equatable {
        let code: Int
        let ansi: Bool
        let on: Bool
    }

    struct ScrollingRegion: Equatable {
        let top: Int
        let bottom: Int
        let left: Int
        let right: Int

        func isValid(columns: Int, rows: Int) -> Bool {
            columns > 0 && rows > 0
                && top >= 0 && top <= bottom && bottom < rows
                && left >= 0 && left <= right && right < columns
        }
    }

    struct Cursor: Equatable {
        enum Style: String {
            case bar
            case block
            case underline
            case blockHollow = "block_hollow"

            func sequence(blinking: Bool) -> String {
                let code: Int
                switch self {
                case .block, .blockHollow: code = blinking ? 1 : 2
                case .underline: code = blinking ? 3 : 4
                case .bar: code = blinking ? 5 : 6
                }
                return "\u{1b}[\(code) q"
            }
        }

        let row: Int
        let column: Int
        let visible: Bool
        let style: Style
        let blinking: Bool
    }

    let columns: Int
    let rows: Int
    let activeScreen: Screen
    let modes: [Mode]
    let scrollingRegion: ScrollingRegion?
    let cursor: Cursor
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
        return WebRemoteCrypto.constantTimeEquals(Data(provided.utf8), Data(expected.utf8))
    }
}

/// End-to-end crypto for the web remote. The access token never crosses the
/// wire: the browser proves it knows the token with an HMAC challenge-response,
/// and both sides derive per-direction AES-256-GCM keys from (token, challenge)
/// via HKDF. Everything after the handshake is encrypted, so a passive sniffer
/// on the LAN sees only the random challenge and the proof — not the token, not
/// terminal content, not project paths.
///
/// Threat model: defends against *passive* sniffing only. Not forward-secret
/// (the session key derives from the long-lived token). Matches the JS client's
/// vendored `crypto.mjs` byte-for-byte: HMAC-SHA256, HKDF (extract+expand),
/// AES-256-GCM with the 16-byte tag appended to the ciphertext.
enum WebRemoteCrypto {
    static let nonceLength = 12       // AES-GCM standard nonce
    static let tagLength = 16         // AES-GCM authentication tag
    static let challengeLength = 32
    static let keyLength = 32         // AES-256

    /// Domain-separation labels shared with the client.
    private static let proofLabel = Data("glint-webremote/v1/proof".utf8)
    private static let sessionInfo = Data("glint-webremote/v1/session".utf8)
    private static let c2sInfo = Data("c2s".utf8)
    private static let s2cInfo = Data("s2c".utf8)

    /// Constant-time equality for secrets (proofs / tokens). Length differences
    /// are folded into the accumulator so timing doesn't leak the length.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        let count = max(left.count, right.count)
        for index in 0 ..< count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }

    /// Decode the 64-char lowercase-hex token into its 32 raw bytes. Returns nil
    /// for anything that isn't exactly 64 lowercase hex digits.
    static func tokenKey(from token: String) -> Data? {
        guard token.count == 64,
              token.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(keyLength)
        var index = token.startIndex
        while index < token.endIndex {
            let next = token.index(index, offsetBy: 2)
            guard let byte = UInt8(token[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// A fresh per-connection random challenge.
    static func newChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: challengeLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max)
            }
        }
        return Data(bytes)
    }

    /// Proof of knowledge of `tokenKey` for `challenge`, without revealing the
    /// token. `proof = HMAC-SHA256(tokenKey, "…/proof" || challenge)`.
    static func proof(tokenKey: Data, challenge: Data) -> Data {
        var message = proofLabel
        message.append(challenge)
        let mac = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: tokenKey)
        )
        return Data(mac)
    }

    /// Per-direction AES-256 keys derived from (tokenKey, challenge).
    /// `sessionKey = HKDF(tokenKey, salt: challenge, info: session)` then
    /// `c2s`/`s2c = HKDF-Expand(sessionKey, info, 32)`.
    static func sessionKeys(
        tokenKey: Data,
        challenge: Data
    ) -> (c2s: SymmetricKey, s2c: SymmetricKey) {
        let session = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: tokenKey),
            salt: challenge,
            info: sessionInfo,
            outputByteCount: keyLength
        )
        let c2s = HKDF<SHA256>.expand(
            pseudoRandomKey: session,
            info: c2sInfo,
            outputByteCount: keyLength
        )
        let s2c = HKDF<SHA256>.expand(
            pseudoRandomKey: session,
            info: s2cInfo,
            outputByteCount: keyLength
        )
        return (c2s, s2c)
    }

    /// 12-byte GCM nonce for a per-direction message counter: 4 zero bytes
    /// followed by the 8-byte big-endian counter. Keys are direction-split, so
    /// counters only need uniqueness within one direction — never collide.
    static func nonce(for counter: UInt64) -> Data {
        var nonce = Data(count: nonceLength)
        nonce.withUnsafeMutableBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var bigEndian = counter.bigEndian
            withUnsafeBytes(of: &bigEndian) { counterBytes in
                for index in 0 ..< MemoryLayout<UInt64>.size {
                    bytes[nonceLength - MemoryLayout<UInt64>.size + index] = counterBytes[index]
                }
            }
        }
        return nonce
    }

    /// Inverse of `nonce(for:)`: read the counter back out of a 12-byte nonce.
    /// Used by the receiver's replay guard.
    static func counter(fromNonce nonce: Data) -> UInt64? {
        guard nonce.count == nonceLength else { return nil }
        var value: UInt64 = 0
        for index in 0 ..< MemoryLayout<UInt64>.size {
            value <<= 8
            value |= UInt64(nonce[nonceLength - MemoryLayout<UInt64>.size + index])
        }
        return value
    }

    /// Encrypt `plaintext` into a full frame: `nonce(12) || ciphertext || tag`.
    /// The 16-byte tag is appended to the ciphertext, matching the client's
    /// vendored noble gcm layout. nil only on a malformed nonce, which the
    /// counter encoding can't produce — callers treat nil as fatal.
    static func sealFrame(plaintext: Data, key: SymmetricKey, counter: UInt64) -> Data? {
        let nonce = self.nonce(for: counter)
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce),
              let sealed = try? AES.GCM.seal(plaintext, using: key, nonce: gcmNonce)
        else { return nil }
        var frame = Data(capacity: nonceLength + sealed.ciphertext.count + tagLength)
        frame.append(nonce)
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        return frame
    }

    /// Decrypt a frame body (the bytes after the 12-byte nonce): `ciphertext ||
    /// tag`, authenticated under the supplied nonce. nil on any failure
    /// (truncated frame, nonce shape, auth-tag mismatch) — callers drop.
    static func openFrame(nonce: Data, body: Data, key: SymmetricKey) -> Data? {
        guard nonce.count == nonceLength,
              body.count > tagLength,
              let gcmNonce = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: body.prefix(body.count - tagLength),
                tag: body.suffix(tagLength)
              ),
              let plaintext = try? AES.GCM.open(box, using: key)
        else { return nil }
        return plaintext
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

    /// The URL with the access-token fragment stripped, so copying or sharing
    /// the link never leaks the secret in plaintext. The token must travel
    /// out-of-band (the "Access key" field); a browser opening this redacted
    /// URL prompts for the key via the auth dialog.
    static func redacted(from value: String) -> String {
        guard var comps = URLComponents(string: value) else { return value }
        comps.fragment = nil
        return comps.string ?? value
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
        case "/crypto.mjs":
            WebRemoteAsset(
                resource: "crypto",
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
