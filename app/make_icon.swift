// Renders Edgeflow's app icon, direction "1d 雙屏" from "Edgeflow Icons": the vivid wallpaper
// gradient, a dim screen behind and a lit screen in front with the cyan edge line.
// The design has three masters (160 / 64 / 32 pt); small sizes use the simpler ones.
//
// Usage: swift make_icon.swift <out dir>   → icon_<px>.png for 16, 32, 64, 128, 256, 512, 1024

import AppKit

struct Spec {
    let size: CGFloat, radius: CGFloat
    let back: CGRect, backR: CGFloat, backAlpha: CGFloat
    let front: CGRect, frontR: CGFloat, frontShadow: Bool
    let line: CGRect?, lineGlow: Bool
}

// Rects in the design's own coordinates (top-left origin), copied from the CSS.
let big = Spec(size: 160, radius: 36, back: CGRect(x: 26, y: 38, width: 72, height: 52), backR: 10, backAlpha: 0.35,
               front: CGRect(x: 60, y: 66, width: 76, height: 56), frontR: 10, frontShadow: true,
               line: CGRect(x: 66, y: 72, width: 4, height: 44), lineGlow: true)
let mid = Spec(size: 64, radius: 14, back: CGRect(x: 10, y: 15, width: 29, height: 21), backR: 4, backAlpha: 0.35,
               front: CGRect(x: 24, y: 26, width: 30, height: 22), frontR: 4, frontShadow: false,
               line: CGRect(x: 26.5, y: 28.5, width: 2, height: 17), lineGlow: false)
let small = Spec(size: 32, radius: 7, back: CGRect(x: 5, y: 7, width: 15, height: 11), backR: 2, backAlpha: 0.4,
                 front: CGRect(x: 12, y: 13, width: 15, height: 11), frontR: 2, frontShadow: false,
                 line: nil, lineGlow: false)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ s: Spec, px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let P = CGFloat(px)
    // macOS icon grid: the rounded square is 824/1024 of the canvas, centred
    let body = P * 824 / 1024, inset = (P - body) / 2, k = body / s.size
    // design coords (top-left) → canvas rect
    func r(_ d: CGRect) -> CGRect { CGRect(x: inset + d.minX * k, y: inset + (s.size - d.maxY) * k, width: d.width * k, height: d.height * k) }

    let squircle = NSBezierPath(roundedRect: CGRect(x: inset, y: inset, width: body, height: body), xRadius: s.radius * k, yRadius: s.radius * k)
    // soft drop shadow under the tile (big sizes only)
    if px >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -P * 0.012), blur: P * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        color(0x6A3D9E).setFill(); squircle.fill()
        ctx.restoreGState()
    }
    ctx.saveGState()
    squircle.addClip()
    // linear-gradient(150deg, #F35E52 0%, #DA3468 50%, #6A3D9E 100%): CSS 150° runs toward bottom-right
    NSGradient(colors: [color(0xF35E52), color(0xDA3468), color(0x6A3D9E)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: inset, y: inset, width: body, height: body), angle: -60)
    // back screen
    color(0xFFFFFF, s.backAlpha).setFill()
    NSBezierPath(roundedRect: r(s.back), xRadius: s.backR * k, yRadius: s.backR * k).fill()
    // front screen
    ctx.saveGState()
    if s.frontShadow { ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: color(0x3C0A3C, 0.35).cgColor) }
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r(s.front), xRadius: s.frontR * k, yRadius: s.frontR * k).fill()
    ctx.restoreGState()
    // cyan edge line
    if let l = s.line {
        ctx.saveGState()
        if s.lineGlow { ctx.setShadow(offset: .zero, blur: 10 * k, color: color(0x59D9FF, 0.8).cgColor) }
        color(0x59D9FF).setFill()
        NSBezierPath(roundedRect: r(l), xRadius: l.width / 2 * k, yRadius: l.width / 2 * k).fill()
        ctx.restoreGState()
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for px in [16, 32, 64, 128, 256, 512, 1024] {
    let spec = px <= 32 ? small : px <= 64 ? mid : big
    let data = render(spec, px: px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(px).png"))
}
print("wrote icons to \(out)")
