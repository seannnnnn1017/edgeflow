// Settings model: global feel/sound/effect/key settings plus the paired computers.

import Foundation
import SwiftUI

enum Side: String, Codable, CaseIterable {
    case top, bottom, left, right
    var opposite: Side { [.top: .bottom, .bottom: .top, .left: .right, .right: .left][self]! }
    var label: String { T("pos_\(rawValue)") }
    /// Deskflow link direction word.
    var deskflow: String { [.top: "up", .bottom: "down", .left: "left", .right: "right"][self]! }
}

struct Computer: Codable, Identifiable, Equatable {
    var id: String              // device id, also used in helper URLs
    var name: String            // what the user calls it
    var screen: String          // Deskflow screen name (the other computer's host name)
    var os: String              // "linux" | "windows"
    var osv: String             // "Ubuntu 24.04", "Windows 11"
    var ip: String
    var icon: String = "desktop" // desktop | laptop | server
    var side: Side = .right
    var keys: Bool? = nil       // per-computer override of the global key mapping
    var key: String             // shared secret for the helper's config polling (hex)
    var fingerprint: String = "" // its Deskflow certificate (sha256 hex)
    var helperVersion: String? = nil
    var lastSeen: Date? = nil
    var ssh: Bool = false

    var isWindows: Bool { os == "windows" }
    var sfIcon: String { ["laptop": "laptopcomputer", "server": "server.rack"][icon] ?? "desktopcomputer" }
    var osShort: String { isWindows ? "Windows" : "Linux" }
}

struct FXConfig: Codable, Equatable {
    var delay: Double = 0.25
    var chargeSound: Bool = true
    var soundEnabled: Bool = true
    var volume: Double = 0.6
    var theme: String = SoundTheme.crystal.rawValue
    var effectEnabled: Bool = true
    var color: [Double] = [0.35, 0.85, 1.0]
    var duration: Double = 0.6
    var glow: Double = 48
    var ripple: Bool = true
    var macKeys: Bool = true
    var ime: String = "caps"               // caps | shift | ctrlspace
    var clipboard: Bool = true
    var screenshotToClipboard: Bool = true
    var computers: [Computer] = []
    var setupDone: Bool = false
    var paused: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FXConfig()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        delay = v(.delay, d.delay); chargeSound = v(.chargeSound, d.chargeSound)
        soundEnabled = v(.soundEnabled, d.soundEnabled); volume = v(.volume, d.volume)
        theme = v(.theme, d.theme); effectEnabled = v(.effectEnabled, d.effectEnabled)
        color = v(.color, d.color); duration = v(.duration, d.duration); glow = v(.glow, d.glow)
        ripple = v(.ripple, d.ripple); macKeys = v(.macKeys, d.macKeys); ime = v(.ime, d.ime)
        clipboard = v(.clipboard, d.clipboard); screenshotToClipboard = v(.screenshotToClipboard, d.screenshotToClipboard)
        computers = v(.computers, d.computers); setupDone = v(.setupDone, d.setupDone); paused = v(.paused, d.paused)
        if color.count != 3 { color = d.color }
    }

    var accent: Color { Color(red: color[0], green: color[1], blue: color[2]) }
    var soundTheme: SoundTheme { SoundTheme(rawValue: theme) ?? .crystal }
    var colorHex: String { String(format: "#%02X%02X%02X", Int(color[0] * 255), Int(color[1] * 255), Int(color[2] * 255)) }

    func keys(for c: Computer) -> Bool { c.keys ?? macKeys }
    func computer(side: Side) -> Computer? { computers.first { $0.side == side } }

    /// What the helper on one computer needs (written to its config.json).
    func deviceConfig(for c: Computer, serverIP: String, wavHashes: [String: String]) -> [String: Any] {
        [
            "delay": delay, "chargeSound": chargeSound, "soundEnabled": soundEnabled, "volume": volume,
            "theme": theme, "effectEnabled": effectEnabled, "color": color, "duration": duration,
            "glow": glow, "ripple": ripple, "clipboard": clipboard,
            "edge": c.side.opposite.rawValue, "keys": keys(for: c), "ime": ime,
            "screen": c.screen, "server": serverIP, "serverHost": Env.macHost,
            // only the sounds the other computer plays (return.wav is the Mac's own)
            "paused": paused, "files": wavHashes.filter { ["enter.wav", "charge.wav"].contains($0.key) },
            "helperLatest": Env.version,
        ]
    }
}

/// Accent swatches from the design (the "original" palette).
let swatchHex = ["#59D9FF", "#A98BFF", "#FF7EB6", "#FFB547", "#5BE49B", "#F4F6F8"]
let swatchNames = ["c_cyan", "c_purple", "c_pink", "c_amber", "c_green", "c_white"]

func rgb(_ hex: String) -> [Double] {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return [0.35, 0.85, 1.0] }
    return [Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255]
}
