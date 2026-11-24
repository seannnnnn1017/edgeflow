// Everything that runs on the Mac while sharing: Deskflow's config files, its server
// process, its log (who is connected, where the cursor is), the charge sound and the
// clipboard image bridge.

import AppKit
import Foundation

// MARK: - Deskflow config files

enum DeskflowConf {
    /// Rewrites Deskflow.conf, the server layout and the trusted-clients list from the
    /// settings. Returns true when something changed (the core only reads them at start).
    @discardableResult
    static func write(_ cfg: FXConfig) -> Bool {
        try? FileManager.default.createDirectory(at: Env.tlsDir, withIntermediateDirectories: true)
        let mac = Env.macScreen
        var changed = false

        // 1. Deskflow.conf
        let old = (try? String(contentsOf: Env.deskflowConf, encoding: .utf8)) ?? ""
        var ini = INI(old)
        let fx = Env.fxDir.path
        ini.set("core", ["coreMode": "2", "computerName": mac, "enableEnterCommand": "true",
                         "enterCommand": "\"\(fx)/edge-fx \(fx)/return.wav auto\"", "processMode": "0"])
        ini.remove("core", "interface")
        ini.set("security", ["tlsEnabled": "true", "checkPeerFingerprints": "true"])
        ini.set("server", ["externalConfig": "true", "externalConfigFile": Env.serverConf.path,
                           "enableSwitchDelay": "\(cfg.delay >= 0.05)", "switchDelay": "\(Int((cfg.delay * 1000).rounded()))",
                           "enableClipboard": "\(cfg.clipboard)", "clipboardSize": "64"])
        ini.set("log", ["toFile": "true", "level": "Info", "file": Env.deskflowLog.path])
        ini.set("gui", ["startCoreWithGui": "true", "enableUpdateCheck": "false"])
        ini.sections.removeAll { $0.name.hasPrefix("computer_") }
        ini.set("computer_\(mac)", ["name": mac])
        for c in cfg.computers {
            let k = cfg.keys(for: c)
            // Mac ⌘ arrives as Super: send it as Ctrl, and Mac ⌃ as Super/Win
            ini.set("computer_\(c.screen)", ["name": c.screen, "modifierSuper": k ? "ctrl" : "super",
                                              "modifierCtrl": k ? "super" : "ctrl"])
        }
        let text = ini.text
        if text != old { try? text.write(to: Env.deskflowConf, atomically: true, encoding: .utf8); changed = true }

        // 2. layout: each computer on its side of the Mac
        var links = "section: options\nend\n\nsection: links\n\t\(mac):\n"
        for c in cfg.computers { links += "\t\t\(c.side.deskflow) = \(c.screen)\n" }
        for c in cfg.computers { links += "\t\(c.screen):\n\t\t\(c.side.opposite.deskflow) = \(mac)\n" }
        links += "end\n"
        if links != (try? String(contentsOf: Env.serverConf, encoding: .utf8)) {
            try? links.write(to: Env.serverConf, atomically: true, encoding: .utf8); changed = true
        }

        // 3. certificates the server accepts
        let tc = Env.tlsDir.appendingPathComponent("trusted-clients")
        let have = Set(((try? String(contentsOf: tc, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        let want = have.union(cfg.computers.filter { !$0.fingerprint.isEmpty }.map { "v2:sha256:\($0.fingerprint)" })
        if want != have {
            try? (want.sorted().joined(separator: "\n") + "\n").write(to: tc, atomically: true, encoding: .utf8); changed = true
        }
        return changed
    }

    static var serverFingerprint: String {
        let pem = Env.tlsDir.appendingPathComponent("deskflow.pem")
        if !FileManager.default.fileExists(atPath: pem.path) { _ = makeIdentity(at: pem) }
        let out = sh("/usr/bin/openssl", ["x509", "-in", pem.path, "-noout", "-fingerprint", "-sha256"]).out
        return out.split(separator: "=").last.map { $0.replacingOccurrences(of: ":", with: "").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    /// Key + self-signed certificate in Deskflow's layout (private key first, then the certificate).
    /// Returns the certificate's sha256 fingerprint.
    static func makeIdentity(at url: URL) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ef-" + Crypto.randomHex(4))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let k = dir.appendingPathComponent("k.pem").path, c = dir.appendingPathComponent("c.pem").path
        let r = sh("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", k, "-out", c,
                                        "-days", "3650", "-subj", "/CN=Deskflow"], timeout: 30)
        guard r.status == 0, let key = try? String(contentsOfFile: k, encoding: .utf8),
              let cert = try? String(contentsOfFile: c, encoding: .utf8) else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (key + cert).write(to: url, atomically: true, encoding: .utf8)
        let fp = sh("/usr/bin/openssl", ["x509", "-in", c, "-noout", "-fingerprint", "-sha256"]).out
        return fp.split(separator: "=").last.map { $0.replacingOccurrences(of: ":", with: "").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

/// Minimal Qt-style INI editor that keeps sections it doesn't touch.
struct INI {
    struct Section { var name: String; var lines: [String] }
    var sections: [Section] = []

    init(_ text: String) {
        var cur: Section? = nil
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let c = cur { sections.append(c) }
                cur = Section(name: String(line.dropFirst().dropLast()), lines: [])
            } else if !line.isEmpty {
                if cur == nil { cur = Section(name: "General", lines: []) }
                cur!.lines.append(line)
            }
        }
        if let c = cur { sections.append(c) }
    }

    mutating func set(_ section: String, _ kv: [String: String]) {
        if !sections.contains(where: { $0.name == section }) { sections.append(Section(name: section, lines: [])) }
        let i = sections.firstIndex { $0.name == section }!
        for (k, v) in kv.sorted(by: { $0.key < $1.key }) {
            if let j = sections[i].lines.firstIndex(where: { $0.hasPrefix(k + "=") }) { sections[i].lines[j] = "\(k)=\(v)" }
            else { sections[i].lines.append("\(k)=\(v)") }
        }
    }

    mutating func remove(_ section: String, _ key: String) {
        guard let i = sections.firstIndex(where: { $0.name == section }) else { return }
        sections[i].lines.removeAll { $0.hasPrefix(key + "=") }
    }

    var text: String { sections.map { "[\($0.name)]\n" + $0.lines.joined(separator: "\n") }.joined(separator: "\n\n") + "\n" }
}

// MARK: - Deskflow server process

/// Runs Deskflow's server core in the background (no Deskflow window ever shows).
/// Restarts it if it exits on its own.
final class CoreRunner {
    private var proc: Process?
    private var wanted = false
    private let q = DispatchQueue(label: "edgeflow.core")
    private(set) var lastExit: Date?

    var isRunning: Bool { q.sync { proc?.isRunning == true } }

    func start() { q.async { self.wanted = true; self.launch() } }

    func stop() {
        q.sync {
            wanted = false
            guard let p = proc, p.isRunning else { return }
            p.terminate()
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    func restart() { stop(); start() }

    private func launch() {
        guard wanted, proc?.isRunning != true, FileManager.default.isExecutableFile(atPath: Env.coreBinary) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Env.coreBinary)
        p.arguments = ["server"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            self?.lastExit = Date()
            self?.q.asyncAfter(deadline: .now() + 2) { self?.launch() }
        }
        do { try p.run(); proc = p } catch { proc = nil }
    }
}

// MARK: - Deskflow log: connections and cursor position

final class LogWatcher {
    private var offset: UInt64 = 0
    private var timer: Timer?
    private(set) var connected = Set<String>()
    private(set) var activeScreen: String? = nil
    var onSwitch: ((String, String) -> Void)?
    var onChange: (() -> Void)?

    func start() {
        // keep the log small: start fresh each launch
        if let a = try? FileManager.default.attributesOfItem(atPath: Env.deskflowLog.path),
           (a[.size] as? NSNumber)?.intValue ?? 0 > 4_000_000 {
            try? "".write(to: Env.deskflowLog, atomically: true, encoding: .utf8)
        }
        offset = (try? FileManager.default.attributesOfItem(atPath: Env.deskflowLog.path)[.size] as? NSNumber)?.uint64Value ?? 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }

    func reset() { connected.removeAll(); activeScreen = nil; onChange?() }

    private func poll() {
        guard let h = try? FileHandle(forReadingFrom: Env.deskflowLog) else { return }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        if end < offset { offset = 0 }
        guard end > offset else { return }
        try? h.seek(toOffset: offset)
        let data = h.readDataToEndOfFile()
        offset = end
        var changed = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let q = line.split(separator: "\"").map(String.init)
            if line.contains("switch from \""), q.count >= 4 {
                activeScreen = q[3]; changed = true; onSwitch?(q[1], q[3])
            } else if line.contains("has connected"), q.count >= 2 {
                connected.insert(q[1]); changed = true
            } else if line.contains("has disconnected"), q.count >= 2 {
                connected.remove(q[1]); changed = true
                if activeScreen == q[1] { activeScreen = nil }
            } else if line.contains("started server") {
                connected.removeAll(); activeScreen = nil; changed = true
            }
        }
        if changed { onChange?() }
    }
}

// MARK: - Charge sound

/// Plays the charge-up sound while the cursor is pressed against an edge that has a
/// computer behind it; stops if you let go before Deskflow switches.
final class ChargeWatcher {
    var enabled = true
    var keepIfHeld: TimeInterval = 0.2
    var volume: Float = 0.6
    var sides: Set<Side> = []
    private var sound: NSSound?
    private var edgeSince: Date?
    private var armed = true
    private var timer: Timer?

    func reloadSound() {
        sound = NSSound(contentsOf: Env.fxDir.appendingPathComponent("charge.wav"), byReference: false)
        sound?.volume = volume
    }

    func start() {
        reloadSound()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func atEdge(_ m: NSPoint) -> Bool {
        let frames = NSScreen.screens.map(\.frame)
        guard let u = frames.first else { return false }
        let all = frames.dropFirst().reduce(u) { $0.union($1) }
        return (sides.contains(.top) && m.y >= all.maxY - 2) || (sides.contains(.bottom) && m.y <= all.minY + 1)
            || (sides.contains(.left) && m.x <= all.minX + 1) || (sides.contains(.right) && m.x >= all.maxX - 2)
    }

    private func tick() {
        guard enabled, let sound else { edgeSince = nil; return }
        if atEdge(NSEvent.mouseLocation) {
            if edgeSince == nil && armed {
                edgeSince = Date(); armed = false
                sound.stop(); sound.currentTime = 0; sound.volume = volume; sound.play()
            }
        } else {
            if let s = edgeSince, Date().timeIntervalSince(s) < keepIfHeld { sound.stop() }
            edgeSince = nil; armed = true
        }
    }
}

// MARK: - Clipboard images

/// Deskflow's Mac side only moves images as "com.microsoft.bmp", while screenshots and
/// most apps use PNG/TIFF. Adds the missing format both ways, and puts new Mac
/// screenshots on the clipboard.
final class ClipboardBridge {
    var enabled = true
    var screenshots = true
    var onDesktopAccess: ((Bool) -> Void)?
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var known = Set<String>()
    private let bmpType = NSPasteboard.PasteboardType("com.microsoft.bmp")
    let shotDir: URL = {
        let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return loc.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? Env.home.appendingPathComponent("Desktop")
    }()

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.check() }
        watchShots()
    }

    /// Touching the folder triggers macOS's "Desktop folder" prompt the first time.
    @discardableResult
    func watchShots() -> Bool {
        guard dirSource == nil else { return true }
        let ok = (try? FileManager.default.contentsOfDirectory(atPath: shotDir.path)) != nil
        onDesktopAccess?(ok)
        guard ok else { return false }
        known = Set(listShots())
        let fd = open(shotDir.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scanShots() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
        return true
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        defer { lastCount = pb.changeCount }
        guard enabled, let types = pb.types else { return }
        let hasBMP = types.contains(bmpType), hasPNG = types.contains(.png), hasTIFF = types.contains(.tiff)
        if (hasPNG || hasTIFF) && !hasBMP {
            guard let data = pb.data(forType: hasPNG ? .png : .tiff), let rep = NSBitmapImageRep(data: data),
                  let bmp = rep.representation(using: .bmp, properties: [:]) else { return }
            pb.addTypes([bmpType], owner: nil)
            pb.setData(bmp, forType: bmpType)
        } else if hasBMP && !hasPNG {
            guard let data = pb.data(forType: bmpType), let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            pb.addTypes([.png, .tiff], owner: nil)
            pb.setData(png, forType: .png)
            if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        }
    }

    private func listShots() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: shotDir.path)) ?? []
        return names.filter { n in
            let l = n.lowercased()
            return (l.hasSuffix(".png") || l.hasSuffix(".jpg") || l.hasSuffix(".heic"))
                && (n.hasPrefix("截圖") || n.hasPrefix("螢幕快照") || n.hasPrefix("Screenshot") || n.hasPrefix("Screen Shot"))
        }
    }

    private func scanShots() {
        let now = listShots()
        let fresh = now.filter { !known.contains($0) }
        known = Set(now)
        guard enabled, screenshots, let name = fresh.last else { return }
        let url = shotDir.appendingPathComponent(name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let img = NSImage(contentsOf: url), let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
            pb.setData(tiff, forType: .tiff)
        }
    }
}
