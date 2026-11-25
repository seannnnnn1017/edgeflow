// Layout map (drag computers around the Mac) and the live preview animation.

import SwiftUI

/// Tile centers on the 400×230 map, from the design.
let slotCenter: [Side: CGPoint] = [.right: CGPoint(x: 326, y: 115), .left: CGPoint(x: 74, y: 115),
                                   .top: CGPoint(x: 200, y: 37), .bottom: CGPoint(x: 200, y: 193)]

struct DotGrid: View {
    @Environment(\.pal) var pal
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 8
            while y < size.height {
                var x: CGFloat = 8
                while x < size.width { ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(pal.dot)); x += 16 }
                y += 16
            }
        }
    }
}

struct ComputerTile: View {
    var c: Computer
    var dot: Color
    var active: Bool
    @Environment(\.pal) var pal
    @Environment(\.ac) var ac
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: c.sfIcon).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    Circle().fill(dot).frame(width: 6, height: 6)
                    Text(c.osShort).font(.system(size: 10.5)).foregroundStyle(pal.mut)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 104, height: 56)
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.tile))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? ac : pal.line, lineWidth: 1.5))
        .shadow(color: .black.opacity(active ? 0.35 : 0.12), radius: active ? 10 : 3, y: active ? 6 : 1)
    }
}

struct LayoutMap: View {
    @EnvironmentObject var engine: Engine
    var onTap: ((Computer) -> Void)? = nil
    var glowSide: Side? = nil
    @State private var dragId: String?
    @State private var dragOffset: CGSize = .zero
    @Environment(\.pal) var pal
    @Environment(\.ac) var ac

    private func nearest(_ p: CGPoint) -> Side {
        slotCenter.min { hypot($0.value.x - p.x, $0.value.y - p.y) < hypot($1.value.x - p.x, $1.value.y - p.y) }!.key
    }

    /// A screen group dragged well away from the Mac moves to another side instead of sliding.
    private func pulledOff(_ c: Computer) -> Bool {
        abs(c.horizontalEdge ? dragOffset.height : dragOffset.width) > 50
    }

    private func dot(_ c: Computer) -> Color { engine.isOnline(c) ? DotColor.green : DotColor.grey }

    private func endDrag(_ c: Computer, _ g: DragGesture.Value, slide: Double? = nil) {
        let center = slotCenter[c.side]!
        if hypot(g.translation.width, g.translation.height) < 4 {
            onTap?(c)
        } else if let slide, !pulledOff(c) {
            withAnimation(.spring(duration: 0.3)) { engine.setEdgeStart(c.id, slide) }
        } else {
            let s = nearest(CGPoint(x: center.x + g.translation.width, y: center.y + g.translation.height))
            withAnimation(.spring(duration: 0.3)) { engine.place(c.id, s) }
        }
        dragId = nil; dragOffset = .zero
    }

    @ViewBuilder private func singleTile(_ c: Computer) -> some View {
        let center = slotCenter[c.side]!
        let dragging = dragId == c.id
        ComputerTile(c: c, dot: dot(c), active: dragging)
            .offset(x: center.x - 52 + (dragging ? dragOffset.width : 0), y: center.y - 28 + (dragging ? dragOffset.height : 0))
            .zIndex(dragging ? 2 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in dragId = c.id; dragOffset = g.translation }
                .onEnded { g in endDrag(c, g) })
            .animation(.spring(duration: 0.3), value: c.side)
    }

    /// A computer with several screens along the shared edge: its real screen layout, the part
    /// of its edge that meets the Mac lit up. Drag along the edge to slide it, away to move it.
    @ViewBuilder private func screenGroup(_ c: Computer, _ g: ScreenGroupGeo) -> some View {
        let dragging = dragId == c.id
        let slideBy = dragging && !pulledOff(c) ? (c.horizontalEdge ? dragOffset.width : dragOffset.height) : 0
        let start = g.start(sliding: slideBy)
        let cross = dragging && pulledOff(c) ? dragOffset : .zero
        ZStack(alignment: .topLeading) {
            ForEach(Array(c.screens.enumerated()), id: \.offset) { i, m in
                let r = g.rect(m, start: start)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(pal.tile)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(dragging ? ac : pal.line, lineWidth: dragging ? 1.5 : 1)
                    Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.mut)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(5)
                }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            }
            // the part of its edge the Mac leads to
            let bar = g.linkBar(start: start)
            RoundedRectangle(cornerRadius: 1.5).fill(ac).frame(width: bar.width, height: bar.height)
                .shadow(color: ac.opacity(0.8), radius: 4).offset(x: bar.minX, y: bar.minY)
            let label = g.labelCenter(start: start)
            HStack(spacing: 5) {
                Image(systemName: c.sfIcon).font(.system(size: 12))
                Text(c.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Circle().fill(dot(c)).frame(width: 6, height: 6)
            }
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(pal.card.opacity(0.92)))
            .frame(width: 160, height: 22)
            .offset(x: label.x - 80, y: label.y - 11)
        }
        .shadow(color: .black.opacity(dragging ? 0.35 : 0.12), radius: dragging ? 10 : 3, y: dragging ? 6 : 1)
        .offset(cross)
        .zIndex(dragging ? 2 : 1)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in dragId = c.id; dragOffset = v.translation }
            .onEnded { v in
                let s = g.start(sliding: c.horizontalEdge ? v.translation.width : v.translation.height)
                endDrag(c, v, slide: s)
            })
        .animation(.spring(duration: 0.3), value: c.side)
        .animation(.spring(duration: 0.3), value: c.edgeStart)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(pal.field)
            DotGrid()
            if let id = dragId, let c = engine.computer(id), ScreenGroupGeo(c) == nil || pulledOff(c) {
                let target = nearest(CGPoint(x: slotCenter[c.side]!.x + dragOffset.width, y: slotCenter[c.side]!.y + dragOffset.height))
                ForEach(Side.allCases, id: \.self) { s in
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(s == target ? ac : pal.line, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 104, height: 56)
                        .offset(x: slotCenter[s]!.x - 52, y: slotCenter[s]!.y - 28)
                }
            }
            // the Mac
            VStack(spacing: 3) {
                Image(systemName: "laptopcomputer").font(.system(size: 20))
                Text(T("mac_label")).font(.system(size: 11.5)).foregroundStyle(pal.mut)
            }
            .frame(width: 120, height: 76)
            .background(RoundedRectangle(cornerRadius: 10).fill(pal.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(pal.line))
            .overlay { if let g = glowSide { EdgeGlow(side: g) } }
            .offset(x: 140, y: 77)

            ForEach(engine.config.computers) { c in
                if let g = ScreenGroupGeo(c) {
                    screenGroup(c, g)
                } else {
                    singleTile(c)
                }
            }
        }
        .frame(width: 400, height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
    }
}

/// Where a multi-screen computer's screens go on the 400×230 map. The Mac tile is
/// x 140–260, y 77–153; the screens sit beside it on their side, scaled so the main screen
/// is as long as the Mac's edge (smaller if they wouldn't fit), and shifted along the edge
/// so the part linked to the Mac sits right against it.
struct ScreenGroupGeo {
    let c: Computer
    let lo: Double, total: Double, range: (Double, Double)
    let scale: Double
    let minX, minY, maxX, maxY: Double

    static let mac = CGRect(x: 140, y: 77, width: 120, height: 76)

    init?(_ c: Computer) {
        guard let span = c.edgeSpan, let range = c.edgeRange, let p = c.primaryScreen else { return nil }
        self.c = c; lo = span.lo; total = span.hi - span.lo; self.range = range
        minX = c.screens.map(\.x).min()!; minY = c.screens.map(\.y).min()!
        maxX = c.screens.map { $0.x + $0.w }.max()!; maxY = c.screens.map { $0.y + $0.h }.max()!
        let m = Self.mac
        let h = c.horizontalEdge
        let macLen = h ? m.width : m.height
        let crossRoom: Double = h ? 64 : 126            // between the Mac and the map's edge
        let axisRoom: Double = h ? 392 : 222
        scale = min(macLen / (h ? p.w : p.h), crossRoom / (h ? maxY - minY : maxX - minX),
                    axisRoom / (h ? maxX - minX : maxY - minY))
    }

    /// The edge start after sliding the screens by `by` map points (snapped to screen edges).
    func start(sliding by: Double) -> Double {
        let len = range.1 - range.0
        var s = range.0 - by / scale / total
        s = min(max(s, 0), 1 - len)
        if let snap = c.edgeSnaps.min(by: { abs($0 - s) < abs($1 - s) }), abs(snap - s) < 0.04 { s = snap }
        return s
    }

    /// Map position of a desktop pixel coordinate along the edge, for a given start.
    private func axis(_ px: Double, start: Double) -> Double {
        let m = Self.mac
        let macMid = c.horizontalEdge ? m.midX : m.midY
        let linkMid = lo + (start + (range.1 - range.0) / 2) * total
        return macMid + (px - linkMid) * scale
    }

    func rect(_ s: Monitor, start: Double) -> CGRect {
        let m = Self.mac, gap = 6.0
        if c.horizontalEdge {
            let x = axis(s.x, start: start), w = s.w * scale, h = s.h * scale
            let y = c.side == .top ? m.minY - gap - (maxY - s.y) * scale : m.maxY + gap + (s.y - minY) * scale
            return CGRect(x: x, y: y, width: w, height: h)
        } else {
            let y = axis(s.y, start: start), w = s.w * scale, h = s.h * scale
            let x = c.side == .left ? m.minX - gap - (maxX - s.x) * scale : m.maxX + gap + (s.x - minX) * scale
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    /// The lit strip on the screens' edge facing the Mac.
    func linkBar(start: Double) -> CGRect {
        let m = Self.mac, gap = 6.0
        let a = axis(lo + start * total, start: start), b = axis(lo + (start + range.1 - range.0) * total, start: start)
        switch c.side {
        case .top: return CGRect(x: a, y: m.minY - gap - 1.5, width: b - a, height: 3)
        case .bottom: return CGRect(x: a, y: m.maxY + gap - 1.5, width: b - a, height: 3)
        case .left: return CGRect(x: m.minX - gap - 1.5, y: a, width: 3, height: b - a)
        case .right: return CGRect(x: m.maxX + gap - 1.5, y: a, width: 3, height: b - a)
        }
    }

    /// Name label: in the middle of the screens, across from the Mac.
    func labelCenter(start: Double) -> CGPoint {
        let r = c.screens.map { rect($0, start: start) }.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: c.horizontalEdge ? Self.mac.midX : r.midX, y: c.horizontalEdge ? r.midY : Self.mac.midY)
    }
}

/// Pulsing accent bar on the Mac tile's edge toward where the cursor should go.
struct EdgeGlow: View {
    var side: Side
    @Environment(\.ac) var ac
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let o = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.4))
            GeometryReader { g in
                let vertical = side == .left || side == .right
                RoundedRectangle(cornerRadius: 3).fill(ac)
                    .frame(width: vertical ? 5 : g.size.width - 20, height: vertical ? g.size.height - 16 : 5)
                    .shadow(color: ac, radius: 9)
                    .position(x: side == .left ? 0 : side == .right ? g.size.width : g.size.width / 2,
                              y: side == .top ? 0 : side == .bottom ? g.size.height : g.size.height / 2)
                    .opacity(o)
            }
        }
    }
}

// MARK: - Live preview

/// The design's looping demo: cursor walks to the edge, charges, crosses, the glow and
/// ripple play on the other side. Timing follows the current settings.
struct LivePreview: View {
    var cfg: FXConfig
    var side: Side
    var remoteName: String
    var height: CGFloat = 230
    @Environment(\.pal) var pal
    @Environment(\.ac) var ac

    // boxes as fractions: x, y, w, h
    private var mac: [CGFloat] {
        switch side { case .right: [0.06, 0.14, 0.38, 0.72]; case .left: [0.56, 0.14, 0.38, 0.72]
        case .bottom: [0.22, 0.05, 0.56, 0.40]; case .top: [0.22, 0.55, 0.56, 0.40] }
    }
    private var rem: [CGFloat] {
        switch side { case .right: [0.56, 0.14, 0.38, 0.72]; case .left: [0.06, 0.14, 0.38, 0.72]
        case .bottom: [0.22, 0.55, 0.56, 0.40]; case .top: [0.22, 0.05, 0.56, 0.40] }
    }

    var body: some View {
        TimelineView(.animation) { tl in
            GeometryReader { g in
                let W = g.size.width, H = g.size.height
                let dur = 2.6 + cfg.delay * 2 + cfg.duration * 0.5
                let p = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: dur) / dur
                let bandW = max(2, (cfg.glow / 160 * 16).rounded())
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12).fill(pal.field)
                    screen(mac, T("mac_label"), W, H)
                    screen(rem, remoteName, W, H)
                    if cfg.effectEnabled && cfg.glow > 0 { band(W, H, bandW).opacity(bandOpacity(p)) }
                    if cfg.effectEnabled && cfg.ripple, let (o, s) = ripple(p) {
                        Circle().strokeBorder(ac, lineWidth: 2).frame(width: 34, height: 34).scaleEffect(s).opacity(o)
                            .position(ripplePoint(W, H))
                    }
                    if cfg.delay >= 0.05 && cfg.effectEnabled && cfg.chargeGlow, let k = chargeGlow(p) {
                        chargeGlowView(k, W, H)
                    }
                    if cfg.delay >= 0.05, let (o, s) = charge(p) {
                        Circle().strokeBorder(ac, style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(width: 30, height: 30)
                            .scaleEffect(s).opacity(o).position(chargePoint(W, H))
                    }
                    Image(systemName: "cursorarrow").font(.system(size: 17, weight: .regular)).symbolRenderingMode(.palette)
                        .foregroundStyle(pal.fg).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .position(cursor(p, W, H)).opacity(cursorOpacity(p))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func screen(_ b: [CGFloat], _ label: String, _ W: CGFloat, _ H: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8).fill(pal.card)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pal.line))
            .overlay(alignment: .bottom) { Text(label).font(.system(size: 11)).foregroundStyle(pal.mut).padding(.bottom, 6) }
            .frame(width: b[2] * W, height: b[3] * H)
            .offset(x: b[0] * W, y: b[1] * H)
    }

    private func band(_ W: CGFloat, _ H: CGFloat, _ bw: CGFloat) -> some View {
        let r = rem
        let grad: (UnitPoint, UnitPoint) = {
            switch side { case .right: (.leading, .trailing); case .left: (.trailing, .leading)
            case .bottom: (.top, .bottom); case .top: (.bottom, .top) }
        }()
        let rect: CGRect = {
            switch side {
            case .right: return CGRect(x: r[0] * W, y: r[1] * H, width: bw, height: r[3] * H)
            case .left: return CGRect(x: (r[0] + r[2]) * W - bw, y: r[1] * H, width: bw, height: r[3] * H)
            case .bottom: return CGRect(x: r[0] * W, y: r[1] * H, width: r[2] * W, height: bw)
            case .top: return CGRect(x: r[0] * W, y: (r[1] + r[3]) * H - bw, width: r[2] * W, height: bw)
            }
        }()
        return Rectangle().fill(LinearGradient(colors: [ac, ac.opacity(0)], startPoint: grad.0, endPoint: grad.1))
            .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }

    private func ripplePoint(_ W: CGFloat, _ H: CGFloat) -> CGPoint {
        switch side { case .right: CGPoint(x: 0.58 * W, y: 0.5 * H); case .left: CGPoint(x: 0.42 * W, y: 0.5 * H)
        case .bottom: CGPoint(x: 0.5 * W, y: 0.57 * H); case .top: CGPoint(x: 0.5 * W, y: 0.43 * H) }
    }
    private func chargePoint(_ W: CGFloat, _ H: CGFloat) -> CGPoint {
        switch side { case .right: CGPoint(x: 0.44 * W, y: 0.5 * H); case .left: CGPoint(x: 0.56 * W, y: 0.5 * H)
        case .bottom: CGPoint(x: 0.5 * W, y: 0.45 * H); case .top: CGPoint(x: 0.5 * W, y: 0.55 * H) }
    }

    /// Cursor path keyframes (fraction of the travel axis) at times 0, .32, .48, .52, .82.
    private func cursor(_ p: Double, _ W: CGFloat, _ H: CGFloat) -> CGPoint {
        let keys: [Double] = {
            switch side { case .right: [0.18, 0.42, 0.42, 0.58, 0.80]; case .left: [0.78, 0.55, 0.55, 0.40, 0.18]
            case .bottom: [0.16, 0.39, 0.39, 0.57, 0.76]; case .top: [0.76, 0.54, 0.54, 0.38, 0.16] }
        }()
        let times: [Double] = [0, 0.32, 0.48, 0.52, 0.82]
        var v = keys.last!
        for i in 0..<(times.count - 1) where p >= times[i] && p < times[i + 1] {
            let k = (p - times[i]) / (times[i + 1] - times[i])
            let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
            v = keys[i] + (keys[i + 1] - keys[i]) * e
        }
        let horizontal = side == .left || side == .right
        return horizontal ? CGPoint(x: v * W + 6, y: 0.46 * H + 8) : CGPoint(x: 0.48 * W + 6, y: v * H + 8)
    }
    private func cursorOpacity(_ p: Double) -> Double { p < 0.06 ? p / 0.06 : p < 0.82 ? 1 : p < 0.92 ? 1 - (p - 0.82) / 0.1 : 0 }
    private func bandOpacity(_ p: Double) -> Double { p < 0.49 ? 0 : p < 0.52 ? (p - 0.49) / 0.03 : p < 0.74 ? 1 - (p - 0.52) / 0.22 : 0 }
    private func ripple(_ p: Double) -> (Double, Double)? {
        guard p >= 0.5, p < 0.78 else { return nil }
        let k = (p - 0.5) / 0.28
        return (0.9 * (1 - k), 0.1 + 2.1 * (1 - pow(1 - k, 2)))
    }
    /// Charge glow progress during the push (0.32–0.48), then a quick fade; matches ChargeLook.
    private func chargeGlow(_ p: Double) -> (progress: Double, fade: Double)? {
        if p >= 0.32 && p < 0.48 { return ((p - 0.32) / 0.16, 1) }
        if p >= 0.48 && p < 0.51 { return (1, 1 - (p - 0.48) / 0.03) }
        return nil
    }
    private func chargeGlowView(_ k: (progress: Double, fade: Double), _ W: CGFloat, _ H: CGFloat) -> some View {
        let b = mac, q = k.progress
        let level = ChargeLook.level(q) * k.fade
        let horizontal = side == .top || side == .bottom
        // the spot on the Mac's edge where the cursor pushes (cursor keyframe at the edge)
        let c: CGPoint = switch side {
        case .top: CGPoint(x: 0.48 * W + 6, y: b[1] * H)
        case .bottom: CGPoint(x: 0.48 * W + 6, y: (b[1] + b[3]) * H)
        case .left: CGPoint(x: b[0] * W, y: 0.46 * H + 8)
        case .right: CGPoint(x: (b[0] + b[2]) * W, y: 0.46 * H + 8)
        }
        // scaled down from screen pixels to the little preview
        let rx = ChargeLook.reach(q) * 0.16, ry = max(10, cfg.glow) * 0.22 * ChargeLook.deep(q)
        let w = horizontal ? rx : ry, h = horizontal ? ry : rx
        let ell = { (sx: Double, sy: Double, a: Double, col: Color) in
            Ellipse().fill(RadialGradient(colors: [col.opacity(a), col.opacity(a * 0.5), col.opacity(0)],
                                          center: .center, startRadius: 0, endRadius: 0.5))
                .frame(width: 2 * w * sx, height: 2 * h * sy)
                .position(c)
        }
        return ZStack {
            ell(1, 1, 0.9 * level, ac)
            ell(0.35, 0.45, level, Color(nsColor: NSColor(ac).blended(withFraction: 0.4 * q, of: .white) ?? NSColor(ac)))
        }
        .frame(width: W, height: H)
        .mask(RoundedRectangle(cornerRadius: 8).frame(width: b[2] * W, height: b[3] * H)
                .position(x: (b[0] + b[2] / 2) * W, y: (b[1] + b[3] / 2) * H))
        .allowsHitTesting(false)
    }
    private func charge(_ p: Double) -> (Double, Double)? {
        guard p >= 0.3, p < 0.5 else { return nil }
        let k = (p - 0.3) / 0.18
        return (p < 0.34 ? (p - 0.3) / 0.04 * 0.9 : p < 0.48 ? 0.9 : 0.9 * (1 - (p - 0.48) / 0.02), 1.7 - 1.25 * min(1, k))
    }
}
