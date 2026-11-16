import Foundation
import AppKit
import Combine

enum EngineKind: String, CaseIterable {
    case apple = "apple"
    case mymemory = "mymemory"
    case google = "google"
    case openai = "openai"

    var label: String {
        switch self {
        case .apple:    return "Apple 系统翻译（离线·推荐）"
        case .mymemory: return "MyMemory 免费在线"
        case .google:   return "Google 免费接口（需可访问）"
        case .openai:   return "OpenAI 兼容 API（需填密钥）"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var fontSize: Double {
        get { d.object(forKey: "fontSize") == nil ? 28.0 : d.double(forKey: "fontSize") }
        set { d.set(newValue, forKey: "fontSize") }
    }

    var opacity: Double {
        get { d.object(forKey: "opacity") == nil ? 0.45 : d.double(forKey: "opacity") }
        set { d.set(newValue, forKey: "opacity") }
    }

    var showOriginal: Bool {
        get { d.object(forKey: "showOriginal") == nil ? true : d.bool(forKey: "showOriginal") }
        set { d.set(newValue, forKey: "showOriginal") }
    }

    var interval: Double {
        get { d.object(forKey: "interval") == nil ? 0.5 : d.double(forKey: "interval") }
        set { d.set(newValue, forKey: "interval") }
    }

    var autoSave: Bool {
        get { d.object(forKey: "autoSave") == nil ? true : d.bool(forKey: "autoSave") }
        set { d.set(newValue, forKey: "autoSave") }
    }

    var subtitleEnabled: Bool {
        get { d.object(forKey: "subtitleEnabled") == nil ? true : d.bool(forKey: "subtitleEnabled") }
        set { d.set(newValue, forKey: "subtitleEnabled") }
    }

    /// 播放器实时识别 + 批量处理共用的字幕区域高度（画面底部占比）
    var videoSubRatio: Double {
        get { d.object(forKey: "videoSubRatio") == nil ? 0.25 : d.double(forKey: "videoSubRatio") }
        set { d.set(newValue, forKey: "videoSubRatio") }
    }

    var videoStep: Double {
        get { d.object(forKey: "videoStep") == nil ? 0.5 : d.double(forKey: "videoStep") }
        set { d.set(newValue, forKey: "videoStep") }
    }

    var engine: EngineKind {
        get { EngineKind(rawValue: d.string(forKey: "engine") ?? "apple") ?? .apple }
        set { d.set(newValue.rawValue, forKey: "engine") }
    }

    var openaiBase: String {
        get { d.string(forKey: "openaiBase") ?? "https://api.openai.com/v1" }
        set { d.set(newValue, forKey: "openaiBase") }
    }

    var openaiKey: String {
        get { d.string(forKey: "openaiKey") ?? "" }
        set { d.set(newValue, forKey: "openaiKey") }
    }

    var openaiModel: String {
        get { d.string(forKey: "openaiModel") ?? "gpt-4o-mini" }
        set { d.set(newValue, forKey: "openaiModel") }
    }
}

final class SubtitleState: ObservableObject {
    @Published var text: String = ""
    @Published var original: String = ""
    @Published var fontSize: Double = 28
    @Published var opacity: Double = 0.45
    @Published var showOriginal: Bool = true
}

struct TranslationUnavailable: Error {}
