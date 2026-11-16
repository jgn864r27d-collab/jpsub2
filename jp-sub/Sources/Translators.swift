import Foundation

/// 翻译调度中心：默认走系统离线翻译，失败时按配置回退到在线引擎
@MainActor
final class TranslatorCenter {

    static let shared = TranslatorCenter()

    let apple = AppleTranslationBridge()

    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []

    func translate(_ text: String) async -> String {
        if let cached = cache[text] { return cached }
        let result = await performTranslate(text)
        remember(text, result)
        return result
    }

    private func performTranslate(_ text: String) async -> String {
        let engine = Settings.shared.engine

        if engine == .apple {
            if apple.available, let r = try? await apple.translate(text), !r.isEmpty { return r }
            if let r = await MyMemoryEngine.translate(text) { return r }
            return text
        }

        switch engine {
        case .mymemory:
            if let r = await MyMemoryEngine.translate(text) { return r }
        case .google:
            if let r = await GoogleEngine.translate(text) { return r }
        case .openai:
            if let r = await OpenAIEngine.translate(text) { return r }
        case .apple:
            break
        }

        if apple.available, let r = try? await apple.translate(text), !r.isEmpty { return r }
        return text
    }

    private func remember(_ source: String, _ result: String) {
        if cache[source] != nil { return }
        cache[source] = result
        cacheOrder.append(source)
        while cacheOrder.count > 40 {
            let old = cacheOrder.removeFirst()
            cache.removeValue(forKey: old)
        }
    }
}

enum MyMemoryEngine {
    static func translate(_ text: String) async -> String? {
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")
        comps?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "ja|zh-CN")
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("JpSub/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rd = obj["responseData"] as? [String: Any],
               let t = rd["translatedText"] as? String {
                let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && !cleaned.contains("MYMEMORY WARNING") {
                    return cleaned
                }
            }
        } catch {}
        return nil
    }
}

enum GoogleEngine {
    static func translate(_ text: String) async -> String? {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        comps?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "ja"),
            URLQueryItem(name: "tl", value: "zh-CN"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
               let parts = arr.first as? [Any] {
                var out = ""
                for p in parts {
                    if let seg = p as? [Any], let s = seg.first as? String {
                        out += s
                    }
                }
                let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
        } catch {}
        return nil
    }
}

enum OpenAIEngine {
    static func translate(_ text: String) async -> String? {
        let s = Settings.shared
        let key = s.openaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        var base = s.openaiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")

        let systemPrompt = "你是专业的日语影视字幕翻译。把用户提交的日文台词翻译成自然、口语化的简体中文。只输出译文本身，不要解释、不要加引号、不要保留日文原文。"
        let body: [String: Any] = [
            "model": s.openaiModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "temperature": 0.2
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
                    cleaned = String(cleaned.dropFirst().dropLast())
                }
                return cleaned.isEmpty ? nil : cleaned
            }
        } catch {}
        return nil
    }
}
