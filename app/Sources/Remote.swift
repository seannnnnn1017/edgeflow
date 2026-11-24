// Finding computers on the LAN (Bonjour) and installing over SSH with a password.

import Foundation

struct Found: Identifiable, Equatable {
    var id: String { ip }
    var name: String
    var os: String          // linux | windows | ""
    var osv: String
    var ip: String
    var ssh: Bool
}

/// Browses Bonjour for computers that announce themselves (Linux with Avahi, anything with
/// SSH, and computers that already run the Edgeflow helper). Windows rarely announces
/// itself, so the wizard also takes a typed IP.
final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private static let types = ["_edgeflow._tcp.", "_workstation._tcp.", "_ssh._tcp.", "_sftp-ssh._tcp.", "_rdp._tcp."]
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var found: [String: Found] = [:]
    private(set) var searching = false
    var onUpdate: (([Found], Bool) -> Void)?
    var onLocalNetwork: ((Bool) -> Void)?

    private var scanning = false
    private var browseDone = false

    func start() {
        stop()
        found.removeAll()
        searching = true
        scanning = true
        browseDone = false
        for t in Self.types {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: t, inDomain: "local.")
            browsers.append(b)
        }
        report()
        DispatchQueue.global(qos: .userInitiated).async { self.scan() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.browseDone = true; self?.finish() }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        services.forEach { $0.stop() }
        services.removeAll()
    }

    private func finish() {
        guard searching, browseDone, !scanning else { return }
        searching = false
        stop()
        report()
    }

    // MARK: active scan
    // Most computers never announce themselves (Windows doesn't use Bonjour; Ubuntu's Avahi
    // doesn't publish a workstation by default), so also sweep the Mac's /24: a connection
    // attempt to every address fills the ARP table, then each live host is identified by its
    // mDNS name (Linux), its Windows ports + NetBIOS name, and whether SSH answers.

    private func scan() {
        defer { DispatchQueue.main.async { self.scanning = false; self.finish() } }
        guard let me = Net.lanIPv4() else { return }
        let net = me.split(separator: ".").prefix(3).joined(separator: ".")
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 128
        for i in 1...254 where "\(net).\(i)" != me {
            q.addOperation { _ = Net.tcp("\(net).\(i)", 445, timeoutMs: 700) }
        }
        q.waitUntilAllOperationsAreFinished()
        let arp = sh("/usr/sbin/arp", ["-an"], timeout: 5).out
        let live = arp.split(separator: "\n").compactMap { line -> String? in
            guard !line.contains("incomplete"), let l = line.firstIndex(of: "("), let r = line.firstIndex(of: ")") else { return nil }
            let ip = String(line[line.index(after: l)..<r])
            return ip.hasPrefix(net + ".") && ip != me && !ip.hasSuffix(".255") && !ip.hasSuffix(".1") ? ip : nil
        }
        for ip in live { q.addOperation { self.identify(ip) } }
        q.waitUntilAllOperationsAreFinished()
    }

    private func identify(_ ip: String) {
        let port = { (p: UInt16) in Net.tcp(ip, p, timeoutMs: 700) }
        if port(62078) { return }                                   // iPhone / iPad
        let windows = port(445) || port(135)
        let ssh = port(22)
        var name = "", os = "", osv = ""
        if windows {
            let out = sh("/usr/bin/smbutil", ["status", ip], timeout: 4).out
            name = out.split(separator: "\n").first { $0.hasPrefix("Server:") }
                .map { $0.dropFirst(7).trimmingCharacters(in: .whitespaces) } ?? ""
            os = "windows"; osv = "Windows"
        } else {
            let out = sh("/usr/bin/dig", ["-x", ip, "@224.0.0.251", "-p", "5353", "+short", "+time=1", "+tries=1"], timeout: 4).out
            name = out.split(separator: "\n").first { !$0.hasPrefix(";") && !$0.isEmpty }
                .map { $0.replacingOccurrences(of: ".local.", with: "").replacingOccurrences(of: ".", with: "") } ?? ""
            if name.isEmpty && !ssh { return }                       // nothing that looks like a computer
            if port(7000) && !ssh { return }                         // AirPlay: Apple TV, speakers, Macs
            if name.lowercased().contains("macbook") || name.lowercased().contains("imac") || name.lowercased().contains("iphone") { return }
            os = "linux"; osv = "Linux"
        }
        if name.isEmpty { name = ip }
        let f = Found(name: name, os: os, osv: osv, ip: ip, ssh: ssh)
        DispatchQueue.main.async {
            if var old = self.found[ip] { old.ssh = old.ssh || ssh; if old.os.isEmpty { old.os = os; old.osv = osv }; self.found[ip] = old }
            else { self.found[ip] = f }
            self.report()
        }
    }

    private func report() { onUpdate?(found.values.sorted { $0.name < $1.name }, searching) }

    func netServiceBrowser(_ b: NetServiceBrowser, didFind s: NetService, moreComing: Bool) {
        services.append(s)
        s.delegate = self
        s.resolve(withTimeout: 4)
        onLocalNetwork?(true)
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // -72008 = kDNSServiceErr_PolicyDenied: Local Network access was refused
        if errorDict[NetService.errorCode]?.intValue == -72008 { onLocalNetwork?(false) }
    }

    func netServiceDidResolveAddress(_ s: NetService) {
        guard let ip = s.addresses?.compactMap(ipv4).first else { return }
        let host = (s.hostName ?? s.name).replacingOccurrences(of: ".local.", with: "").replacingOccurrences(of: ".local", with: "")
        if host.caseInsensitiveCompare(Env.macScreen) == .orderedSame || ip == Net.lanIPv4() { return }
        var f = found[ip] ?? Found(name: host, os: "", osv: "", ip: ip, ssh: false)
        if s.type.hasPrefix("_ssh") || s.type.hasPrefix("_sftp") { f.ssh = true }
        if s.type.hasPrefix("_workstation") { f.os = "linux"; f.osv = f.osv.isEmpty ? "Linux" : f.osv }
        if s.type.hasPrefix("_rdp") { f.os = "windows"; f.osv = "Windows" }
        if s.type.hasPrefix("_edgeflow"), let txt = s.txtRecordData() {
            let d = NetService.dictionary(fromTXTRecord: txt)
            if let o = d["os"] { f.os = String(decoding: o, as: UTF8.self) }
            if let v = d["osv"] { f.osv = String(decoding: v, as: UTF8.self) }
        }
        found[ip] = f
        report()
    }

    private func ipv4(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
    }
}

/// SSH with a typed password: OpenSSH reads it from an SSH_ASKPASS helper that echoes an
/// environment variable, so the password never lands on disk or in a command line.
enum SSHInstall {
    enum TestResult: Equatable { case ok(os: String, osv: String, name: String), wrongPassword, unreachable, noSSH }

    private static let askpass: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("edgeflow-askpass.sh")
        try? "#!/bin/sh\nprintf '%s\\n' \"$EF_SSH_PASS\"\n".write(to: u, atomically: true, encoding: .utf8)
        chmod(u.path, 0o700)
        return u
    }()

    static func run(host: String, user: String, pass: String, command: String, input: String? = nil,
                    timeout: TimeInterval = 20) -> (status: Int32, out: String) {
        let env = ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": "edgeflow", "EF_SSH_PASS": pass]
        let target = user.isEmpty ? host : "\(user)@\(host)"
        return sh("/usr/bin/ssh", ["-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=6",
                                   "-o", "NumberOfPasswordPrompts=1", "-o", "BatchMode=no",
                                   "-o", "PreferredAuthentications=publickey,keyboard-interactive,password",
                                   target, command], env: env, input: input, timeout: timeout)
    }

    static func classify(_ out: String) -> TestResult? {
        let o = out.lowercased()
        if o.contains("permission denied") || o.contains("too many authentication") { return .wrongPassword }
        if o.contains("connection refused") { return .noSSH }
        if o.contains("timed out") || o.contains("no route") || o.contains("could not resolve") || o.contains("unreachable") { return .unreachable }
        return nil
    }

    static func test(host: String, user: String, pass: String) -> TestResult {
        if !Net.portOpen(host, 22, timeout: 3) {
            return sh("/sbin/ping", ["-c", "1", "-t", "2", host], timeout: 4).status == 0 ? .noSSH : .unreachable
        }
        // `echo %OS%` prints Windows_NT in cmd.exe and the literal text in a POSIX shell.
        let probe = run(host: host, user: user, pass: pass, command: "echo %OS%")
        if probe.status != 0 { return classify(probe.out) ?? .unreachable }
        if probe.out.contains("Windows_NT") {
            let r = run(host: host, user: user, pass: pass,
                        command: "powershell -NoProfile -Command \"(Get-CimInstance Win32_OperatingSystem).Caption; hostname\"")
            let l = r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let osv = (l.first ?? "Windows").replacingOccurrences(of: "Microsoft ", with: "")
            return .ok(os: "windows", osv: osv, name: l.last ?? host)
        }
        let r = run(host: host, user: user, pass: pass, command: ". /etc/os-release 2>/dev/null; echo \"${PRETTY_NAME:-Linux}\"; hostname")
        let l = r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let osv = (l.first ?? "Linux").replacingOccurrences(of: " LTS", with: "")
        return .ok(os: "linux", osv: osv, name: l.last ?? host)
    }

    /// Runs the same one-line installer a person would paste. On Linux the password is also
    /// handed to `sudo` through stdin, in case Flatpak still has to be installed.
    static func install(host: String, user: String, pass: String, os: String, command: String) -> (status: Int32, out: String) {
        if os == "windows" {
            let utf16 = command.data(using: .utf16LittleEndian)!.base64EncodedString()
            return run(host: host, user: user, pass: pass, command: "powershell -NoProfile -EncodedCommand \(utf16)", timeout: 900)
        }
        return run(host: host, user: user, pass: pass,
                   command: "IFS= read -r EF_SUDO_PASS; export EF_SUDO_PASS; \(command)", input: pass + "\n", timeout: 900)
    }
}
