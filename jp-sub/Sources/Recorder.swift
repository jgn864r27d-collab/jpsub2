import Foundation

/// 字幕记录与归档（SRT / 中日对照文本）
@MainActor
final class SubtitleRecorder {

    struct Cue {
        var start: Double
        var end: Double
        var jp: String
        var zh: String
    }

    static let shared = SubtitleRecorder()

    private(set) var cues: [Cue] = []
    private(set) var sourceName: String = ""
    private(set) var sourceURL: URL?

    var count: Int { cues.count }

    private var dirtyCount = 0

    private func markDirty() {
        dirtyCount += 1
        if autoSaveEnabled && dirtyCount >= 8 {
            dirtyCount = 0
            flush()
        }
    }

    var suggestedFileName: String {
        let base: String
        if sourceName.isEmpty {
            base = "字幕"
        } else {
            base = (sourceName as NSString).deletingPathExtension
        }
        return base + ".zh.srt"
    }

    var autoSaveEnabled: Bool { Settings.shared.autoSave }

    func reset(sourceName: String, sourceURL: URL?) {
        cues.removeAll()
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }

    /// 追加一条字幕（同句重复出现时仅更新译文）
    func add(jp: String, zh: String, at time: Double) {
        guard time >= 0 else { return }
        let chinese = zh.isEmpty ? jp : zh

        if let last = cues.last, TextUtils.similar(last.jp, jp) {
            cues[cues.count - 1].zh = chinese
            markDirty()
            return
        }

        if var previous = cues.last {
            var end = time
            if end <= previous.start { end = previous.start + 2.0 }
            if end - previous.start > 12.0 { end = previous.start + 4.0 }
            previous.end = max(previous.start + 0.6, end)
            cues[cues.count - 1] = previous
        }

        cues.append(Cue(start: time, end: time + 3.0, jp: jp, zh: chinese))
        markDirty()
    }

    // MARK: - 输出

    func srtText(includeJapanese: Bool) -> String {
        guard !cues.isEmpty else { return "" }
        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n"
            out += "\(TextUtils.timecode(cue.start)) --> \(TextUtils.timecode(cue.end))\n"
            out += cue.zh
            out += "\n"
            if includeJapanese {
                out += cue.jp + "\n"
            }
            out += "\n"
        }
        return out
    }

    func plainText() -> String {
        var out = ""
        if !sourceName.isEmpty {
            out += "# \(sourceName)\n"
        }
        out += "# 中日对照字幕（由 JpSub 生成）\n\n"
        for cue in cues {
            out += "[\(TextUtils.clock(cue.start))] \(cue.zh)\n"
            out += "           \(cue.jp)\n"
        }
        return out
    }

    @discardableResult
    func saveSRT(to url: URL, includeJapanese: Bool = false) throws -> URL {
        try srtText(includeJapanese: includeJapanese).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 自动保存到视频同目录（不改名、直接覆盖同名 .zh.srt）
    func flush() {
        guard !cues.isEmpty, let videoURL = sourceURL else { return }
        let dir = videoURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent(suggestedFileName)
        try? srtText(includeJapanese: false).write(to: url, atomically: true, encoding: .utf8)
    }

    func clear() {
        cues.removeAll()
    }
}
