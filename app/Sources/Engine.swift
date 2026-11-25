// The app's brain: settings, the Deskflow server, pairing, status, permissions.

import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

enum LinkStatus: Equatable {
    case connected(String), controlling(String), waiting(String), offnet, noperm, paused, portbusy, none

    var dot: NSColor {
        switch self {
        case .connected, .controlling: return .systemGreen
        case .waiting, .offnet, .portbusy: return .systemOrange
        case .noperm: return .systemRed
        case .paused, .none: return .systemGray
        }
    }
    var pulses: Bool { if case .connected = self { return true }; if case .controlling = self { return true }; return false }
    var needsAttention: Bool { self == .noperm || self == .portbusy }
}

enum SyncStatus: Equatable { case loading, syncing, ok(Date), fail(String) }
enum PermState: String { case none, wait, ok, deny }

/// Live, non-persisted facts about a paired computer, reported by its helper.
struct DeviceLive { var lastSeen: Date; var helperVersion: String; var configVersion: String; var ip: String }

final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var config: FXConfig { didSet { if config != oldValue { configChanged(from: oldValue) } } }
    @Published var status: LinkStatus = .none
    @Published var macIP = Net.lanIPv4() ?? ""
    @Published var sync: SyncStatus = .loading
    @Published var live: [String: DeviceLive] = [:]
    @Published var perms: [String: PermState] = ["ax": .none, "lan": .none, "desk": .none, "login": .none]
    @Published var found: [Found] = []
    @Published var searching = false
    @Published var session: PairSession?
    @Published var sessionTick = 0            // bumps whenever the session changes
    @Published var toast: String?
    @Published var crossings: [(from: String, to: String, at: Date)] = []
    @Published var portBusyBy: String?
    @Published var peers: Set<String> = []     // IPs with an open Deskflow connection right now

    let core = CoreRunner()
    let charge = ChargeWatcher()
    let clipboard = ClipboardBridge()
    let logs = LogWatcher()
    let discovery = Discovery()
    let http = HTTPServer()
    private let work = DispatchQueue(label: "edgeflow.work")
    private var pending: DispatchWorkItem?
    private var commands: [String: [String]] = [:]
    private var wavHashes: [String: String] = [:]
    private var configVersion = ""
    private var changedAt = Date()
    private var preview: NSSound?
    private var timer: Timer?

    var trusted: Bool { perms["ax"] == .ok }
    var macScreen: String { Env.macScreen }

    private init() {
        let cfg = (try? Data(contentsOf: Env.configURL)).flatMap { try? JSONDecoder().decode(FXConfig.self, from: $0) } ?? FXConfig()
        config = cfg
        perms["ax"] = AXIsProcessTrusted() ? .ok : .none
        perms["login"] = SMAppService.mainApp.status == .enabled ? .ok : .none
        if UserDefaults.standard.bool(forKey: "lanOK") { perms["lan"] = .ok }

        sh("/usr/bin/pkill", ["-f", "Deskflow.app/Contents/MacOS/"])   // a Deskflow window or old core would hold the port
        // Deskflow runs the edge effect from a fixed path; keep it in step with the app's copy
        if let src = Bundle.main.resourceURL?.appendingPathComponent("edge-fx"), FileManager.default.fileExists(atPath: src.path) {
            let dst = Env.fxDir.appendingPathComponent("edge-fx")
            try? FileManager.default.createDirectory(at: Env.fxDir, withIntermediateDirectories: true)
            if (try? Data(contentsOf: src)) != (try? Data(contentsOf: dst)) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
        writeLocal(cfg)
        DeskflowConf.write(cfg)
        applyRuntime(cfg)

        charge.start()
        clipboard.onDesktopAccess = { [weak self] ok in DispatchQueue.main.async { self?.perms["desk"] = ok ? .ok : .deny } }
        if cfg.setupDone { clipboard.start() }
        logs.onChange = { [weak self] in self?.refreshStatus() }
        logs.onSwitch = { [weak self] a, b in
            DispatchQueue.main.async { self?.crossings.append((a, b, Date())); if (self?.crossings.count ?? 0) > 20 { self?.crossings.removeFirst() } }
        }
        logs.start()
        discovery.onUpdate = { [weak self] f, s in self?.found = f; self?.searching = s }
        discovery.onLocalNetwork = { [weak self] ok in
            self?.perms["lan"] = ok ? .ok : .deny
            if ok { UserDefaults.standard.set(true, forKey: "lanOK") }
        }
        http.handler = { [weak self] r in self?.route(r) ?? .notFound }
        http.start(port: Env.pairPort)

        if trusted && !cfg.paused { core.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.sync = .ok(Date()) }
    }

    // MARK: settings

    private func configChanged(from old: FXConfig) {
        applyRuntime(config)
        save()
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.apply() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func applyRuntime(_ c: FXConfig) {
        charge.enabled = c.chargeSound && c.soundEnabled && c.delay >= 0.05 && !c.paused
        charge.keepIfHeld = max(0.08, c.delay * 0.8)
        charge.volume = Float(c.volume)
        charge.sides = Set(c.computers.map(\.side))
        clipboard.enabled = c.clipboard
        clipboard.screenshots = c.screenshotToClipboard
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Env.fxDir, withIntermediateDirectories: true)
        if let d = try? enc.encode(config) { try? d.write(to: Env.configURL) }
    }

    /// Sounds, Deskflow files, and (when needed) a core restart; helpers pick the rest up on their next poll.
    private func apply() {
        let cfg = config
        sync = cfg.computers.isEmpty ? .ok(Date()) : .syncing
        changedAt = Date()
        work.async {
            self.writeLocal(cfg)
            DispatchQueue.main.async { self.charge.reloadSound() }
            if DeskflowConf.write(cfg) && self.trusted && !cfg.paused { self.logs.reset(); self.core.restart() }
        }
    }

    private func writeLocal(_ cfg: FXConfig) {
        try? FileManager.default.createDirectory(at: Env.fxDir, withIntermediateDirectories: true)
        let s = Synth.render(cfg.soundTheme, delay: cfg.delay)
        for (n, d) in [("enter.wav", s.enter), ("return.wav", s.back), ("charge.wav", s.charge)] {
            try? d.write(to: Env.fxDir.appendingPathComponent(n))
            wavHashes[n] = Crypto.sha256Hex(d)
        }
        configVersion = Crypto.sha256Hex(Data("\(cfg)".utf8)).prefix(12).description
    }

    // MARK: status

    private func tick() {
        if !trusted && AXIsProcessTrusted() { perms["ax"] = .ok; if !config.paused { core.start() } }
        if trusted && !AXIsProcessTrusted() { perms["ax"] = .none }
        macIP = Net.lanIPv4() ?? ""
        refreshPeers()
        if let s = session, s.isExpired { s.state = .expired; sessionTick += 1 }
        refreshStatus()
        refreshSync()
    }

    /// Deskflow logs "client … has connected" only at debug level, so also look at the
    /// established TCP connections on its port.
    private func refreshPeers() {
        work.async {
            let out = sh("/usr/sbin/lsof", ["-nP", "-iTCP:\(Env.corePort)", "-sTCP:ESTABLISHED"], timeout: 3).out
            let ips = Set(out.split(separator: "\n").compactMap { l -> String? in
                guard l.hasPrefix("deskflow"), let arrow = l.range(of: "->") else { return nil }
                return l[arrow.upperBound...].split(separator: ":").first.map(String.init)
            })
            DispatchQueue.main.async { if ips != self.peers { self.peers = ips; self.refreshStatus() } }
        }
    }

    func refreshStatus() {
        DispatchQueue.main.async { [self] in
            let cs = config.computers
            let s: LinkStatus
            if !trusted { s = .noperm }
            else if config.paused { s = .paused }
            else if !core.isRunning, let by = portOwner() { portBusyBy = by; s = .portbusy }
            else if cs.isEmpty { s = .none }
            else if let a = logs.activeScreen, let c = cs.first(where: { $0.screen == a }) { s = .controlling(c.name) }
            else if let c = cs.first(where: { isOnline($0) }) { s = .connected(c.name) }
            else if let c = cs.first, !macIP.isEmpty, !c.ip.isEmpty, !Net.sameSubnet24(c.ip, macIP) { s = .offnet }
            else { s = .waiting(cs.first!.name) }
            if s != status { status = s }
        }
    }

    private func portOwner() -> String? {
        guard let exit = core.lastExit, Date().timeIntervalSince(exit) < 10 else { return nil }
        let out = sh("/usr/sbin/lsof", ["-nP", "-iTCP:\(Env.corePort)", "-sTCP:LISTEN"], timeout: 3).out
        return out.split(separator: "\n").dropFirst().first.map { String($0.split(separator: " ").first ?? "") }
    }

    private func refreshSync() {
        guard case .syncing = sync else { return }
        let withHelper = config.computers.filter { live[$0.id] != nil }
        if withHelper.allSatisfy({ live[$0.id]?.configVersion == configVersion }) { sync = .ok(Date()); return }
        if Date().timeIntervalSince(changedAt) > 15, let c = withHelper.first(where: { live[$0.id]?.configVersion != configVersion }) {
            sync = .fail(c.name)
        }
    }

    func computer(_ id: String) -> Computer? { config.computers.first { $0.id == id } }
    func isOnline(_ c: Computer) -> Bool {
        logs.connected.contains(c.screen) || peers.contains(live[c.id]?.ip ?? c.ip) || peers.contains(c.ip)
    }
    func helperOutdated(_ c: Computer) -> Bool {
        guard let v = live[c.id]?.helperVersion ?? c.helperVersion else { return true }
        return v.compare(Env.version, options: .numeric) == .orderedAscending
    }

    // MARK: actions

    func say(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if self.toast == s { self.toast = nil } }
    }

    func reconnect() {
        say(T("t_reconnect"))
        logs.reset()
        work.async {
            DeskflowConf.write(self.config)
            if self.trusted && !self.config.paused { self.core.restart() }
        }
        for c in config.computers { commands[c.id, default: []].append("restart") }
    }

    func setPaused(_ p: Bool) {
        config.paused = p
        if p { core.stop(); logs.reset() } else if trusted { core.start() }
        refreshStatus()
    }

    func freePort() {
        sh("/usr/bin/pkill", ["-f", "Deskflow.app/Contents/MacOS/"])
        if let by = portBusyBy { sh("/usr/bin/pkill", ["-x", by]) }
        portBusyBy = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.core.start(); self.say(T("t_fixed")) }
    }

    func play(_ which: String) {
        let s = Synth.render(config.soundTheme, delay: config.delay)
        preview?.stop()
        preview = NSSound(data: which == "enter" ? s.enter : which == "back" ? s.back : s.charge)
        preview?.volume = Float(config.volume)
        preview?.play()
    }

    func previewMac() {
        let p = Process()
        p.executableURL = Env.fxDir.appendingPathComponent("edge-fx")
        p.arguments = [Env.fxDir.appendingPathComponent("return.wav").path, config.computers.first?.side.rawValue ?? "top"]
        try? p.run()
    }

    func previewRemote() {
        guard let c = config.computers.first else { return }
        commands[c.id, default: []].append("preview")
        say(T("t_rem", ["name": c.name]))
    }

    func reinstallHelper(_ c: Computer) {
        commands[c.id, default: []].append("update")
        say(T("t_reinstall"))
    }

    func remove(_ c: Computer) {
        commands[c.id, default: []].append("uninstall")
        let fp = c.fingerprint
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {   // let its helper fetch the uninstall first
            self.config.computers.removeAll { $0.id == c.id }
            if !fp.isEmpty {
                let tc = Env.tlsDir.appendingPathComponent("trusted-clients")
                let kept = ((try? String(contentsOf: tc, encoding: .utf8)) ?? "").split(separator: "\n").filter { !$0.hasSuffix(fp) }
                try? (kept.joined(separator: "\n") + "\n").write(to: tc, atomically: true, encoding: .utf8)
            }
        }
        say(T("t_removed", ["name": c.name]))
    }

    func update(_ id: String, _ change: (inout Computer) -> Void) {
        guard let i = config.computers.firstIndex(where: { $0.id == id }) else { return }
        change(&config.computers[i])
    }

    /// Slide the Mac along a multi-screen computer's edge (see Computer.edgeRange).
    func setEdgeStart(_ id: String, _ start: Double) {
        update(id) { $0.edgeStart = start }
    }

    /// Put a computer on a side; whoever was there swaps to the old spot.
    func place(_ id: String, _ side: Side) {
        guard let i = config.computers.firstIndex(where: { $0.id == id }) else { return }
        let old = config.computers[i].side
        if let j = config.computers.firstIndex(where: { $0.side == side && $0.id != id }) { config.computers[j].side = old }
        config.computers[i].side = side
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        perms["login"] = SMAppService.mainApp.status == .enabled ? .ok : .none
    }

    // MARK: permissions (wizard step 2)

    func requestPermission(_ k: String) {
        perms[k] = .wait
        switch k {
        case "ax":
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(opts) { perms["ax"] = .ok } else { openAccessibilitySettings() }
        case "lan":
            discovery.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.perms["lan"] == .wait { self.perms["lan"] = .ok; UserDefaults.standard.set(true, forKey: "lanOK") }
            }
        case "desk":
            clipboard.start()
            if perms["desk"] == .wait { perms["desk"] = clipboard.watchShots() ? .ok : .deny }
        case "login":
            setLaunchAtLogin(true)
        default: break
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func finishSetup() {
        config.setupDone = true
        clipboard.start()
        if trusted && !config.paused { core.start() }
    }

    // MARK: pairing

    func newSession(os: String, viaSSH: Bool = false) -> PairSession {
        let s = PairSession(os: os)
        s.viaSSH = viaSSH
        session = s
        sessionTick += 1
        return s
    }

    func sessionChanged() { DispatchQueue.main.async { self.sessionTick += 1 } }

    /// Remote install over SSH: runs the same command a person would paste.
    func installOverSSH(host: String, user: String, pass: String, os: String) {
        let s = newSession(os: os, viaSSH: true)
        let cmd = s.command(macIP: macIP)
        work.async {
            let r = SSHInstall.install(host: host, user: user, pass: pass, os: os, command: cmd)
            s.log.append(contentsOf: r.out.split(separator: "\n").map(String.init).suffix(40))
            if s.state == .waiting || (r.status != 0 && s.state != .done) {
                s.state = .failed
                if s.failedStep == nil { s.steps[s.steps.firstIndex(where: { $0 != .ok }) ?? 0] = .fail }
                s.failMessage = SSHInstall.classify(r.out).map { $0 == .wrongPassword ? T("sh_err_pass") : T("sh_err_unreach") } ?? ""
            }
            self.sessionChanged()
        }
    }

    private func freeSide() -> Side {
        for s: Side in [.right, .left, .top, .bottom] where config.computer(side: s) == nil { return s }
        return .right
    }

    private func uniqueScreen(_ host: String) -> String {
        var base = host.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        if base.isEmpty { base = "computer" }
        var name = base, n = 2
        while name == macScreen || config.computers.contains(where: { $0.screen == name }) { name = "\(base)-\(n)"; n += 1 }
        return name
    }

    // MARK: HTTP routes (called on the server's queue)

    private func route(_ r: HTTPRequest) -> HTTPResponse {
        let parts = r.path.split(separator: "/").map(String.init)
        guard let head = parts.first else { return .notFound }
        switch (r.method, head) {
        case ("GET", "i"), ("GET", "w"):
            guard parts.count == 2, let s = session, s.token == parts[1], !s.isExpired else { return .denied }
            return HTTPResponse(body: Payload.installer(os: head == "w" ? "windows" : "linux", url: "http://\(macIP):\(Env.pairPort)", token: s.token))
        case ("POST", "p"):
            guard parts.count == 2 else { return .notFound }
            return hello(token: parts[1], r)
        case ("POST", "s"):
            guard parts.count == 2, let s = session, s.token == parts[1] else { return .denied }
            progress(s, r.form)
            return .text("ok\n")
        case ("GET", "f"):
            guard parts.count == 2, let d = Payload.file(parts[1]) else { return .notFound }
            return HTTPResponse(type: "application/octet-stream", body: d)
        case ("GET", "c"):
            guard parts.count == 2 else { return .notFound }
            return poll(id: parts[1], r)
        case ("GET", "d"):
            guard parts.count == 3, ["enter.wav", "charge.wav"].contains(parts[2]), authorized(parts[1], r) != nil,
                  let d = try? Data(contentsOf: Env.fxDir.appendingPathComponent(parts[2])) else { return .denied }
            return HTTPResponse(type: "audio/wav", body: d)
        default:
            return .notFound
        }
    }

    private func hello(token: String, _ r: HTTPRequest) -> HTTPResponse {
        guard let s = session, s.token == token, s.state == .waiting, !s.isExpired else { return .denied }
        let f = r.form
        let pemURL = FileManager.default.temporaryDirectory.appendingPathComponent("ef-client-\(token).pem")
        guard let fp = DeskflowConf.makeIdentity(at: pemURL), let pem = try? String(contentsOf: pemURL, encoding: .utf8) else {
            return .text("identity failed\n", 500)
        }
        try? FileManager.default.removeItem(at: pemURL)
        var c: Computer!
        DispatchQueue.main.sync {
            let host = f["hostname"] ?? "computer"
            let os = f["os"] == "windows" ? "windows" : "linux"
            c = Computer(id: "d-" + Crypto.randomHex(4), name: host, screen: uniqueScreen(host), os: os,
                         osv: f["osv"] ?? (os == "windows" ? "Windows" : "Linux"), ip: r.remoteIP, icon: "desktop",
                         side: freeSide(), keys: nil, key: Crypto.randomHex(16), fingerprint: fp,
                         helperVersion: Env.version, ssh: s.viaSSH)
            config.computers.append(c)
            s.deviceId = c.id
            s.os = os
            s.state = .installing
            s.steps[0] = .ok
            s.steps[1] = .running
            sessionTick += 1
        }
        let cfg = config
        DeskflowConf.write(cfg)
        if trusted && !cfg.paused { logs.reset(); core.restart() }
        let url = "http://\(macIP):\(Env.pairPort)"
        let bundle: [String: Any] = [
            "deviceId": c.id, "deviceKey": c.key, "screen": c.screen, "name": c.name,
            "server": macIP, "serverHost": Env.macHost, "port": Env.corePort, "pairUrl": url,
            "serverFingerprint": DeskflowConf.serverFingerprint, "pem": pem,
            "files": Payload.hashes, "version": Env.version,
            "config": cfg.deviceConfig(for: c, serverIP: macIP, wavHashes: wavHashes),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys]),
              let sealed = Crypto.seal(json, secret: s.secret) else { return .text("seal failed\n", 500) }
        return .text(sealed)
    }

    private func progress(_ s: PairSession, _ f: [String: String]) {
        guard let n = Int(f["step"] ?? ""), (1...6).contains(n) else { return }
        let st: StepState = f["state"] == "ok" ? .ok : f["state"] == "fail" ? .fail : .running
        s.steps[n - 1] = st
        if st == .ok && n < 6 && s.steps[n] == .pending { s.steps[n] = .running }
        if let l = f["log"], !l.isEmpty { s.log.append(l) }
        if st == .fail { s.state = .failed; s.failMessage = f["msg"] ?? "" }
        if n == 6 && st == .ok { s.state = .done }
        sessionChanged()
    }

    private func authorized(_ id: String, _ r: HTTPRequest) -> Computer? {
        guard let c = DispatchQueue.main.sync(execute: { computer(id) }),
              let ts = Double(r.query["ts"] ?? ""), abs(Date().timeIntervalSince1970 - ts) < 86_400,
              r.query["sig"] == Crypto.hmacHex(key: Data(c.key.hexBytes), "\(id):\(r.query["ts"]!)") else { return nil }
        return c
    }

    private func poll(id: String, _ r: HTTPRequest) -> HTTPResponse {
        guard let c = authorized(id, r) else { return .denied }
        var out: [String: Any] = [:]
        DispatchQueue.main.sync {
            live[id] = DeviceLive(lastSeen: Date(), helperVersion: r.query["v"] ?? "", configVersion: r.query["cv"] ?? "", ip: r.remoteIP)
            if c.ip != r.remoteIP && !r.remoteIP.isEmpty { update(id) { $0.ip = r.remoteIP } }
            if let v = r.query["v"], c.helperVersion != v { update(id) { $0.helperVersion = v } }
            if let m = r.query["mon"].flatMap(Monitor.parse), c.monitors != m { update(id) { $0.monitors = m } }
            out = config.deviceConfig(for: c, serverIP: macIP, wavHashes: wavHashes)
            out["cv"] = configVersion
            out["commands"] = commands[id] ?? []
            out["helperFiles"] = Payload.hashes
            commands[id] = nil
            // the install's last step: the helper confirms Deskflow connected
            // (also when the installer gave up waiting on step 6 but the computer did connect)
            if let s = session, s.deviceId == id, isOnline(c),
               s.state == .installing || (s.state == .failed && s.failedStep == 5) {
                for i in 0..<6 { s.steps[i] = .ok }
                s.state = .done
                sessionTick += 1
            }
        }
        return .json(out)
    }
}
