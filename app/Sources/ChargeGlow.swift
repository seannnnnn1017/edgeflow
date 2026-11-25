// The charge glow: while the cursor pushes against the edge toward another computer, a
// glow at that spot grows and slowly brightens over the switch delay, so the charge is
// visible as well as audible.

import AppKit

/// Shared look (the Mac, the Linux and Windows helpers, and the preview follow it):
/// at progress p (0…1 of the delay) the glow reaches `reach(p)` along the edge and
/// `depth * deep(p)` into the screen, with brightness `level(p)`.
enum ChargeLook {
    static func level(_ p: Double) -> Double { 0.12 + 0.88 * pow(p, 1.8) }
    static func reach(_ p: Double) -> Double { 90 + 300 * (1 - pow(1 - p, 2)) }
    static func deep(_ p: Double) -> Double { 0.55 + 0.75 * p }
}

final class ChargeGlow {
    private var panel: NSPanel?
    private let view = GlowView()
    private var fading: Timer?

    /// Show or update the glow at cursor point `m` (screen coordinates) on `side`.
    func show(at m: NSPoint, side: Side, progress: Double, color: NSColor, depth: CGFloat) {
        fading?.invalidate(); fading = nil
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -3, dy: -3).contains(m) }) else { return }
        let f = screen.frame, d = depth * 1.4
        let frame: NSRect = switch side {
        case .top: NSRect(x: f.minX, y: f.maxY - d, width: f.width, height: d)
        case .bottom: NSRect(x: f.minX, y: f.minY, width: f.width, height: d)
        case .left: NSRect(x: f.minX, y: f.minY, width: d, height: f.height)
        case .right: NSRect(x: f.maxX - d, y: f.minY, width: d, height: f.height)
        }
        let p = panel ?? makePanel(frame)
        if p.frame != frame { p.setFrame(frame, display: false) }
        view.side = side; view.color = color; view.depth = depth; view.progress = progress; view.fade = 1
        view.along = side == .top || side == .bottom ? m.x - frame.minX : m.y - frame.minY
        view.needsDisplay = true
        if !p.isVisible { p.orderFrontRegardless() }
    }

    /// Fade out quickly (the cursor left the edge or crossed over).
    func hide() {
        guard let p = panel, p.isVisible, fading == nil else { return }
        let start = Date()
        fading = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = Date().timeIntervalSince(start) / 0.18
            if k >= 1 { t.invalidate(); self.fading = nil; p.orderOut(nil); return }
            self.view.fade = 1 - k
            self.view.needsDisplay = true
        }
    }

    private func makePanel(_ frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = view
        panel = p
        return p
    }
}

private final class GlowView: NSView {
    var side: Side = .top
    var along: CGFloat = 0
    var progress: Double = 0
    var fade: Double = 1
    var depth: CGFloat = 48
    var color: NSColor = .cyan

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let p = progress, level = ChargeLook.level(p) * fade
        let reach = ChargeLook.reach(p), deep = depth * ChargeLook.deep(p)
        let horizontal = side == .top || side == .bottom
        let o: CGPoint = switch side {
        case .top: CGPoint(x: along, y: bounds.maxY)
        case .bottom: CGPoint(x: along, y: 0)
        case .left: CGPoint(x: 0, y: along)
        case .right: CGPoint(x: bounds.maxX, y: along)
        }
        let hot = color.blended(withFraction: 0.4 * p, of: .white) ?? color
        func blob(_ rx: Double, _ ry: Double, _ a: Double, _ c: NSColor) {
            let cols = [c.withAlphaComponent(a), c.withAlphaComponent(a * 0.5), c.withAlphaComponent(0)].map(\.cgColor)
            guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols as CFArray,
                                     locations: [0, 0.45, 1]) else { return }
            ctx.saveGState()
            ctx.translateBy(x: o.x, y: o.y)
            ctx.scaleBy(x: horizontal ? rx : ry, y: horizontal ? ry : rx)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
            ctx.restoreGState()
        }
        blob(reach, deep, 0.9 * level, color)               // soft halo
        blob(reach * 0.35, deep * 0.45, level, hot)          // hot core
        blob(reach * 0.9, 3, min(1, level * 1.1), hot)       // the edge line itself
    }
}
