// Edge effect for the Mac side of Deskflow.
// Deskflow runs this (core/enterCommand) when the cursor comes back to the Mac.
// Shows a glow along the entry edge plus a ripple at the cursor, plays the
// arrival sound, then exits. Never takes focus or eats clicks.
// Look & sound come from ~/Library/Deskflow/fx/config.json (written by Edgeflow).
//
// Build: swiftc -O mac_edge_fx.swift -o edge-fx
// Usage: edge-fx [sound.wav] [edge: top|bottom|left|right]

import AppKit

struct FXConfig: Decodable {
    var soundEnabled: Bool?
    var volume: Double?
    var effectEnabled: Bool?
    var color: [Double]?
    var duration: Double?
    var glow: Double?
    var ripple: Bool?
}

let args = CommandLine.arguments
let soundPath = args.count > 1 ? args[1] : ""
var edge = args.count > 2 ? args[2] : "top"
// "auto": light the screen edge the cursor just came in through (the nearest one)
if edge == "auto" {
    let m = NSEvent.mouseLocation
    let f = (NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!).frame
    let d = ["top": f.maxY - m.y, "bottom": m.y - f.minY, "left": m.x - f.minX, "right": f.maxX - m.x]
    edge = d.min { $0.value < $1.value }!.key
}
let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Deskflow/fx/config.json")
let cfg = (try? JSONDecoder().decode(FXConfig.self, from: Data(contentsOf: configURL)))
    ?? FXConfig()

let soundOn = cfg.soundEnabled ?? true
let effectOn = cfg.effectEnabled ?? true
let duration = max(0.2, cfg.duration ?? 0.75)
let band = CGFloat(cfg.glow ?? 70)
let rippleOn = cfg.ripple ?? true
let rgb = cfg.color ?? [0.35, 0.85, 1.0]
let tint = NSColor(calibratedRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1.0)

if !soundOn && !effectOn { exit(0) }

final class FXView: NSView {
    var progress: CGFloat = 0
    var cursor: NSPoint = .zero  // in view coordinates

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = progress
        let fade = 1 - p * p  // ease-out fade

        // 1) Edge glow: gradient band hugging the entry edge
        let colors = [tint.withAlphaComponent(0.85 * fade).cgColor,
                      tint.withAlphaComponent(0.0).cgColor] as CFArray
        if band > 0, let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            let b = bounds
            let (from, to): (CGPoint, CGPoint)
            switch edge {
            case "bottom": (from, to) = (CGPoint(x: 0, y: b.minY), CGPoint(x: 0, y: b.minY + band))
            case "left":   (from, to) = (CGPoint(x: b.minX, y: 0), CGPoint(x: b.minX + band, y: 0))
            case "right":  (from, to) = (CGPoint(x: b.maxX, y: 0), CGPoint(x: b.maxX - band, y: 0))
            default:       (from, to) = (CGPoint(x: 0, y: b.maxY), CGPoint(x: 0, y: b.maxY - band))
            }
            ctx.drawLinearGradient(g, start: from, end: to, options: [])
        }

        guard rippleOn else { return }
        // 2) Ripple: two expanding rings at the cursor
        for (i, lag) in [CGFloat(0), 0.18].enumerated() {
            let q = max(0, min(1, (p - lag) / (1 - lag)))
            if q <= 0 { continue }
            let r = 8 + 70 * (1 - pow(1 - q, 3))  // ease-out cubic
            let alpha = (1 - q) * (i == 0 ? 0.9 : 0.55)
            ctx.setStrokeColor(tint.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(3 * (1 - q) + 1)
            ctx.strokeEllipse(in: CGRect(x: cursor.x - r, y: cursor.y - r, width: r * 2, height: r * 2))
        }
        ctx.setFillColor(tint.withAlphaComponent(0.6 * fade).cgColor)
        ctx.fillEllipse(in: CGRect(x: cursor.x - 6, y: cursor.y - 6, width: 12, height: 12))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, never steals focus

var window: NSWindow?
var view: FXView?
if effectOn {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.level = .screenSaver
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    let v = FXView(frame: NSRect(origin: .zero, size: screen.frame.size))
    v.cursor = NSPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
    w.contentView = v
    w.orderFrontRegardless()
    window = w
    view = v
}

if soundOn, !soundPath.isEmpty, let s = NSSound(contentsOfFile: soundPath, byReference: true) {
    s.volume = Float(cfg.volume ?? 0.8)
    s.play()
}

let start = Date()
let total = effectOn ? duration : 0.9  // sound-only: just wait for the sound
Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { t in
    let p = Date().timeIntervalSince(start) / total
    if p >= 1 {
        t.invalidate()
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        return
    }
    view?.progress = CGFloat(p)
    view?.needsDisplay = true
}
app.run()
