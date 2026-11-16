import Foundation
import CoreGraphics
import Vision

/// 日语 OCR：使用系统 Vision 框架（完全离线，支持日文竖排/横排字幕）
final class OCRService {

    static let shared = OCRService()

    private let lock = NSLock()
    private let request: VNRecognizeTextRequest

    private init() {
        request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.015
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
    }

    /// 识别一张图，按视觉顺序拼成多行文本
    func recognize(_ image: CGImage) -> String {
        lock.lock()
        defer { lock.unlock() }

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        guard let observations = request.results, !observations.isEmpty else { return "" }

        struct Piece {
            let text: String
            let box: CGRect
        }

        let pieces: [Piece] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let t = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            return Piece(text: t, box: obs.boundingBox)
        }

        if pieces.isEmpty { return "" }

        // 按纵向中心聚成“行”（Vision 常把一句字幕拆成多段）
        var lines: [(centerY: CGFloat, height: CGFloat, items: [Piece])] = []
        for piece in pieces {
            let cy = piece.box.midY
            let h = piece.box.height
            if let idx = lines.firstIndex(where: { abs($0.centerY - cy) <= max(0.012, h * 0.65) }) {
                lines[idx].items.append(piece)
            } else {
                lines.append((centerY: cy, height: h, items: [piece]))
            }
        }

        // Vision 的 boundingBox 原点在左下，Y 越大越靠上 → 按 Y 降序排列
        lines.sort { $0.centerY > $1.centerY }

        var rendered: [String] = []
        for line in lines {
            let sorted = line.items.sorted { $0.box.minX < $1.box.minX }
            let joined = sorted.map { $0.text }.joined()
            if !joined.isEmpty { rendered.append(joined) }
        }

        return TextUtils.normalize(rendered.joined(separator: "\n"))
    }
}
