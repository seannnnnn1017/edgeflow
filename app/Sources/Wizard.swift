// First-run setup and "Add Computer": welcome → permissions → choose → install → name → place.

import AppKit
import SwiftUI

enum WizPage { case welcome, perms, choose, pair, ssh, progress, name, place }

final class WizardModel: ObservableObject {
    @Published var page: WizPage = .welcome
    @Published var addMode = false
    @Published var selected: Found?
    @Published var manualIP = ""
    @Published var method = "pair"            // pair | ssh
    @Published var pairOS = "linux"
    @Published var copied = false
    @Published var host = ""
    @Published var user = ""
    @Published var pass = ""
    @Published var showPass = false
    @Published var testing = false
    @Published var test: SSHInstall.TestResult?
    @Published var logOpen = false
    @Published var name = ""
    @Published var icon = "desktop"
    @Published var tryState = "wait"           // wait | over | back
    var deviceId: String?
    var crossingMark = Date()

    func start(add: Bool) {
        addMode = add
        page = add ? .choose : .welcome
        selected = nil; manualIP = ""; method = "pair"; test = nil; pass = ""; tryState = "wait"; deviceId = nil
    }

    var target: String { selected?.ip ?? manualIP.trimmingCharacters(in: .whitespaces) }
    var sshAvailable: Bool { selected?.ssh == true || (!manualIP.isEmpty && selected == nil) }
    var stepNumber: Int {
        switch page { case .welcome: 1; case .perms: 2; case .choose: 3; case .pair, .ssh, .progress, .name: 4; case .place: 5 }
    }
}

struct WizardView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject var w: WizardModel
    var finish: () -> Void
    @Environment(\.pal) var pal
    @Environment(\.ac) var ac

    var body: some View {
        VStack(spacing: 0) {
            stepBar.padding(.horizontal, 40).padding(.top, 12)   // + 28 pt title bar = 40 from the top
            ScrollView {
                Group {
                    switch w.page {
                    case .welcome: welcome
                    case .perms: perms
                    case .choose: choose
                    case .pair: pair
                    case .ssh: ssh
                    case .progress: progress
                    case .name: naming
                    case .place: place
                    }
                }
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(pal.div).frame(height: 1)
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(pal.content.ignoresSafeArea())
        .onChange(of: engine.sessionTick) { _, _ in sessionMoved() }
        .onChange(of: engine.crossings.count) { _, _ in crossed() }
    }

    // MARK: step bar

    private var stepBar: some View {
        let nums = w.addMode ? [3, 4, 5] : [1, 2, 3, 4, 5]
        return HStack(spacing: 6) {
            ForEach(nums, id: \.self) { n in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).frame(height: 3)
                        .foregroundStyle(n < w.stepNumber ? ac.opacity(0.55) : n == w.stepNumber ? ac : pal.line)
                    Text(T("s\(n)")).font(.system(size: 11)).foregroundStyle(n <= w.stepNumber ? pal.fg : pal.mut)
                }
            }
        }
    }

    // MARK: 1 welcome

    private var welcome: some View {
        VStack(spacing: 20) {
            AppMark()
            VStack(spacing: 8) {
                Text(T("w_title")).font(.system(size: 24, weight: .bold))
                Text(T("tagline")).font(.system(size: 14)).foregroundStyle(pal.mut).multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            VStack(spacing: 8) {
                point("arrow.left.arrow.right", T("w_p1"))
                point("doc.on.clipboard", T("w_p2"))
                point("command", T("w_p3"))
            }
            .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity).padding(.top, 16)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).accentText().frame(width: 22)
            Text(text).font(.system(size: 13.5))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(pal.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(pal.line))
    }

    // MARK: 2 permissions

    private var perms: some View {
        let rows: [(String, String, String, String, Bool, String?)] = [
            ("ax", "accessibility", T("p_ax"), T("p_ax_why"), true, T("p_ax_hint")),
            ("lan", "network", T("p_lan"), T("p_lan_why"), true, nil),
            ("desk", "folder", T("p_desk"), T("p_desk_why"), false, nil),
            ("login", "power", T("p_login"), T("p_login_why"), false, nil),
        ]
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(T("p_title")).font(.system(size: 20, weight: .bold))
                Text(T("p_lead")).foregroundStyle(pal.mut)
            }
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    let st = engine.perms[r.0] ?? .none
                    if i > 0 { Rectangle().fill(pal.line).frame(height: 1) }
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(icon: r.1)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(r.2).fontWeight(.semibold)
                                Text(r.4 ? T("required") : T("optional")).font(.system(size: 10.5)).foregroundStyle(pal.mut)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 4).fill(pal.chip))
                            }
                            Text(r.3).font(.system(size: 12)).foregroundStyle(pal.mut).fixedSize(horizontal: false, vertical: true)
                            if let hint = r.5 {
                                Label(hint, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(pal.mut)
                            }
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                Circle().fill(permColor(st)).frame(width: 7, height: 7)
                                Text(T("st_\(st.rawValue)")).font(.system(size: 12)).foregroundStyle(permColor(st))
                            }
                            if st == .none || st == .deny {
                                ChipButton(title: r.0 == "login" ? T("p_login_btn") : T("openSettings")) { engine.requestPermission(r.0) }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(pal.line))
        }
    }

    private func permColor(_ s: PermState) -> Color {
        switch s { case .none: pal.mut; case .wait: DotColor.orange; case .ok: DotColor.green; case .deny: DotColor.red }
    }

    // MARK: 3 choose

    private var choose: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(T("c_title")).font(.system(size: 20, weight: .bold))
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if engine.searching { Spinner() }
                    Text(engine.searching ? T("c_searching") : T("c_found", ["n": "\(engine.found.count)"]))
                        .font(.system(size: 12)).foregroundStyle(pal.mut)
                    Spacer()
                    if !engine.searching {
                        Button(T("c_rescan")) { engine.discovery.start() }.buttonStyle(.plain).font(.system(size: 12)).accentText()
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                ForEach(engine.found) { f in
                    Rectangle().fill(pal.line).frame(height: 1)
                    Button { w.selected = f; w.manualIP = "" } label: {
                        HStack(spacing: 12) {
                            Image(systemName: f.os == "windows" ? "pc" : "desktopcomputer").font(.system(size: 18)).foregroundStyle(pal.mut).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).fontWeight(.semibold)
                                (Text(f.osv.isEmpty ? "—" : f.osv) + Text(" · ") + Text(f.ip).font(.system(size: 11.5, design: .monospaced)))
                                    .font(.system(size: 11.5)).foregroundStyle(pal.mut)
                            }
                            Spacer()
                            if f.ssh {
                                Text(T("c_ssh_tag")).font(.system(size: 10.5)).accentText()
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(ac.opacity(0.16)))
                            }
                            Image(systemName: w.selected == f ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 17)).foregroundStyle(w.selected == f ? ac : pal.mut)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(w.selected == f ? ac.opacity(0.1) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !engine.searching && engine.found.isEmpty {
                    Rectangle().fill(pal.line).frame(height: 1)
                    VStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 22)).foregroundStyle(pal.mut)
                        Text(T("c_none_title")).fontWeight(.semibold)
                        Text(T("c_none")).font(.system(size: 12)).foregroundStyle(pal.mut).multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 22).padding(.horizontal, 20).frame(maxWidth: .infinity)
                }
                Rectangle().fill(pal.line).frame(height: 1)
                HStack(spacing: 10) {
                    Image(systemName: "pencil").foregroundStyle(pal.mut)
                    TextField(T("c_manual") + " · " + T("c_manual_ph"), text: $w.manualIP)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                        .onChange(of: w.manualIP) { _, v in if !v.isEmpty { w.selected = nil } }
                }
                .padding(.horizontal, 14).frame(height: 46)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(pal.line))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                Text(T("c_method")).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.mut)
                HStack(spacing: 10) {
                    methodCard(id: "pair", icon: "terminal", title: T("m_pair"), desc: T("m_pair_desc"), rec: true, enabled: true)
                    methodCard(id: "ssh", icon: "key", title: T("m_ssh"),
                               desc: w.target.isEmpty ? T("m_ssh_need") : w.sshAvailable ? T("m_ssh_desc") : T("m_ssh_no"),
                               rec: false, enabled: !w.target.isEmpty && w.sshAvailable)
                }
            }
        }
        .onAppear { if engine.found.isEmpty && !engine.searching { engine.discovery.start() } }
    }

    private func methodCard(id: String, icon: String, title: String, desc: String, rec: Bool, enabled: Bool) -> some View {
        Button { if enabled { w.method = id } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.system(size: 18)).accentText()
                    Spacer()
                    if rec {
                        Text(T("m_rec")).font(.system(size: 10.5)).accentText()
                            .padding(.horizontal, 7).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(ac.opacity(0.16)))
                    }
                }
                Text(title).fontWeight(.semibold).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text(desc).font(.system(size: 12)).foregroundStyle(pal.mut)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(w.method == id ? ac : pal.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: 4a pairing command

    private var pair: some View {
        let s = engine.session
        let cmd = s?.command(macIP: engine.macIP) ?? ""
        let expired = s?.state == .expired
        return VStack(alignment: .leading, spacing: 16) {
            Text(T("pr_title")).font(.system(size: 20, weight: .bold))
            Segmented(options: [("linux", "Linux"), ("windows", "Windows")], value: Binding(get: { w.pairOS }, set: { os in
                w.pairOS = os; _ = engine.newSession(os: os)
            }), height: 26)
            HStack(spacing: 10) {
                Text(cmd).font(.system(size: 12.5, design: .monospaced)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).opacity(expired ? 0.4 : 1)
                ChipButton(icon: w.copied ? "checkmark" : "doc.on.doc", title: w.copied ? T("pr_copied") : T("pr_copy")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
                    w.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { w.copied = false }
                }
            }
            .padding(.vertical, 12).padding(.leading, 16).padding(.trailing, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(pal.field))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(pal.line))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.circle").font(.system(size: 15))
                Text(T(w.pairOS == "windows" ? "pr_win_where" : "pr_linux_where")).lineSpacing(2)
            }
            .foregroundStyle(pal.mut)
            HStack(spacing: 10) {
                if expired {
                    Image(systemName: "clock").font(.system(size: 17)).foregroundStyle(DotColor.orange)
                    Text(T("pr_expired"))
                    Spacer()
                    PrimaryButton(title: T("pr_new"), height: 28) { _ = engine.newSession(os: w.pairOS) }
                } else if s?.state == .installing || s?.state == .done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(DotColor.green)
                    Text(T("pr_connected"))
                    Spacer()
                } else {
                    WaitingDots()
                    Text(T("pr_waiting"))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        let left = max(0, Int((s?.expires ?? .now).timeIntervalSince(tl.date)))
                        Text(T("pr_expires", ["t": String(format: "%d:%02d", left / 60, left % 60)]))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.mut)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(pal.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(pal.line))
        }
    }

    // MARK: 4b SSH

    private var ssh: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(T("sh_title")).font(.system(size: 20, weight: .bold))
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { field(T("sh_host"), $w.host, mono: true).gridCellColumns(2) }
                GridRow(alignment: .top) {
                    field(T("sh_user"), $w.user, placeholder: NSUserName() == "" ? "" : "user")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(T("sh_pass")).font(.system(size: 12)).foregroundStyle(pal.mut)
                        ZStack(alignment: .trailing) {
                            Group {
                                if w.showPass { TextField("", text: $w.pass) } else { SecureField("", text: $w.pass) }
                            }
                            .textFieldStyle(.plain).padding(.leading, 12).padding(.trailing, 54).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(pal.field))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pal.line))
                            Button(w.showPass ? T("sh_hide") : T("sh_show")) { w.showPass.toggle() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(pal.mut)
                                .padding(.horizontal, 8).frame(height: 22).background(RoundedRectangle(cornerRadius: 6).fill(pal.chip)).padding(.trailing, 6)
                        }
                        Text(T("sh_note")).font(.system(size: 11.5)).foregroundStyle(pal.mut)
                    }
                }
            }
            HStack(spacing: 12) {
                ChipButton(icon: "cable.connector", title: w.testing ? T("sh_testing") : T("sh_test")) { runTest() }
                    .disabled(w.testing || w.host.isEmpty).opacity(w.testing || w.host.isEmpty ? 0.5 : 1)
                if w.testing { Spinner() }
                if let t = w.test { Text(testText(t)).font(.system(size: 12.5)).foregroundStyle(testColor(t)) }
            }
        }
        .onAppear { if w.host.isEmpty { w.host = w.target } }
    }

    private func field(_ label: String, _ text: Binding<String>, mono: Bool = false, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(pal.mut)
            TextField(placeholder, text: text).textFieldStyle(.plain)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(pal.field))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pal.line))
        }
    }

    private func runTest() {
        w.testing = true; w.test = nil
        let (h, u, p) = (w.host, w.user, w.pass)
        DispatchQueue.global().async {
            let r = SSHInstall.test(host: h, user: u, pass: p)
            DispatchQueue.main.async { w.testing = false; w.test = r }
        }
    }

    private func testText(_ t: SSHInstall.TestResult) -> String {
        switch t {
        case let .ok(_, osv, name): T("sh_ok", ["os": osv, "name": name])
        case .wrongPassword: T("sh_err_pass")
        case .unreachable: T("sh_err_unreach")
        case .noSSH: T("sh_err_nossh")
        }
    }
    private func testColor(_ t: SSHInstall.TestResult) -> Color { if case .ok = t { return DotColor.green }; return DotColor.red }

    // MARK: 4c progress

    private var progress: some View {
        let s = engine.session
        let name = s?.deviceId.flatMap { engine.computer($0)?.name } ?? w.target
        let failed = s?.state == .failed
        return VStack(alignment: .leading, spacing: 16) {
            Text(s?.state == .done ? T("ip_done", ["name": name]) : T("ip_title", ["name": name.isEmpty ? "…" : name]))
                .font(.system(size: 20, weight: .bold))
            VStack(spacing: 0) {
                ForEach(0..<6) { i in
                    let st = s?.steps[i] ?? .pending
                    if i > 0 { Rectangle().fill(pal.line).frame(height: 1) }
                    HStack(alignment: .top, spacing: 12) {
                        Group {
                            switch st {
                            case .running: Spinner(size: 13)
                            case .ok: Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(DotColor.green)
                            case .fail: Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(DotColor.red)
                            case .pending: Circle().strokeBorder(pal.line, lineWidth: 1.5).frame(width: 12, height: 12)
                            }
                        }
                        .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(T("i\(i + 1)")).foregroundStyle(st == .pending ? pal.mut : pal.fg)
                            if st == .fail {
                                Text((s?.failMessage.isEmpty ?? true) ? T("ip_fail") : s!.failMessage).font(.system(size: 12)).foregroundStyle(pal.mut)
                            }
                        }
                        .padding(.top, 1)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(pal.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(pal.line))
            if failed {
                HStack(spacing: 8) {
                    PrimaryButton(title: T("ip_retry"), height: 28) { retry() }
                    ChipButton(title: T("ip_copylog")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString((s?.log ?? []).joined(separator: "\n"), forType: .string)
                        engine.say(T("ip_copied"))
                    }
                }
            }
            Button { w.logOpen.toggle() } label: {
                Label(w.logOpen ? T("ip_log_hide") : T("ip_log_show"), systemImage: w.logOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12)).foregroundStyle(pal.mut)
            }
            .buttonStyle(.plain)
            if w.logOpen {
                Text((s?.log ?? []).isEmpty ? "—" : (s?.log ?? []).joined(separator: "\n"))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.mut).lineSpacing(4).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(pal.field))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(pal.line))
            }
        }
    }

    private func retry() {
        if let id = engine.session?.deviceId, let c = engine.computer(id) { engine.config.computers.removeAll { $0.id == c.id } }
        if w.method == "ssh" {
            engine.installOverSSH(host: w.host, user: w.user, pass: w.pass, os: testedOS)
        } else {
            _ = engine.newSession(os: w.pairOS)
            w.page = .pair
        }
    }

    private var testedOS: String { if case let .ok(os, _, _) = w.test { return os }; return w.selected?.os == "windows" ? "windows" : "linux" }

    // MARK: 4d name

    private var naming: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(T("nm_title")).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            field(T("nm_name"), $w.name)
            VStack(alignment: .leading, spacing: 6) {
                Text(T("nm_icon")).font(.system(size: 12)).foregroundStyle(pal.mut)
                HStack(spacing: 10) {
                    ForEach([("desktop", "desktopcomputer", T("ic_desktop")), ("laptop", "laptopcomputer", T("ic_laptop")),
                             ("server", "server.rack", T("ic_server"))], id: \.0) { id, sf, label in
                        Button { w.icon = id } label: {
                            VStack(spacing: 6) {
                                Image(systemName: sf).font(.system(size: 22)).foregroundStyle(w.icon == id ? ac : pal.mut)
                                Text(label).font(.system(size: 12.5))
                            }
                            .padding(.vertical, 14).frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).fill(pal.card))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(w.icon == id ? ac : pal.line, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 5 place + try

    private var place: some View {
        let c = w.deviceId.flatMap { engine.computer($0) } ?? engine.config.computers.last
        let name = c?.name ?? "lab_pc"
        let v: (String, Color, String) = w.tryState == "wait" ? ("arrow.right", ac, T("pl_try", ["name": name]))
            : w.tryState == "over" ? ("arrow.left", ac, T("pl_ok1")) : ("checkmark.circle.fill", DotColor.green, T("pl_ok2"))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(T("pl_title")).font(.system(size: 20, weight: .bold))
                Text(T("pl_lead")).foregroundStyle(pal.mut)
            }
            LayoutMap(glowSide: w.tryState == "back" ? nil : c?.side)
                .overlay { if w.tryState == "back" { Confetti() } }
            HStack(spacing: 10) {
                Image(systemName: v.0).font(.system(size: 18, weight: .semibold)).foregroundStyle(v.1)
                    .transition(.scale.combined(with: .opacity)).id(w.tryState)
                Text(v.2)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(pal.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(pal.line))
            .animation(.spring(duration: 0.3), value: w.tryState)
        }
        .onAppear { w.crossingMark = Date() }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 12) {
            if showBack { Button(T("back")) { back() }.buttonStyle(.plain).padding(.horizontal, 14).frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(pal.line)) }
            Spacer()
            if w.page == .welcome || (w.addMode && w.page == .choose) {
                Button { finish() } label: {
                    HStack(spacing: 4) { Text(w.addMode ? T("cancel") : T("skip")); if !w.addMode { Image(systemName: "forward.fill").font(.system(size: 10)) } }
                        .font(.system(size: 12.5)).foregroundStyle(pal.mut)
                }
                .buttonStyle(.plain).padding(.horizontal, 10)
            }
            if let (label, enabled) = primary { PrimaryButton(title: label, disabled: !enabled) { next() } }
        }
    }

    private var showBack: Bool {
        switch w.page {
        case .welcome, .progress, .place: false
        case .choose: !w.addMode
        default: true
        }
    }

    private var primary: (String, Bool)? {
        switch w.page {
        case .welcome: (T("start"), true)
        case .perms: (T("next"), engine.perms["ax"] == .ok && engine.perms["lan"] == .ok)
        case .choose: (T("next"), w.method == "pair" || !w.target.isEmpty)
        case .pair: nil
        case .ssh: (T("sh_start"), { if case .ok = w.test { return true }; return false }())
        case .progress: (T("next"), engine.session?.state == .done)
        case .name: (T("next"), !w.name.trimmingCharacters(in: .whitespaces).isEmpty)
        case .place: (T("done"), true)
        }
    }

    private func back() {
        switch w.page {
        case .perms: w.page = .welcome
        case .choose: w.page = .perms
        case .pair, .ssh: w.page = .choose
        case .name: w.page = .progress
        default: break
        }
    }

    private func next() {
        switch w.page {
        case .welcome: w.page = .perms
        case .perms: w.page = .choose
        case .choose:
            if w.method == "ssh" { w.page = .ssh }
            else {
                w.pairOS = w.selected?.os == "windows" ? "windows" : "linux"
                _ = engine.newSession(os: w.pairOS)
                w.page = .pair
            }
        case .ssh:
            engine.installOverSSH(host: w.host, user: w.user, pass: w.pass, os: testedOS)
            w.page = .progress
        case .progress:
            if let id = engine.session?.deviceId, let c = engine.computer(id) { w.deviceId = id; w.name = c.name; w.icon = c.icon }
            w.page = .name
        case .name:
            if let id = w.deviceId { engine.update(id) { $0.name = w.name.trimmingCharacters(in: .whitespaces); $0.icon = w.icon } }
            w.tryState = "wait"
            w.page = .place
        case .place:
            finish()
        case .pair:
            break   // moves on by itself once the other computer connects
        }
    }

    private func sessionMoved() {
        guard let s = engine.session else { return }
        if w.page == .pair && (s.state == .installing || s.state == .done) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if w.page == .pair { w.page = .progress } }
        }
    }

    /// Real crossings from Deskflow's log drive the "try it" card.
    private func crossed() {
        guard w.page == .place, let last = engine.crossings.last, last.at > w.crossingMark else { return }
        let mac = engine.macScreen
        if w.tryState == "wait" && last.from == mac { w.tryState = "over" }
        else if w.tryState == "over" && last.to == mac { w.tryState = "back" }
    }
}

struct Confetti: View {
    @State private var go = false
    private let colors = swatchHex.prefix(5).map { Color(nsColor: NSColor(srgbRed: rgb($0)[0], green: rgb($0)[1], blue: rgb($0)[2], alpha: 1)) }
    var body: some View {
        ZStack {
            ForEach(0..<18, id: \.self) { i in
                let a = Double(i) / 18 * 2 * .pi, r = 60.0 + Double(i * 37 % 45)
                RoundedRectangle(cornerRadius: 2).fill(colors[i % 5]).frame(width: 6, height: 9)
                    .rotationEffect(.degrees(go ? Double(i * 47 % 360) : 0))
                    .offset(x: go ? cos(a) * r : 0, y: go ? sin(a) * r * 0.75 : 0)
                    .opacity(go ? 0 : 1)
                    .animation(.easeOut(duration: 1.1).delay(Double(i % 4) * 0.04), value: go)
            }
        }
        .allowsHitTesting(false)
        .onAppear { go = true }
    }
}
