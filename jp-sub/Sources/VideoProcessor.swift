import Foundation
import AppKit
import CoreGraphics
import AVFoundation

struct VideoCue {
    var start: Double
    var end: Double
    var jp: String
    var zh: String
}

/// 线程安全的取消标志
final class CancelFlag {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// 视频文件 → 扫帧识别日文字幕 → 翻译 → 字幕条目
/// 全程在后台线程执行，通过 progress 回调汇报进度。
enum VideoProcessor {

    /// 抽帧间隔（秒）。字幕通常每句停留 1 秒以上，0.5 秒足够捕捉边界。
    static var sampleStep: Double { Settings.shared.videoStep }

    static func process(
        url: URL,
        regionRatio: Double,
        progress: @escaping (Double, String) -> Void,
        isCancelled: @escaping () -> Bool
    ) async throws -> [VideoCue] {

        let asset = AVURLAsset(url: url)
        let durationCM = try await asset.load(\.duration)
        let duration = durationCM.seconds
        guard duration > 0 else { throw VideoError.noVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 300, timescale: 1000)
        generator.requestedTimeToleranceAfter = CMTime(value: 300, timescale: 1000)

        var cues: [VideoCue] = []
        var lastText = ""
        var lastThumb: [UInt8]? = nil
        var cueStart = -1.0
        var currentJP = ""

        let step = sampleStep

        var t = 0.0
        while t < duration {
            if isCancelled() { throw CancellationError() }

            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let frame = try? generator.copyCGImage(at: time, actualTime: nil),
               let bottom = cropBottom(frame, ratio: regionRatio) {

                let thumb = grayThumb(bottom)
                if let last = lastThumb, diff(last, thumb) < 9.0 {
                    // 字幕区画面没变，跳过 OCR（字幕静止期间只识别一次）
                    t += step
                    continue
                }
                lastThumb = thumb

                let raw = OCRService.shared.recognize(bottom)
                let text = TextUtils.normalize(raw)

                if text.isEmpty {
                    if cueStart >= 0 {
                        cues.append(VideoCue(start: cueStart, end: t, jp: currentJP, zh: ""))
                        cueStart = -1
                        currentJP = ""
                        lastText = ""
                    }
                } else if TextUtils.similar(text, lastText) {
                    // 同一句字幕还在，仅延长结束时间
                } else {
                    if cueStart >= 0 {
                        cues.append(VideoCue(start: cueStart, end: t, jp: currentJP, zh: ""))
                    }
                    cueStart = t
                    currentJP = text
                    lastText = text
                }
            }

            let phase1 = 0.8 * min(1.0, t / duration)
            let msg = "识别字幕  \(TextUtils.clock(t)) / \(TextUtils.clock(duration))"
            await MainActor.run { progress(phase1, msg) }

            t += step
        }

        if cueStart >= 0 {
            cues.append(VideoCue(start: cueStart, end: max(duration, cueStart + 1), jp: currentJP, zh: ""))
        }

        // 翻译阶段（8 成进度之后）
        let total = cues.count
        for i in 0..<total {
            if isCancelled() { throw CancellationError() }
            let zh = await translateOnMain(cues[i].jp)
            cues[i].zh = zh.isEmpty ? cues[i].jp : zh
            let phase2 = 0.8 + 0.2 * Double(i + 1) / Double(max(1, total))
            let msg = "翻译字幕  \(i + 1) / \(total)"
            await MainActor.run { progress(phase2, msg) }
        }

        return cues
    }

    @MainActor
    private static func translateOnMain(_ text: String) async -> String {
        await TranslatorCenter.shared.translate(text)
    }

    // MARK: - 图像处理

    /// 截取画面底部（CGImage 像素坐标原点在左上）
    static func cropBottom(_ image: CGImage, ratio: Double) -> CGImage? {
        let w = image.width
        let h = image.height
        let cropH = Int(CGFloat(h) * CGFloat(min(0.6, max(0.08, ratio))))
        guard cropH > 0 else { return nil }
        return image.cropping(to: CGRect(x: 0, y: h - cropH, width: w, height: cropH))
    }

    /// 缩小为 48x10 的灰度缩略图，用于快速变化检测
    static func grayThumb(_ image: CGImage) -> [UInt8] {
        let tw = 48
        let th = 10
        let bytesPerRow = tw * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * th)
        guard let ctx = CGContext(data: &data,
                                  width: tw,
                                  height: th,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return []
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))

        var gray = [UInt8](repeating: 0, count: tw * th)
        for i in 0..<(tw * th) {
            let r = Int(data[i * 4])
            let g = Int(data[i * 4 + 1])
            let b = Int(data[i * 4 + 2])
            gray[i] = UInt8((r * 30 + g * 59 + b * 11) / 100)
        }
        return gray
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1000 }
        var sum = 0
        for i in 0..<a.count {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(a.count)
    }

    // MARK: - 输出

    static func srtText(from cues: [VideoCue]) -> String {
        var out = ""
        for (index, cue) in cues.enumerated() {
            let zh = cue.zh.isEmpty ? cue.jp : cue.zh
            out += "\(index + 1)\n"
            out += "\(TextUtils.timecode(cue.start)) --> \(TextUtils.timecode(cue.end))\n"
            out += zh + "\n\n"
        }
        return out
    }

    static func plainText(from cues: [VideoCue], title: String) -> String {
        var out = "# \(title)\n# 中日对照字幕（由 JpSub 从视频识别生成）\n\n"
        for cue in cues {
            out += "[\(TextUtils.clock(cue.start))] \(cue.zh.isEmpty ? cue.jp : cue.zh)\n"
            out += "           \(cue.jp)\n"
        }
        return out
    }
}

enum VideoError: LocalizedError {
    case noVideo

    var errorDescription: String? {
        switch self {
        case .noVideo:
            return "无法读取该视频（格式不支持或文件损坏）"
        }
    }
}

// MARK: - 进度窗口

@MainActor
final class ProgressWindowController {

    let cancelFlag = CancelFlag()

    private var window: NSWindow?
    private var indicator: NSProgressIndicator!
    private var label: NSTextField!

    var isCancelled: Bool { cancelFlag.isCancelled }

    func show(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 124),
                         styleMask: [.titled],
                         backing: .buffered,
                         defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 124))

        indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 72, width: 400, height: 20))
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.doubleValue = 0
        content.addSubview(indicator)

        label = NSTextField(labelWithString: "准备中…")
        label.frame = NSRect(x: 20, y: 46, width: 400, height: 18)
        label.lineBreakMode = .byTruncatingMiddle
        content.addSubview(label)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 336, y: 12, width: 84, height: 28)
        content.addSubview(cancel)

        w.contentView = content
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func update(_ progress: Double, _ text: String) {
        indicator.doubleValue = min(100, max(0, progress * 100))
        label.stringValue = text
    }

    func close() {
        window?.close()
        window = nil
    }

    @objc private func cancelTapped() {
        cancelFlag.cancel()
        label.stringValue = "正在取消…"
    }
}
