// Shared plumbing: paths, running commands, crypto for pairing, LAN addresses, strings.

import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import SystemConfiguration

enum Env {
    static let version = "1.3.0"
    /// Version of the helper scripts the Mac hands out (VERSION in edgeflow-helper.py/.ps1).
    /// Separate from the app's, so an app-only release doesn't ask to update the helpers.
    static let helperVersion = "1.2.2"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dfDir = home.appendingPathComponent("Library/Deskflow")
    static let fxDir = dfDir.appendingPathComponent("fx")
    static let configURL = fxDir.appendingPathComponent("config.json")
    static let deskflowConf = dfDir.appendingPathComponent("Deskflow.conf")
    static let serverConf = dfDir.appendingPathComponent("deskflow-server.conf")
    static let tlsDir = dfDir.appendingPathComponent("tls")
    static let deskflowLog = dfDir.appendingPathComponent("deskflow.log")
    static let corePort = 24800
    static let pairPort = 24801

    /// Deskflow ships inside Edgeflow.app; an installed Deskflow.app is the fallback.
    static var deskflowApp: String {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Deskflow.app").path ?? ""
        return FileManager.default.fileExists(atPath: bundled) ? bundled : "/Applications/Deskflow.app"
    }
    static var coreBinary: String { "\(deskflowApp)/Contents/MacOS/deskflow-core" }

    /// Helper files served to the other computer during install.
    static var payloadDir: URL { Bundle.main.resourceURL!.appendingPathComponent("payload") }

    /// The Mac's Deskflow screen name (its Bonjour host name, e.g. "HSIANGdeMacBook-Air").
    static var macScreen: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }
    static var macHost: String { "\(macScreen).local" }
}

@discardableResult
func sh(_ path: String, _ args: [String], env: [String: String]? = nil, input: String? = nil,
        timeout: TimeInterval = 15) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    let inPipe = Pipe()
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    var data = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        lock.lock(); data.append(d); lock.unlock()
    }
    do { try p.run() } catch { return (-1, "\(error)") }
    if let input {
        inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(30_000) }
    if p.isRunning { p.terminate(); usleep(100_000) }
    pipe.fileHandleForReading.readabilityHandler = nil
    lock.lock(); data.append(pipe.fileHandleForReading.readDataToEndOfFile()); lock.unlock()
    let out = String(data: data, encoding: .utf8) ?? ""
    return (p.isRunning ? -2 : p.terminationStatus, out)
}

// MARK: - Crypto

enum Crypto {
    static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ s: String) -> Data { Data(SHA256.hash(data: Data(s.utf8))) }

    static func hmacHex(key: Data, _ message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// AES-256-CBC + PKCS7, the cipher both `openssl enc` and .NET Framework can undo.
    static func aesCBC(_ plain: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            plain.withUnsafeBytes { p in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, p.baseAddress, plain.count,
                                o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// Sealed pairing bundle: "<iv hex>\n<ciphertext base64>\n<hmac hex>".
    /// enc key = SHA256("enc:"+secret), mac key = SHA256("mac:"+secret), HMAC over the base64 text.
    static func seal(_ json: Data, secret: String) -> String? {
        let iv = Data(randomHex(16).hexBytes)
        guard let ct = aesCBC(json, key: sha256("enc:" + secret), iv: iv) else { return nil }
        let b64 = ct.base64EncodedString()
        return "\(iv.hex)\n\(b64)\n\(hmacHex(key: sha256("mac:" + secret), b64))\n"
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension String {
    var hexBytes: [UInt8] {
        var out: [UInt8] = []
        var i = startIndex
        while i < endIndex, let j = index(i, offsetBy: 2, limitedBy: endIndex) {
            if let b = UInt8(self[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }
}

// MARK: - Network

enum Net {
    /// IPv4 of the active Wi-Fi/Ethernet interface (en0, en1…), skipping link-local and VPN tunnels.
    static func lanIPv4() -> String? { lanInterface()?.ip }

    /// The network the Mac is on, told apart by its router's hardware address (the Wi-Fi name
    /// would need Location permission). `id` is nil when the router's address can't be read.
    static func network() -> (router: String, id: String?)? {
        guard let ifc = lanInterface() else { return nil }
        var router = sh("/usr/sbin/ipconfig", ["getoption", ifc.name, "router"], timeout: 2).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if router.split(separator: ".").count != 4 {   // set up by hand, not DHCP
            let r = sh("/sbin/route", ["-n", "get", "-ifscope", ifc.name, "default"], timeout: 2).out
            router = r.split(separator: "\n").first { $0.contains("gateway:") }
                .map { $0.split(separator: ":").last.map(String.init) ?? "" }?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        guard router.split(separator: ".").count == 4 else { return nil }
        func lookup() -> String? {
            let out = sh("/usr/sbin/arp", ["-n", router], timeout: 2).out
            guard let at = out.range(of: " at ") else { return nil }
            let parts = out[at.upperBound...].split(separator: " ").first?.split(separator: ":") ?? []
            guard parts.count == 6, parts.allSatisfy({ UInt8($0, radix: 16) != nil }) else { return nil }
            return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
        }
        if let id = lookup() { return (router, id) }
        _ = sh("/sbin/ping", ["-c", "1", "-t", "1", router], timeout: 2)   // fills the ARP table
        return (router, lookup())
    }

    static func lanInterface() -> (name: String, ip: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: (name: String, ip: String)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en"), (a.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            if name == "en0" { return (name, ip) }
            best = best ?? (name, ip)
        }
        return best
    }

    static func sameSubnet24(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "."), pb = b.split(separator: ".")
        return pa.count == 4 && pb.count == 4 && pa.prefix(3) == pb.prefix(3)
    }

    /// Non-blocking TCP connect with a timeout. True only if the port accepts.
    static func tcp(_ ip: String, _ port: UInt16, timeoutMs: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return false }
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, timeoutMs) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// Quick TCP probe (used for "is SSH on?").
    static func portOpen(_ host: String, _ port: Int, timeout: TimeInterval = 1.2) -> Bool {
        sh("/usr/bin/nc", ["-z", "-G", "\(Int(max(1, timeout)))", host, "\(port)"], timeout: timeout + 1).status == 0
    }
}

// MARK: - Strings

enum L10n {
    static let lang: String = {
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return pref.hasPrefix("zh") ? "zh" : "en"
    }()
    static func t(_ key: String, _ args: [String: String] = [:]) -> String {
        var s = (lang == "zh" ? L10nTable.zh : L10nTable.en)[key] ?? L10nTable.en[key] ?? key
        for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }
}

func T(_ key: String, _ args: [String: String] = [:]) -> String { L10n.t(key, args) }
