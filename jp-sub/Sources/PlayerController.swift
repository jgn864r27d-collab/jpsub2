import Foundation
import AppKit
import AVFoundation
import AVKit
import CoreImage
import CoreGraphics

/// 覆盖在视频画面上、绘制半透明中文字幕的视图
final class SubtitleOverlayView: NSView {

    var chineseText: String = ""
    var japaneseText: String = ""
    var showJapanese: Bool = false
    var fontSize: CGFloat = 28
    var backgroundOpacity: CGFloat = 0.45

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if chineseText.isEmpty && japaneseText.isEmpty { return }

        let radius: CGFloat = 14
        let bg = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(backgroundOpacity).setFill()
        bg.fill()

        var available = bounds.insetBy(dx: 20, dy: 12)

        // 日文原文（小字，位于上方）
        if showJapanese && !japaneseText.isEmpty {
            let jpRect = available
            let jpStyle = NSMutableParagraphStyle()
            jpStyle.alignment = .center
            jpStyle.lineBreakMode = .byWordWrapping
            let jpAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(12, fontSize * 0.5), weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .paragraphStyle: jpStyle
            ]
            let jpSize = (japaneseText as NSString).boundingRect(
                with: NSSize(width: available.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: jpAttrs
            )
            let jpH = min(jpSize.height, available.height * 0.4)
            (japaneseText as NSString).draw(in: NSRect(x: available.minX, y: available.maxY - jpH, width: available.width, height: jpH), withAttributes: jpAttrs)
            available.size.height -= jpH + 4
        }

        // 中文译文（主字幕，居中）
        let zhStyle = NSMutableParagraphStyle()
        zhStyle.alignment = .center
        zhStyle.lineBreakMode = .byWordWrapping
        let zhAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: zhStyle
        ]
        let zhSize = (chineseText as NSString).boundingRect(
            with: NSSize(width: available.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: zhAttrs
        )
        let zhH = min(zhSize.height, available.height)
        let zhY = available.minY + (available.height - zhH) / 2
        (chineseText as NSString).draw(in: NSRect(x: available.minX, y: zhY, width: available.width, height: zhH), withAttributes: zhAttrs)
    }

    func update(chinese: String, japanese: String, showJapanese: Bool, fontSize: CGFloat, opacity: CGFloat) {
        self.chineseText = chinese
        self.japaneseText = japanese
        self.showJapanese = showJapanese
        self.fontSize = fontSize
        self.backgroundOpacity = opacity
        needsDisplay = true
    }
}

/// 播放器内核：AVPlayer 播放 + 从解码帧 OCR 字幕 + 翻译 + 归档
@MainActor
final class PlayerEngine {

    let player = AVPlayer()
    let playerView = AVPlayerView()
    let subtitleView = SubtitleOverlayView()

    private let videoOutput: AVPlayerItemVideoOutput
    private let ciContext = CIContext()

    private var started = false
    private var running = true
    private var inFlight = false
    private var lastSource = ""
    private var lastThumb: [UInt8]?

    var onTimeChange: ((Double) -> Void)?

    init() {
        var attrs: [String: Any] = [:]
        attrs[kCVPixelBufferPixelFormatTypeKey as String] = Int(kCVPixelFormatType_32BGRA)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)

        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.allowsMagnification = true
    }

    var currentURL: URL?

    func open(url: URL) {
        currentURL = url
        let item = AVPlayerItem(url: url)
        item.add(videoOutput)
        player.replaceCurrentItem(with: item)

        SubtitleRecorder.shared.reset(sourceName: url.lastPathComponent, sourceURL: url)
        lastSource = ""
        lastThumb = nil
        subtitleView.update(chinese: "", japanese: "", showJapanese: Settings.shared.showOriginal,
                            fontSize: CGFloat(Settings.shared.fontSize), opacity: CGFloat(Settings.shared.opacity))
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    func currentTime() -> Double {
        player.currentTime().seconds
    }

    func startRecognition() {
        running = true
        guard !started else { return }
        started = true
        Task { await loop() }
    }

    func stopRecognition() {
        running = false
        lastSource = ""
        subtitleView.update(chinese: "", japanese: "", showJapanese: Settings.shared.showOriginal,
                            fontSize: CGFloat(Settings.shared.fontSize), opacity: CGFloat(Settings.shared.opacity))
    }

    var isRecognitionRunning: Bool { running }

    private func loop() async {
        while true {
            if running && isPlaying {
                await tick()
            }
            let ms = max(200, Int(Settings.shared.interval * 1000))
            try? await Task.sleep(for: .milliseconds(ms))
        }
    }

    private func tick() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        guard let frame = currentFrame() else { return }
        let ratio = Settings.shared.videoSubRatio
        guard let bottom = VideoProcessor.cropBottom(frame, ratio: ratio) else { return }

        // 字幕区画面变化检测：没变就跳过 OCR
        let thumb = VideoProcessor.grayThumb(bottom)
        if let last = lastThumb, VideoProcessor.diff(last, thumb) < 9.0 {
            return
        }
        lastThumb = thumb

        let raw = await Task.detached(priority: .userInitiated) {
            OCRService.shared.recognize(bottom)
        }.value
        let text = TextUtils.normalize(raw)

        if text.isEmpty {
            if !lastSource.isEmpty {
                lastSource = ""
                setSubtitle(source: "", translated: "")
            }
            return
        }

        if !lastSource.isEmpty && TextUtils.similar(text, lastSource) {
            return
        }

        lastSource = text
        setSubtitle(source: text, translated: "")   // 先顶出日文原文，减少空窗

        let translated = await TranslatorCenter.shared.translate(text)
        setSubtitle(source: text, translated: translated)

        let t = currentTime()
        SubtitleRecorder.shared.add(jp: text, zh: translated, at: t)
        onTimeChange?(t)
    }

    private func setSubtitle(source: String, translated: String) {
        let zh = translated.isEmpty ? "" : translated
        subtitleView.update(chinese: zh,
                            japanese: source,
                            showJapanese: Settings.shared.showOriginal,
                            fontSize: CGFloat(Settings.shared.fontSize),
                            opacity: CGFloat(Settings.shared.opacity))
    }

    func refreshSubtitleStyle() {
        subtitleView.update(chinese: subtitleView.chineseText,
                            japanese: subtitleView.japaneseText,
                            showJapanese: Settings.shared.showOriginal,
                            fontSize: CGFloat(Settings.shared.fontSize),
                            opacity: CGFloat(Settings.shared.opacity))
    }

    // MARK: - 取当前播放帧

    private func currentFrame() -> CGImage? {
        guard let item = player.currentItem else { return nil }
        let time = item.currentTime()
        guard videoOutput.hasNewPixelBuffer(forItemTime: time) else { return nil }
        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}
