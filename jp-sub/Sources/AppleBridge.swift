import Foundation
import SwiftUI
import Combine

#if canImport(Translation)
import Translation

/// 使用 macOS 15+ 自带的 Translation 框架做离线「日语 → 简体中文」翻译。
/// 无需联网、无需 API Key，延迟极低，最适合实时字幕。
@MainActor
final class AppleTranslationBridge: ObservableObject {

    @Published var configuration: TranslationSession.Configuration? = TranslationSession.Configuration(
        source: Locale.Language(identifier: "ja"),
        target: Locale.Language(identifier: "zh-Hans"))

    private var queue: [(text: String, cont: CheckedContinuation<String, Error>)] = []
    private var ready = false
    private var generation = 0

    var available: Bool { ready }

    /// 提交一段文本，挂起直到翻译结果返回
    func translate(_ text: String) async throws -> String {
        guard ready else { throw TranslationUnavailable() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.append((text, cont))
        }
    }

    /// 由 translationTask 驱动，session 在闭包存续期间保持有效
    func run(_ session: TranslationSession) async {
        generation += 1
        let myGeneration = generation

        do { try await session.prepareTranslation() } catch { }
        ready = true

        while !Task.isCancelled {
            if queue.isEmpty {
                try? await Task.sleep(for: .milliseconds(40))
                continue
            }
            let job = queue.removeFirst()
            do {
                let response = try await session.translate(job.text)
                job.cont.resume(returning: response.targetText)
            } catch {
                job.cont.resume(throwing: error)
            }
        }

        if generation == myGeneration {
            ready = false
        }
    }
}

/// 挂在界面里的隐藏视图，负责让系统把可用的 TranslationSession 交给我们
struct AppleTranslationHostView: View {
    @ObservedObject var bridge: AppleTranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session)
            }
    }
}

#else

/// 当前 SDK 不含 Translation 框架时的占位实现（走在线翻译引擎）
@MainActor
final class AppleTranslationBridge: ObservableObject {
    var available: Bool { false }

    func translate(_ text: String) async throws -> String {
        throw TranslationUnavailable()
    }
}

struct AppleTranslationHostView: View {
    init(bridge: AppleTranslationBridge) {}
    var body: some View {
        EmptyView()
    }
}

#endif
