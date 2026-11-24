// App entry: one window (setup wizard or main), the menu bar panel, and quitting cleanly.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ n: Notification) { Engine.shared.core.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

final class UIState: ObservableObject {
    @Published var wizard = !Engine.shared.config.setupDone
}

@main
struct EdgeflowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine.shared
    @StateObject private var wiz = WizardModel()
    @StateObject private var ui = UIState()

    var body: some Scene {
        Window("Edgeflow", id: "main") {
            RootView(wiz: wiz, ui: ui).environmentObject(engine)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuPanel(ui: ui, wiz: wiz).environmentObject(engine)
        } label: {
            Image(nsImage: MenuIcon.image(engine.status))
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var wiz: WizardModel
    @ObservedObject var ui: UIState

    var body: some View {
        Group {
            if ui.wizard {
                WizardView(w: wiz) {
                    if !wiz.addMode { engine.finishSetup() }
                    withAnimation(.easeInOut(duration: 0.25)) { ui.wizard = false }
                }
                .frame(width: 600, height: 632)   // + 28 pt title bar = 660
            } else {
                MainView(addComputer: { wiz.start(add: true); ui.wizard = true })
                    .frame(width: 820, height: 672)   // + 28 pt title bar = 700
                    .background(VisualEffect(material: .sidebar).ignoresSafeArea())
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .themed(engine.config.accent)
        .onAppear {
            if ui.wizard && wiz.page == .welcome && engine.config.setupDone { wiz.start(add: true) }
            // EF_WIZ=<page>: open a wizard page directly (debug/screenshots)
            let pages: [String: WizPage] = ["welcome": .welcome, "perms": .perms, "choose": .choose, "pair": .pair,
                                            "ssh": .ssh, "progress": .progress, "name": .name, "place": .place]
            if let p = ProcessInfo.processInfo.environment["EF_WIZ"].flatMap({ pages[$0] }) {
                ui.wizard = true
                if p == .pair { _ = engine.newSession(os: "linux") }
                wiz.page = p
            }
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.pal) var pal
    var body: some View {
        if let t = engine.toast {
            Text(t).font(.system(size: 12.5)).padding(.horizontal, 16).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(pal.menu))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(pal.line))
                .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
                .padding(.bottom, 28)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .animation(.spring(duration: 0.25), value: engine.toast)
        }
    }
}

// MARK: - Menu bar

struct MenuPanel: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var ui: UIState
    @ObservedObject var wiz: WizardModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pal) var pal

    var body: some View {
        let b = Badge(engine)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(b.dot).frame(width: 7, height: 7)
                Text(engine.status == .noperm ? T("mb_ax") : b.l1)
            }
            .foregroundStyle(pal.mut).padding(.horizontal, 10).padding(.vertical, 5)
            divider
            ForEach(engine.config.computers) { c in
                row {
                    Circle().fill(engine.isOnline(c) ? DotColor.green : DotColor.grey).frame(width: 7, height: 7)
                    Text(c.name)
                    Spacer()
                    Text(c.side.label).font(.system(size: 12)).foregroundStyle(pal.mut)
                } action: { open() }
            }
            if !engine.config.computers.isEmpty { divider }
            row {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).frame(width: 14)
                    .opacity(engine.config.paused ? 1 : 0)
                Text(T("mb_pause"))
            } action: { engine.setPaused(!engine.config.paused) }
            VStack(alignment: .leading, spacing: 4) {
                Text(T("mb_resist", ["v": String(format: "%.2f", engine.config.delay)]))
                Slider(value: Binding(get: { engine.config.delay }, set: { engine.config.delay = ($0 / 0.05).rounded() * 0.05 }), in: 0...1.5)
                    .controlSize(.mini)
            }
            .padding(.leading, 32).padding(.trailing, 10).padding(.top, 5).padding(.bottom, 7)
            divider
            row(indent: true) { Text(T("mb_open")) } action: { open() }
            row(indent: true) { Text(T("mb_reconnect")) } action: { engine.reconnect() }
            divider
            row(indent: true) { Text(T("mb_quit")) } action: { NSApp.terminate(nil) }
        }
        .font(.system(size: 13))
        .padding(5)
        .frame(width: 280)
        .themed(engine.config.accent)
    }

    private var divider: some View { Rectangle().fill(pal.line).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4) }

    private func row<C: View>(indent: Bool = false, @ViewBuilder _ content: () -> C, action: @escaping () -> Void) -> some View {
        MenuRow(indent: indent, content: content(), action: action)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuRow<C: View>: View {
    var indent: Bool
    var content: C
    var action: () -> Void
    @State private var hover = false
    @Environment(\.ac) var ac
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.leading, indent ? 32 : 10).padding(.trailing, 10).frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? ac.opacity(0.32) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The four menu bar icons from the design: connected, controlling (filled), disconnected (dashed), attention.
enum MenuIcon {
    static func image(_ s: LinkStatus) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 14), flipped: true) { _ in
            NSColor.black.setStroke(); NSColor.black.setFill()
            let lw: CGFloat = 1.4
            if s.needsAttention {
                let r = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 10, height: 7), xRadius: 1.5, yRadius: 1.5)
                r.lineWidth = lw; r.stroke()
                NSBezierPath(ovalIn: NSRect(x: 10, y: 4.5, width: 9, height: 9)).fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                let bang = NSBezierPath(); bang.move(to: NSPoint(x: 14.5, y: 6.6)); bang.line(to: NSPoint(x: 14.5, y: 9.6))
                bang.move(to: NSPoint(x: 14.5, y: 11.2)); bang.line(to: NSPoint(x: 14.5, y: 11.6))
                bang.lineWidth = lw; bang.stroke()
                return true
            }
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 8, y: 8)); back.line(to: NSPoint(x: 2.5, y: 8))
            back.appendArc(withCenter: NSPoint(x: 2.5, y: 6.5), radius: 1.5, startAngle: 90, endAngle: 180)
            back.line(to: NSPoint(x: 1, y: 2.5))
            back.appendArc(withCenter: NSPoint(x: 2.5, y: 2.5), radius: 1.5, startAngle: 180, endAngle: 270)
            back.line(to: NSPoint(x: 9.5, y: 1))
            back.appendArc(withCenter: NSPoint(x: 9.5, y: 2.5), radius: 1.5, startAngle: 270, endAngle: 360)
            back.line(to: NSPoint(x: 11, y: 5.5))
            back.lineWidth = lw; back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 8, y: 5.5, width: 11, height: 7.5), xRadius: 1.5, yRadius: 1.5)
            front.lineWidth = lw
            switch s {
            case .controlling: front.fill(); front.stroke()
            case .connected: front.stroke()
            default: front.setLineDash([2, 2], count: 2, phase: 0); front.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
