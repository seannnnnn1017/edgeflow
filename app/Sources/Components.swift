// Design tokens and shared controls, after "Edgeflow Prototype" (vibrant surface,
// original palette). Colors follow the system's light/dark appearance.

import AppKit
import SwiftUI

struct Palette {
    let dark: Bool
    var fg: Color { dark ? Color(hex: 0xF1F3F6) : Color(hex: 0x16181C) }
    var mut: Color { fg.opacity(dark ? 0.58 : 0.6) }
    var content: Color { dark ? Color(hex: 0x1E1E20) : .white }
    var card: Color { dark ? Color(hex: 0x29292C) : Color(hex: 0xF2F2F4) }
    var field: Color { dark ? Color(hex: 0x232326) : Color(hex: 0xF5F5F7) }
    var tile: Color { dark ? Color(hex: 0x333337) : .white }
    var chip: Color { dark ? .white.opacity(0.08) : .black.opacity(0.05) }
    var line: Color { dark ? .white.opacity(0.09) : .black.opacity(0.09) }
    var div: Color { dark ? .black.opacity(0.3) : .black.opacity(0.08) }
    var off: Color { dark ? .white.opacity(0.16) : .black.opacity(0.14) }
    var menu: Color { dark ? Color(red: 36 / 255, green: 36 / 255, blue: 40 / 255).opacity(0.9) : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255).opacity(0.92) }
    var dot: Color { dark ? .white.opacity(0.07) : .black.opacity(0.08) }
    var navOn: Color { dark ? .white.opacity(0.16) : .white.opacity(0.85) }
    var navOff: Color { dark ? .white.opacity(0.05) : .white.opacity(0.35) }
    var segOn: Color { dark ? .white.opacity(0.16) : .white }
}

enum DotColor {
    static let green = Color(hex: 0x34C759), orange = Color(hex: 0xFF9F0A), red = Color(hex: 0xFF453A), grey = Color(hex: 0x8E8E93)
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette(dark: true) }
private struct AccentKey: EnvironmentKey { static let defaultValue = Color(hex: 0x59D9FF) }
extension EnvironmentValues {
    var pal: Palette { get { self[PaletteKey.self] } set { self[PaletteKey.self] = newValue } }
    var ac: Color { get { self[AccentKey.self] } set { self[AccentKey.self] = newValue } }
}

/// Sets palette + accent from the system appearance and the chosen effect color.
struct Themed: ViewModifier {
    @Environment(\.colorScheme) var scheme
    var accent: Color
    func body(content: Content) -> some View {
        let p = Palette(dark: scheme == .dark)
        content.environment(\.pal, p).environment(\.ac, accent).foregroundStyle(p.fg).tint(accent)
    }
}

extension View {
    func themed(_ accent: Color) -> some View { modifier(Themed(accent: accent)) }
}

/// Accent text color: on light backgrounds the design darkens it for contrast.
struct AccentText: ViewModifier {
    @Environment(\.ac) var ac
    @Environment(\.colorScheme) var scheme
    func body(content: Content) -> some View {
        let dimmed = Color(nsColor: NSColor(ac).usingColorSpace(.sRGB)?.blended(withFraction: 0.45, of: .black) ?? NSColor(ac))
        content.foregroundStyle(scheme == .light ? dimmed : ac)
    }
}
extension View { func accentText() -> some View { modifier(AccentText()) } }

// MARK: - Window chrome

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

// MARK: - Controls

/// 34×20 switch from the design.
struct EFToggle: View {
    @Binding var on: Bool
    @Environment(\.pal) var pal
    @Environment(\.ac) var ac
    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { on.toggle() } } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? ac : pal.off).frame(width: 34, height: 20)
                Circle().fill(.white).frame(width: 16, height: 16).shadow(color: .black.opacity(0.3), radius: 1, y: 1).padding(2)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ValuePill: View {
    var text: String
    @Environment(\.pal) var pal
    var body: some View {
        Text(text).font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(pal.chip))
    }
}

struct SliderRow: View {
    var label: String
    var desc: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    @Environment(\.pal) var pal
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if let desc { Text(desc).font(.system(size: 12)).foregroundStyle(pal.mut) }
                }
                Spacer()
                ValuePill(text: format(value))
            }
            Slider(value: Binding(get: { value }, set: { value = (($0 / step).rounded() * step * 1000).rounded() / 1000 }), in: range)
                .controlSize(.small)
        }
    }
}

struct ToggleRow: View {
    var label: String
    var desc: String? = nil
    @Binding var on: Bool
    @Environment(\.pal) var pal
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let desc { Text(desc).font(.system(size: 12)).foregroundStyle(pal.mut) }
            }
            Spacer()
            EFToggle(on: $on)
        }
    }
}

struct Card<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.pal) var pal
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(pal.card))
    }
}

struct CardHeader<Trailing: View>: View {
    var icon: String
    var title: String
    var desc: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.pal) var pal
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).accentText().frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if let desc { Text(desc).font(.system(size: 12)).foregroundStyle(pal.mut) }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(icon: String, title: String, desc: String? = nil) {
        self.init(icon: icon, title: title, desc: desc) { EmptyView() }
    }
}

/// Small rounded chip button (試聽, 預覽, 新增電腦 …).
struct ChipButton: View {
    var icon: String? = nil
    var title: String
    var action: () -> Void
    @Environment(\.pal) var pal
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12))
            }
            .padding(.leading, icon == nil ? 12 : 9).padding(.trailing, 12)
            .frame(height: 28)
            .background(Capsule().fill(hover ? pal.line : pal.chip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Accent-tinted main action (下一步, 重新連線, 開始安裝).
struct PrimaryButton: View {
    var title: String
    var icon: String? = nil
    var height: CGFloat = 32
    var disabled = false
    var action: () -> Void
    @Environment(\.ac) var ac
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: height < 30 ? 12 : 13, weight: .semibold))
            }
            .padding(.horizontal, height < 30 ? 12 : 18)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: height < 30 ? 8 : 9).fill(ac.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: height < 30 ? 8 : 9).strokeBorder(ac, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

struct SecondaryButton: View {
    var title: String
    var icon: String? = nil
    var action: () -> Void
    @Environment(\.pal) var pal
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12)) }
                Text(title).font(.system(size: 13))
            }
            .padding(.horizontal, 14).frame(height: 32)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pal.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Segmented<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var value: T
    var fill = false
    var height: CGFloat = 24
    @Environment(\.pal) var pal
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (v, label) = options[i]
                Button { value = v } label: {
                    Text(label).font(.system(size: 12.5))
                        .padding(.horizontal, 11)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: height)
                        .background(RoundedRectangle(cornerRadius: 7).fill(value == v ? pal.segOn : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(pal.chip))
        .fixedSize(horizontal: !fill, vertical: true)
    }
}

struct StatusDot: View {
    var color: Color
    var pulse = false
    var size: CGFloat = 7
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(
                Circle().stroke(color.opacity(on ? 0 : 0.55), lineWidth: on ? 7 : 0)
                    .scaleEffect(on ? 1.9 : 1).opacity(pulse ? 1 : 0)
            )
            .onAppear { if pulse { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { on = true } } }
    }
}

struct KeyCap: View {
    var text: String
    var remote = false
    @Environment(\.pal) var pal
    @Environment(\.ac) var ac
    var body: some View {
        Text(text).font(.system(size: remote ? 12 : 12.5)).lineLimit(1)
            .padding(.horizontal, remote ? 7 : 6)
            .frame(minWidth: 24, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(remote ? ac.opacity(0.14) : pal.chip))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(remote ? ac.opacity(0.35) : pal.line))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(remote ? ac.opacity(0.35) : pal.line).frame(height: 1.5).padding(.horizontal, 2)
            }
    }
}

struct Spinner: View {
    var size: CGFloat = 12
    @Environment(\.ac) var ac
    @Environment(\.pal) var pal
    @State private var spin = false
    var body: some View {
        Circle().stroke(pal.line, lineWidth: 2)
            .overlay(Circle().trim(from: 0, to: 0.25).stroke(ac, style: StrokeStyle(lineWidth: 2, lineCap: .round)))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin = true } }
    }
}

struct WaitingDots: View {
    @Environment(\.ac) var ac
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let p = (t / 1.2 + Double(i) * 0.83).truncatingRemainder(dividingBy: 1)
                    Circle().fill(ac).frame(width: 6, height: 6).opacity(p < 0.4 ? 0.2 + p * 2 : max(0.2, 1 - (p - 0.4) * 2))
                }
            }
        }
    }
}

struct IconTile: View {
    var icon: String
    @Environment(\.pal) var pal
    var body: some View {
        Image(systemName: icon).font(.system(size: 15)).accentText()
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(pal.chip))
    }
}

/// The design's app mark (two screens, cursor line) used on the welcome page.
struct AppMark: View {
    var size: CGFloat = 96
    var body: some View {
        let s = size / 96
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22 * s, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF35E52), Color(hex: 0xDA3468), Color(hex: 0x6A3D9E)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 6 * s).fill(.white.opacity(0.35)).frame(width: 43 * s, height: 31 * s).offset(x: 16 * s, y: 23 * s)
            RoundedRectangle(cornerRadius: 6 * s).fill(.white).frame(width: 46 * s, height: 34 * s)
                .shadow(color: Color(red: 60 / 255, green: 10 / 255, blue: 60 / 255).opacity(0.35), radius: 7 * s, y: 6 * s)
                .offset(x: 36 * s, y: 40 * s)
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x59D9FF)).frame(width: 2.5 * s, height: 26 * s)
                .shadow(color: Color(hex: 0x59D9FF), radius: 4 * s).offset(x: 40 * s, y: 44 * s)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 22 * s, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 15, y: 12)
    }
}
