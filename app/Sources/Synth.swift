import Foundation

// MARK: - Sound synthesis

enum SoundTheme: String, CaseIterable, Identifiable {
    case crystal, soft, scifi, retro
    var id: String { rawValue }
    var title: String { T(self == .retro ? "st_pixel" : "st_\(rawValue)") }
    var icon: String {
        switch self {
        case .crystal: return "diamond"
        case .soft: return "cloud"
        case .scifi: return "bolt"
        case .retro: return "square.grid.2x2"
        }
    }
}

enum Synth {
    static let rate = 44100.0
    enum Wave { case sine, bell, fm, square }

    static func notes(_ freqs: [Double], dur: Double, gap: Double, decay: Double, wave: Wave, volume: Double = 0.35) -> [Double] {
        let total = Int(rate * (dur + gap * Double(freqs.count - 1)))
        var buf = [Double](repeating: 0, count: total)
        for (n, f) in freqs.enumerated() {
            let start = Int(rate * gap * Double(n))
            let len = Int(rate * dur)
            for i in 0..<len {
                let t = Double(i) / rate
                let env = min(1, t / 0.006) * exp(-t * decay)
                let w = 2 * Double.pi * f * t
                let s: Double
                switch wave {
                case .sine: s = sin(w)
                case .bell: s = sin(w) + 0.30 * sin(2 * w) * exp(-t * 14) + 0.12 * sin(3.01 * w) * exp(-t * 20)
                case .fm: s = sin(w + 3.0 * exp(-t * 12) * sin(2 * w))
                case .square: s = sin(w) >= 0 ? 0.5 : -0.5
                }
                let j = start + i
                if j < total { buf[j] += s * env }
            }
        }
        return normalize(buf, volume)
    }

    static func sweep(dur: Double, from f0: Double, to f1: Double, wave: Wave, tremolo: Bool,
                      steps: Bool = false, volume: Double = 0.3) -> [Double] {
        let n = max(1, Int(rate * dur))
        var buf = [Double]()
        buf.reserveCapacity(n)
        var ph1 = 0.0, ph2 = 0.0, pht = 0.0
        let octaves = log2(f1 / f0)
        for i in 0..<n {
            let t = Double(i) / rate
            let x = t / dur
            var f = f0 * pow(2, octaves * x)
            if steps { f = f0 * pow(2, (12 * log2(f / f0)).rounded(.down) / 12) }
            ph1 += 2 * .pi * f / rate
            ph2 += 2 * .pi * f * 1.5 / rate
            pht += 2 * .pi * (6 + 22 * x) / rate
            let amp = 0.15 + 0.85 * pow(x, 1.6)
            let trem = tremolo ? 0.75 + 0.25 * sin(pht) : 1
            let tail = min(1, (dur - t) / 0.02)
            let s: Double
            switch wave {
            case .square: s = sin(ph1) >= 0 ? 0.6 : -0.6
            case .fm: s = sin(ph1 + 2 * x * sin(2 * ph1)) + 0.3 * sin(ph2)
            default: s = sin(ph1) + 0.15 * sin(2 * ph1) + 0.45 * sin(ph2)
            }
            buf.append(s * amp * trem * tail)
        }
        return normalize(buf, volume)
    }

    static func normalize(_ buf: [Double], _ volume: Double) -> [Double] {
        let peak = buf.map { abs($0) }.max() ?? 1
        return buf.map { $0 / (peak > 0 ? peak : 1) * volume }
    }

    static func wav(_ samples: [Double]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }

    /// enter = arriving on lab_pc, back = arriving on the Mac, charge = the hold at the edge
    static func render(_ theme: SoundTheme, delay: Double) -> (enter: Data, back: Data, charge: Data) {
        let cd = max(0.12, delay)
        switch theme {
        case .crystal:
            return (wav(notes([659.25, 880, 1318.51], dur: 0.42, gap: 0.07, decay: 9, wave: .bell)),
                    wav(notes([1318.51, 987.77, 659.25], dur: 0.42, gap: 0.07, decay: 9, wave: .bell)),
                    wav(sweep(dur: cd, from: 220, to: 880, wave: .bell, tremolo: true)))
        case .soft:
            return (wav(notes([523.25, 659.25, 783.99], dur: 0.7, gap: 0.1, decay: 5, wave: .sine, volume: 0.3)),
                    wav(notes([783.99, 659.25, 523.25], dur: 0.7, gap: 0.1, decay: 5, wave: .sine, volume: 0.3)),
                    wav(sweep(dur: cd, from: 262, to: 523, wave: .sine, tremolo: false, volume: 0.25)))
        case .scifi:
            return (wav(notes([440, 880, 1760], dur: 0.28, gap: 0.05, decay: 12, wave: .fm)),
                    wav(notes([1760, 880, 440], dur: 0.28, gap: 0.05, decay: 12, wave: .fm)),
                    wav(sweep(dur: cd, from: 110, to: 1760, wave: .fm, tremolo: true)))
        case .retro:
            return (wav(notes([523.25, 659.25, 783.99, 1046.5], dur: 0.14, gap: 0.07, decay: 5, wave: .square, volume: 0.22)),
                    wav(notes([1046.5, 783.99, 659.25, 523.25], dur: 0.14, gap: 0.07, decay: 5, wave: .square, volume: 0.22)),
                    wav(sweep(dur: cd, from: 262, to: 1046.5, wave: .square, tremolo: false, steps: true, volume: 0.2)))
        }
    }
}

