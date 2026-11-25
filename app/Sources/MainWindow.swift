// Main window, sidebar layout: Computers & Layout, Switching, Sound, Effects, Key Mapping, Clipboard.

import AppKit
import SwiftUI

enum Tab: String, CaseIterable {
    case computers, feel, sound, fx, keys, clip
    var icon: String {
        switch self {
        case .computers: "display.2"; case .feel: "hand.draw"; case .sound: "waveform"
        case .fx: "sparkles"; case .keys: "command"; case .clip: "doc.on.clipboard"
        }
    }
    var title: String {
        switch self {
        case .computers: T("sec_comp"); case .feel: T("sec_feel"); case .sound: T("sec_sound")
        case .fx: T("sec_fx"); case .keys: T("sec_keys"); case .clip: T("sec_clip")
        }
    }
}

struct Badge {
    var dot: Color, l1: String, l2: String, pulse: Bool

    init(_ e: Engine) {
        let c0 = e.config.computers.first
        let ip = c0.map { e.live[$0.id]?.ip ?? $0.ip } ?? ""
        switch e.status {
        case let .connected(n): self = .init(DotColor.green, T("b_connected", ["name": n]), ip, true)
        case let .controlling(n): self = .init(DotColor.green, T("b_controlling", ["name": n]), ip, true)
        case let .waiting(n): self = .init(DotColor.orange, T("b_waiting", ["name": n]), ip, false)
        case .offnet: self = .init(DotColor.orange, T("b_offnet"), ip, false)
        case .noperm: self = .init(DotColor.red, T("b_perm"), "", false)
        case .paused: self = .init(DotColor.grey, T("b_paused"), "", false)
        case .portbusy: self = .init(DotColor.orange, T("b_port"), "", false)
        case .none: self = .init(DotColor.grey, T("b_none"), "", false)
        }
    }
    private init(_ d: Color, _ a: String, _ b: String, _ p: Bool) { dot = d; l1 = a; l2 = b; pulse = p }
}

struct MainView: View {
    @EnvironmentObject var engine: Engine
    var addComputer: () -> Void
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["EF_TAB"] ?? "") ?? .computers  // EF_TAB: debug/screenshots
    @State private var detail: String?
    @State private var confirmRemove = false
    @Environment(\.pal) var pal
    @Environment(\.ac) var ac

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(pal.div).frame(width: 1)
            content
        }
        .overlay { if let id = detail, let c = engine.computer(id) { detailPanel(c) } }
        .background(hotkeys)
    }

    // ⌘1…⌘6
    private var hotkeys: some View {
        ZStack {
            ForEach(Array(Tab.allCases.enumerated()), id: \.offset) { i, t in
                Button("") { tab = t }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    // MARK: sidebar

    private var sidebar: some View {
        let b = Badge(engine)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Tab.allCases.enumerated()), id: \.offset) { i, t in
                Button { tab = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).font(.system(size: 14)).frame(width: 20)
                            .foregroundStyle(tab == t ? ac : pal.mut)
                        Text(t.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("⌘\(i + 1)").font(.system(size: 11)).monospacedDigit().foregroundStyle(pal.mut)
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? pal.navOn : pal.navOff)
                        .shadow(color: .black.opacity(tab == t ? 0.2 : 0), radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    StatusDot(color: b.dot, pulse: b.pulse)
                    Text(b.l1).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                if !b.l2.isEmpty { Text(b.l2).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.mut).padding(.leading, 15) }
                Text("Edgeflow v\(Env.version)").font(.system(size: 11)).foregroundStyle(pal.mut).padding(.top, 12)
            }
            .padding(.horizontal, 6)
        }
        .padding(.top, 24).padding(.horizontal, 12).padding(.bottom, 16)   // + 28 pt title bar
        .frame(width: 212)
    }

    // MARK: content

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edgeflow").font(.system(size: 19, weight: .bold))
                Text(T("tagline")).font(.system(size: 12.5)).foregroundStyle(pal.mut)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 16)
            if let bn = banner { bannerView(bn).padding(.horizontal, 24).padding(.bottom, 14) }
            Rectangle().fill(pal.div).frame(height: 1)
            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case .computers: computersSection
                    case .feel: feelCard
                    case .sound: soundCard
                    case .fx: fxCard
                    case .keys: keysCard
                    case .clip: clipCard
                    }
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
            }
            Rectangle().fill(pal.div).frame(height: 1)
            footer
        }
        .background(pal.content.ignoresSafeArea())
    }

    // MARK: banners

    private struct BannerSpec { var icon: String; var text: String; var desc: String; var btn: String; var color: Color; var act: () -> Void }

    private var banner: BannerSpec? {
        let n0 = engine.config.computers.first?.name ?? ""
        switch engine.status {
        case .noperm: return BannerSpec(icon: "exclamationmark.triangle.fill", text: T("bn_ax"), desc: T("bn_permlost"),
                                        btn: T("openSettings"), color: DotColor.orange) { engine.openAccessibilitySettings() }
        case .offnet: return BannerSpec(icon: "wifi.slash", text: T("bn_offnet", ["name": n0]), desc: "", btn: "", color: DotColor.orange) {}
        case .portbusy: return BannerSpec(icon: "nosign", text: T("bn_port"), desc: "", btn: T("bn_close"), color: DotColor.orange) { engine.freePort() }
        case .paused: return BannerSpec(icon: "pause.circle.fill", text: T("bn_paused"), desc: "", btn: T("bn_resume"), color: pal.mut) { engine.setPaused(false) }
        default: return nil
        }
    }

    private func bannerView(_ b: BannerSpec) -> some View {
        HStack(spacing: 12) {
            Image(systemName: b.icon).font(.system(size: 17)).foregroundStyle(b.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.text).fontWeight(.semibold)
                if !b.desc.isEmpty { Text(b.desc).font(.system(size: 12)).foregroundStyle(pal.mut) }
            }
            Spacer()
            if !b.btn.isEmpty { ChipButton(title: b.btn, action: b.act) }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(b.color == pal.mut ? pal.chip : b.color.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(b.color == pal.mut ? pal.line : b.color.opacity(0.4)))
    }

    // MARK: sections

    private var computersSection: some View {
        VStack(spacing: 12) {
            Card(spacing: 12) {
                CardHeader(icon: "display.2", title: T("sec_comp")) {
                    ChipButton(icon: "plus", title: T("add"), action: addComputer)
                }
                LayoutMap(onTap: { detail = $0.id; confirmRemove = false })
                Text(T("map_hint")).font(.system(size: 11.5)).foregroundStyle(pal.mut).frame(maxWidth: .infinity)
            }
            Card(spacing: 12) {
                CardHeader(icon: "play.circle", title: T("sec_prev"))
                let c0 = engine.config.computers.first
                LivePreview(cfg: engine.config, side: c0?.side ?? .right, remoteName: c0?.name ?? "lab_pc")
            }
        }
    }

    private var feelCard: some View {
        Card {
            CardHeader(icon: "hand.draw", title: T("sec_feel"))
            SliderRow(label: T("resist"), desc: T("resist_d"), value: $engine.config.delay, range: 0...1.5, step: 0.05,
                      format: { $0 < 0.05 ? T("none") : String(format: "%.2f %@", $0, T("sec")) })
            ToggleRow(label: T("charge"), desc: T("charge_d"), on: $engine.config.chargeSound)
                .disabled(!engine.config.soundEnabled || engine.config.delay < 0.05)
                .opacity(!engine.config.soundEnabled || engine.config.delay < 0.05 ? 0.4 : 1)
        }
    }

    private var soundCard: some View {
        Card {
            CardHeader(icon: "waveform", title: T("sec_sound")) { EFToggle(on: $engine.config.soundEnabled) }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(SoundTheme.allCases) { th in
                        let on = engine.config.theme == th.rawValue
                        Button { engine.config.theme = th.rawValue; engine.play("enter") } label: {
                            VStack(spacing: 6) {
                                Image(systemName: th.icon).font(.system(size: 18)).foregroundStyle(on ? ac : pal.mut)
                                Text(th.title).font(.system(size: 12))
                            }
                            .padding(.vertical, 12).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).fill(pal.chip))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? ac : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                SliderRow(label: T("vol"), value: $engine.config.volume, range: 0...1, step: 0.01,
                          format: { "\(Int(($0 * 100).rounded()))%" })
                HStack(spacing: 8) {
                    Text(T("listen")).font(.system(size: 12)).foregroundStyle(pal.mut).padding(.trailing, 4)
                    ChipButton(icon: "play.fill", title: T("l_enter")) { engine.play("enter") }
                    ChipButton(icon: "play.fill", title: T("l_back")) { engine.play("back") }
                    ChipButton(icon: "play.fill", title: T("l_charge")) { engine.play("charge") }
                }
            }
            .disabled(!engine.config.soundEnabled).opacity(engine.config.soundEnabled ? 1 : 0.4)
        }
    }

    private var fxCard: some View {
        Card {
            CardHeader(icon: "sparkles", title: T("sec_fx")) { EFToggle(on: $engine.config.effectEnabled) }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(T("fx_color"))
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(swatchHex.indices, id: \.self) { i in
                            let hex = swatchHex[i]
                            let on = engine.config.colorHex.caseInsensitiveCompare(hex) == .orderedSame
                            Button { engine.config.color = rgb(hex) } label: {
                                Circle().fill(Color(hex: UInt32(hex.dropFirst(), radix: 16)!)).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: on ? 0 : 1))
                                    .padding(2).overlay(Circle().strokeBorder(on ? Color(hex: UInt32(hex.dropFirst(), radix: 16)!) : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain).help(T(swatchNames[i]))
                        }
                        ColorPicker("", selection: Binding(get: { engine.config.accent }, set: { c in
                            if let n = NSColor(c).usingColorSpace(.sRGB) {
                                engine.config.color = [n.redComponent, n.greenComponent, n.blueComponent].map { (Double($0) * 100).rounded() / 100 }
                            }
                        }), supportsOpacity: false).labelsHidden().help(T("custom"))
                    }
                }
                SliderRow(label: T("fx_len"), value: $engine.config.duration, range: 0.3...1.6, step: 0.1,
                          format: { String(format: "%.1f %@", $0, T("sec")) })
                SliderRow(label: T("fx_thick"), value: $engine.config.glow, range: 0...160, step: 4,
                          format: { $0 < 1 ? T("off") : "\(Int($0)) px" })
                ToggleRow(label: T("ripple"), desc: T("ripple_d"), on: $engine.config.ripple)
                ToggleRow(label: T("chglow"), desc: T("chglow_d"), on: $engine.config.chargeGlow)
                HStack(spacing: 8) {
                    Text(T("preview")).font(.system(size: 12)).foregroundStyle(pal.mut).padding(.trailing, 4)
                    ChipButton(icon: "laptopcomputer", title: T("pv_mac")) { engine.previewMac() }
                    ChipButton(icon: "desktopcomputer", title: T("pv_rem")) { engine.previewRemote() }
                }
            }
            .disabled(!engine.config.effectEnabled).opacity(engine.config.effectEnabled ? 1 : 0.4)
        }
    }

    private var keysCard: some View {
        let win = engine.config.computers.first?.isWindows ?? false
        let imeKeys: [String] = ["caps": ["⇪"], "shift": ["⇧"], "ctrlspace": ["⌃", "Space"]][engine.config.ime] ?? ["⇪"]
        let rows: [([String], [String], String)] = [
            (["⌘"], ["Ctrl"], T("k_d1")), (imeKeys, [T("k_cn")], T("k_d2")), (["⌥"], ["Alt"], T("k_d3")),
            (["⌘", "⇧", "4"], [T("k_shot")], T("k_d4")), (["⌃"], [win ? "Win" : "Super"], win ? T("k_d5w") : T("k_d5l")),
        ]
        return Card(spacing: 12) {
            CardHeader(icon: "command", title: T("sec_keys"), desc: T("keys_d")) { EFToggle(on: $engine.config.macKeys) }
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    Rectangle().fill(pal.line).frame(height: 1)
                    HStack(spacing: 8) {
                        HStack(spacing: 4) { ForEach(r.0, id: \.self) { KeyCap(text: $0) } }.frame(width: 96, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(pal.mut).frame(width: 20)
                        HStack(spacing: 4) { ForEach(r.1, id: \.self) { KeyCap(text: $0, remote: true) } }.frame(width: 84, alignment: .leading)
                        Text(r.2).font(.system(size: 12)).foregroundStyle(pal.mut)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                }
                Rectangle().fill(pal.line).frame(height: 1)
                HStack {
                    Text(T("ime"))
                    Spacer()
                    Segmented(options: [("caps", "⇪"), ("shift", "⇧"), ("ctrlspace", "⌃ Space")], value: $engine.config.ime)
                }
                .padding(.top, 10)
            }
            .disabled(!engine.config.macKeys).opacity(engine.config.macKeys ? 1 : 0.4)
        }
    }

    private var clipCard: some View {
        Card(spacing: 14) {
            CardHeader(icon: "doc.on.clipboard", title: T("sec_clip"), desc: T("clip_d")) { EFToggle(on: $engine.config.clipboard) }
            ToggleRow(label: T("shot"), desc: T("shot_d"), on: Binding(get: { engine.config.screenshotToClipboard }, set: { v in
                engine.config.screenshotToClipboard = v
                if v { engine.clipboard.watchShots() }
            }))
            .disabled(!engine.config.clipboard).opacity(engine.config.clipboard ? 1 : 0.4)
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 14) {
            syncLabel
            Spacer()
            Button { engine.setLaunchAtLogin(engine.perms["login"] != .ok) } label: {
                HStack(spacing: 6) {
                    let on = engine.perms["login"] == .ok
                    RoundedRectangle(cornerRadius: 4).fill(on ? ac : .clear).frame(width: 14, height: 14)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? ac : pal.mut, lineWidth: 1))
                        .overlay { if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0x0B0D10)) } }
                    Text(T("login")).font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            PrimaryButton(title: T("reconnect"), icon: "arrow.clockwise", height: 26) { engine.reconnect() }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    @ViewBuilder private var syncLabel: some View {
        let old = engine.config.computers.first { engine.isOnline($0) && engine.helperOutdated($0) }
        HStack(spacing: 6) {
            if let c = old {
                Image(systemName: "arrow.up.circle").foregroundStyle(DotColor.orange)
                Text(T("helperold", ["name": c.name])).foregroundStyle(DotColor.orange)
                ChipButton(title: T("update")) { update(c) }
            } else {
                switch engine.sync {
                case .loading: Spinner(size: 11); Text(T("sync_load")).foregroundStyle(pal.mut)
                case .syncing: Spinner(size: 11); Text(T("sync_ing")).foregroundStyle(pal.mut)
                case let .ok(d):
                    Image(systemName: "checkmark.icloud").foregroundStyle(pal.mut)
                    Text(T("sync_ok", ["time": d.formatted(date: .omitted, time: .shortened)])).foregroundStyle(pal.mut)
                case let .fail(n):
                    Image(systemName: "icloud.slash").foregroundStyle(DotColor.orange)
                    Text(T("sync_fail", ["name": n])).foregroundStyle(DotColor.orange).lineLimit(1)
                    ChipButton(title: T("retry")) { engine.reconnect() }
                }
            }
        }
        .font(.system(size: 12))
    }

    // MARK: detail panel

    private func detailPanel(_ c: Computer) -> some View {
        let online = engine.isOnline(c)
        let kv: [(String, String, Bool, Color?)] = [
            (T("d_os"), c.osv, false, nil),
            (T("d_ip"), engine.live[c.id]?.ip ?? c.ip, true, nil),
            (T("d_status"), online ? T("online") : T("offline"), false, online ? DotColor.green : DotColor.grey),
            (T("d_last"), lastSeen(c), false, nil),
        ]
        return ZStack(alignment: .trailing) {
            Color.black.opacity(0.35).onTapGesture { detail = nil }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: c.sfIcon).font(.system(size: 20)).accentText()
                    Text(c.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Button { detail = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(pal.chip))
                    }
                    .buttonStyle(.plain)
                }
                VStack(spacing: 0) {
                    ForEach(kv.indices, id: \.self) { i in
                        if i > 0 { Rectangle().fill(pal.line).frame(height: 1) }
                        HStack(spacing: 10) {
                            Text(kv[i].0).font(.system(size: 12.5)).foregroundStyle(pal.mut)
                            Spacer()
                            if let d = kv[i].3 { Circle().fill(d).frame(width: 7, height: 7) }
                            Text(kv[i].1).font(.system(size: 12.5, design: kv[i].2 ? .monospaced : .default))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(pal.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(pal.line))
                if engine.helperOutdated(c) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.circle").foregroundStyle(DotColor.orange)
                        Text(T("helperold", ["name": c.name])).font(.system(size: 12.5))
                        Spacer()
                        ChipButton(title: T("update")) { update(c) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(DotColor.orange.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DotColor.orange.opacity(0.4)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("d_pos")).font(.system(size: 12)).foregroundStyle(pal.mut)
                    Segmented(options: [(Side.top, T("pos_top")), (.bottom, T("pos_bottom")), (.left, T("pos_left")), (.right, T("pos_right"))],
                              value: Binding(get: { c.side }, set: { engine.place(c.id, $0) }), fill: true, height: 26)
                }
                ToggleRow(label: T("d_keys"), desc: T("d_keys_d"),
                          on: Binding(get: { engine.config.keys(for: c) }, set: { v in engine.update(c.id) { $0.keys = v } }))
                SecondaryButton(title: T("d_reinstall"), icon: "arrow.counterclockwise") { update(c) }
                Spacer()
                if confirmRemove {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(T("d_confirm", ["name": c.name])).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer()
                            Button(T("cancel")) { confirmRemove = false }.buttonStyle(.plain).padding(.horizontal, 12).frame(height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pal.line))
                            Button { engine.remove(c); detail = nil; confirmRemove = false } label: {
                                Text(T("remove")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 12).frame(height: 28).background(RoundedRectangle(cornerRadius: 8).fill(DotColor.red))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(DotColor.red.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DotColor.red.opacity(0.4)))
                } else {
                    Button { confirmRemove = true } label: {
                        Text(T("d_remove")).font(.system(size: 13)).foregroundStyle(DotColor.red).frame(maxWidth: .infinity).frame(height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DotColor.red.opacity(0.45)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
            .frame(width: 340).frame(maxHeight: .infinity)
            .background(pal.content)
            .overlay(alignment: .leading) { Rectangle().fill(pal.div).frame(width: 1) }
            .shadow(color: .black.opacity(0.25), radius: 20, x: -10)
            .transition(.move(edge: .trailing))
        }
    }

    /// A helper that has never polled (the old hand-made setup) can't take an update command:
    /// re-pair it instead.
    private func update(_ c: Computer) {
        if engine.live[c.id] == nil { detail = nil; addComputer() } else { engine.reinstallHelper(c) }
    }

    private func lastSeen(_ c: Computer) -> String {
        guard let d = engine.live[c.id]?.lastSeen ?? c.lastSeen else { return "—" }
        return Date().timeIntervalSince(d) < 60 ? T("just_now") : d.formatted(date: .abbreviated, time: .shortened)
    }
}
