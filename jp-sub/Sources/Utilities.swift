import Foundation
import AppKit

enum TextUtils {

    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int((seconds * 1000).rounded()))
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60000) % 60
        let h = total / 3600000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// 按行清洗：去掉行内空格、全角空格，去掉空行与纯符号行
    static func normalize(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        var out: [String] = []
        for line in lines {
            var s = String(line)
            s = s.replacingOccurrences(of: "\u{3000}", with: "")
            s = s.replacingOccurrences(of: " ", with: "")
            s = s.replacingOccurrences(of: "\t", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            let meaningful = s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            if !meaningful { continue }
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    /// 判断两段识别结果是否属于同一句字幕（避免同一句被反复翻译）
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        let la = a.count, lb = b.count
        if abs(la - lb) > max(3, la / 5) { return false }
        let dist = levenshtein(a, b)
        let threshold = max(1, min(la, lb) / 6)
        return dist <= threshold
    }

    static func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            let tmp = prev
            prev = cur
            cur = tmp
        }
        return prev[b.count]
    }
}
