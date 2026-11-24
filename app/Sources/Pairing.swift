// Pairing and the settings channel to the other computers, over the LAN.
//
//   GET  /i/<token>          Linux installer (bash), templated with this Mac's URL + token
//   GET  /w/<token>          Windows installer (PowerShell)
//   POST /p/<token>          the installer says hello (host, OS) → sealed bundle: its Deskflow
//                            certificate, this Mac's fingerprint, a device key
//   POST /s/<token>          install progress (step, state, message)
//   GET  /f/<name>           helper files (integrity: sha256s inside the sealed bundle)
//   GET  /c/<device>?ts&sig  a paired helper polls its settings (HMAC with its device key)
//   GET  /d/<device>/<file>  its sound files
//
// The pasted command carries the installer's sha256 and a one-time secret that never goes
// over the network: the bundle is AES-encrypted and HMAC'd with it, so someone else on the
// network can neither change the installer nor read or forge the certificates.

import Foundation
import Network

struct HTTPRequest {
    var method = "", path = "", query: [String: String] = [:], body = Data(), remoteIP = ""
    var form: [String: String] { parseForm(String(decoding: body, as: UTF8.self)) }
}

struct HTTPResponse {
    var status = 200, type = "text/plain; charset=utf-8", body = Data()
    static func text(_ s: String, _ status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, body: Data(s.utf8)) }
    static func json(_ o: Any) -> HTTPResponse {
        HTTPResponse(type: "application/json", body: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data())
    }
    static let notFound = text("not found\n", 404)
    static let denied = text("denied\n", 403)
}

func parseForm(_ s: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        let k = kv[0].removingPercentEncoding ?? kv[0]
        let v = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
        out[k] = v
    }
    return out
}

/// Tiny HTTP/1.0 server on Network.framework: one request per connection.
final class HTTPServer {
    private var listener: NWListener?
    private let q = DispatchQueue(label: "edgeflow.http")
    var handler: ((HTTPRequest) -> HTTPResponse)?
    private(set) var failed = false

    func start(port: Int) {
        guard listener == nil, let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: UInt16(port))) else {
            failed = true; return
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self] s in if case .failed = s { self?.failed = true } }
        l.start(queue: q)
        listener = l
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: q)
        var buf = Data()
        var remote = ""
        if case let .hostPort(host, _) = c.endpoint { remote = "\(host)".components(separatedBy: "%").first ?? "" }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
                if let data { buf.append(data) }
                if buf.count > 4 << 20 || err != nil { c.cancel(); return }
                if let req = Self.parse(buf, remote: remote) {
                    let resp = self?.handler?(req) ?? .notFound
                    var head = "HTTP/1.0 \(resp.status) OK\r\nContent-Type: \(resp.type)\r\nContent-Length: \(resp.body.count)\r\nConnection: close\r\n\r\n"
                    if resp.status != 200 { head = head.replacingOccurrences(of: " OK\r\n", with: " ERR\r\n") }
                    c.send(content: Data(head.utf8) + resp.body, completion: .contentProcessed { _ in c.cancel() })
                } else if done {
                    c.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    /// Returns a request once headers and the full body have arrived.
    static func parse(_ buf: Data, remote: String) -> HTTPRequest? {
        guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return HTTPRequest(method: "BAD") }
        var len = 0
        for h in head.dropFirst() where h.lowercased().hasPrefix("content-length:") {
            len = Int(h.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = buf[r.upperBound...]
        guard body.count >= len else { return nil }
        var req = HTTPRequest(method: String(first[0]), body: Data(body.prefix(len)), remoteIP: remote)
        let target = String(first[1]).split(separator: "?", maxSplits: 1).map(String.init)
        req.path = target[0]
        if target.count > 1 { req.query = parseForm(target[1]) }
        return req
    }
}

// MARK: - Pairing sessions

enum StepState: Equatable { case pending, running, ok, fail }

final class PairSession {
    let token = Crypto.randomHex(5)          // in the URL
    let secret = Crypto.randomHex(16)        // only in the pasted command
    let created = Date()
    var os: String                           // "linux" | "windows"
    var state: State = .waiting
    var steps = [StepState](repeating: .pending, count: 6)
    var failMessage = ""
    var log: [String] = []
    var deviceId: String?                    // set once the other computer says hello
    var viaSSH = false

    enum State: Equatable { case waiting, installing, done, failed, expired }

    init(os: String) { self.os = os }

    var expires: Date { created.addingTimeInterval(600) }
    var isExpired: Bool { state == .waiting && Date() > expires }
    var failedStep: Int? { steps.firstIndex(of: .fail) }

    func command(macIP: String) -> String {
        let url = "http://\(macIP):\(Env.pairPort)"
        let script = Payload.installer(os: os, url: url, token: token)
        guard script.count > 100 else { return "" }   // never hand out a command for a missing installer
        let sha = Crypto.sha256Hex(script)
        if os == "windows" {
            return "$f=\"$env:TEMP\\edgeflow.ps1\";iwr -useb \(url)/w/\(token) -OutFile $f;if((Get-FileHash $f).Hash -eq '\(sha.uppercased())'){powershell -NoProfile -ExecutionPolicy Bypass -File $f \(secret)}else{'Edgeflow: download check failed'}"
        }
        return "curl -fsSL \(url)/i/\(token) -o /tmp/edgeflow.sh && echo '\(sha)  /tmp/edgeflow.sh' | sha256sum -c --quiet && bash /tmp/edgeflow.sh \(secret)"
    }
}

// MARK: - Files served to the other computer

enum Payload {
    static let helperFiles = ["edge-fx.py", "edgeflow-helper.py", "deskflow-start.sh", "edgeflow-helper.ps1"]

    static func file(_ name: String) -> Data? {
        guard helperFiles.contains(name) || name.hasPrefix("install-") else { return nil }
        return try? Data(contentsOf: Env.payloadDir.appendingPathComponent(name))
    }

    static func installer(os: String, url: String, token: String) -> Data {
        let name = os == "windows" ? "install-windows.ps1" : "install-linux.sh"
        var s = String(decoding: file(name) ?? Data(), as: UTF8.self)
        s = s.replacingOccurrences(of: "@@URL@@", with: url)
            .replacingOccurrences(of: "@@TOKEN@@", with: token)
            .replacingOccurrences(of: "@@VERSION@@", with: Env.version)
        return Data(s.utf8)   // the .ps1 on disk already has CRLF and a UTF-8 BOM (kept by String round-trip)
    }

    static var hashes: [String: String] {
        var h: [String: String] = [:]
        for f in helperFiles { if let d = file(f) { h[f] = Crypto.sha256Hex(d) } }
        return h
    }
}
