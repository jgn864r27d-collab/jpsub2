import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController {

    private let engine: PlayerEngine
    private var layoutTimer: Timer?

    init(engine: PlayerEngine) {
        self.engine = engine

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "JpSub 播放器"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.center()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 620))

        engine.playerView.frame = container.bounds
        engine.playerView.autoresizingMask = [.width, .height]
        container.addSubview(engine.playerView)

        engine.subtitleView.frame = NSRect(x: 100, y: 30, width: 800, height: 90)
        container.addSubview(engine.subtitleView)

        // 隐藏宿主：让系统离线翻译的 translationTask 生效
        let host = NSHostingView(rootView: AppleTranslationHostView(bridge: TranslatorCenter.shared.apple))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(host)

        window.contentView = container
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startLayoutTimer()
    }

    func setTitle(_ title: String) {
        window?.title = title
    }

    private func startLayoutTimer() {
        layoutTimer?.invalidate()
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.layoutSubtitle()
        }
    }

    /// 把字幕条贴到视频画面底部（letterbox 时仍对齐真实画面）
    private func layoutSubtitle() {
        guard let window else { return }
        let vb = engine.playerView.videoBounds
        guard vb.width > 10, vb.height > 10 else { return }
        let h = min(150, vb.height * 0.2)
        let w = max(200, vb.width * 0.88)
        let x = vb.minX + (vb.width - w) / 2
        let y = vb.minY + 12
        engine.subtitleView.frame = NSRect(x: x, y: y, width: w, height: h)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var engine: PlayerEngine!
    private var windowController: MainWindowController!

    private var subtitleToggleItem: NSMenuItem?
    private var originalToggleItem: NSMenuItem?
    private var autoSaveItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = PlayerEngine()
        windowController = MainWindowController(engine: engine)

        buildMainMenu()
        windowController.show()
        engine.startRecognition()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        SubtitleRecorder.shared.flush()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(url: URL(fileURLWithPath: filename))
        return true
    }

    // MARK: - 主菜单

    private func makeMenu(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "JpSub")
        appMenu.addItem(makeMenu("关于 JpSub", #selector(showAbout)))
        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏 JpSub", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideItem)
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(.separator())
        appMenu.addItem(makeMenu("退出 JpSub", #selector(quit), "q"))
        appItem.submenu = appMenu

        // 文件
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(makeMenu("打开视频…", #selector(openVideo), "o"))
        fileMenu.addItem(makeMenu("批量生成字幕…", #selector(batchProcess), "O"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(makeMenu("关闭窗口", #selector(closeWindow), "w"))
        fileItem.submenu = fileMenu

        // 播放
        let playItem = NSMenuItem()
        mainMenu.addItem(playItem)
        let playMenu = NSMenu(title: "播放")
        playMenu.addItem(makeMenu("播放 / 暂停", #selector(togglePlay), "p"))

        subtitleToggleItem = makeMenu("字幕识别", #selector(toggleSubtitle), "e")
        originalToggleItem = makeMenu("显示日文原文", #selector(toggleOriginal))
        playMenu.addItem(subtitleToggleItem!)
        playMenu.addItem(originalToggleItem!)
        playItem.submenu = playMenu

        // 字幕
        let subItem = NSMenuItem()
        mainMenu.addItem(subItem)
        let subMenu = NSMenu(title: "字幕")
        subMenu.addItem(makeMenu("增大字号", #selector(biggerFont)))
        subMenu.addItem(makeMenu("减小字号", #selector(smallerFont)))
        subMenu.addItem(makeMenu("加深背景", #selector(darkerBackground)))
        subMenu.addItem(makeMenu("变淡背景", #selector(lighterBackground)))
        subMenu.addItem(.separator())

        let ratioMenu = NSMenu()
        for value in [0.15, 0.22, 0.25, 0.30, 0.40] {
            let item = makeMenu("\(Int(value * 100))% 画面高度", #selector(chooseVideoRatio(_:)))
            item.representedObject = value
            ratioMenu.addItem(item)
        }
        let ratioParent = NSMenuItem(title: "字幕区域高度", action: nil, keyEquivalent: "")
        ratioParent.submenu = ratioMenu
        subMenu.addItem(ratioParent)

        subMenu.addItem(.separator())
        let engineMenu = NSMenu()
        for kind in EngineKind.allCases {
            let item = makeMenu(kind.label, #selector(chooseEngine(_:)))
            item.representedObject = kind.rawValue
            engineMenu.addItem(item)
        }
        let engineParent = NSMenuItem(title: "翻译引擎", action: nil, keyEquivalent: "")
        engineParent.submenu = engineMenu
        subMenu.addItem(engineParent)
        subMenu.addItem(makeMenu("API 设置（OpenAI 兼容）…", #selector(configureAPI)))

        subMenu.addItem(.separator())
        autoSaveItem = makeMenu("自动保存字幕（.srt）", #selector(toggleAutoSave))
        subMenu.addItem(autoSaveItem!)
        subMenu.addItem(makeMenu("保存字幕…", #selector(saveSubtitles)))
        subItem.submenu = subMenu

        // 帮助
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(makeMenu("使用说明", #selector(showAbout)))
        helpItem.submenu = helpMenu

        refreshMenuStates()
    }

    private func refreshMenuStates() {
        subtitleToggleItem?.state = Settings.shared.subtitleEnabled ? .on : .off
        originalToggleItem?.state = Settings.shared.showOriginal ? .on : .off
        autoSaveItem?.state = Settings.shared.autoSave ? .on : .off
    }

    // MARK: - 打开与播放

    @objc private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "打开视频，实时识别日文字幕并翻译成中文"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    private func open(url: URL) {
        engine.open(url: url)
        windowController.setTitle(url.lastPathComponent + " — JpSub")
        windowController.show()
        engine.play()
        if !engine.isRecognitionRunning {
            engine.startRecognition()
        }
    }

    @objc private func closeWindow() {
        windowController.close()
    }

    @objc private func togglePlay() {
        engine.togglePlay()
    }

    // MARK: - 字幕开关与样式

    @objc private func toggleSubtitle() {
        Settings.shared.subtitleEnabled.toggle()
        if Settings.shared.subtitleEnabled {
            engine.startRecognition()
        } else {
            engine.stopRecognition()
        }
        refreshMenuStates()
    }

    @objc private func toggleOriginal() {
        Settings.shared.showOriginal.toggle()
        engine.refreshSubtitleStyle()
        refreshMenuStates()
    }

    @objc private func biggerFont() {
        Settings.shared.fontSize = min(64, Settings.shared.fontSize + 2)
        engine.refreshSubtitleStyle()
    }

    @objc private func smallerFont() {
        Settings.shared.fontSize = max(14, Settings.shared.fontSize - 2)
        engine.refreshSubtitleStyle()
    }

    @objc private func darkerBackground() {
        Settings.shared.opacity = min(0.9, Settings.shared.opacity + 0.08)
        engine.refreshSubtitleStyle()
    }

    @objc private func lighterBackground() {
        Settings.shared.opacity = max(0.1, Settings.shared.opacity - 0.08)
        engine.refreshSubtitleStyle()
    }

    @objc private func chooseVideoRatio(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            Settings.shared.videoSubRatio = value
        }
    }

    @objc private func chooseEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = EngineKind(rawValue: raw) else { return }
        Settings.shared.engine = kind
        if kind == .openai && Settings.shared.openaiKey.isEmpty {
            configureAPI()
        }
    }

    @objc private func configureAPI() {
        let alert = NSAlert()
        alert.messageText = "OpenAI 兼容 API 设置"
        alert.informativeText = "适用于 OpenAI、DeepSeek、Moonshot 等服务。Base URL 填到 /v1 为止。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 110)

        let baseField = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        let keyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        let modelField = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        baseField.stringValue = Settings.shared.openaiBase
        keyField.stringValue = Settings.shared.openaiKey
        modelField.stringValue = Settings.shared.openaiModel
        baseField.placeholderString = "https://api.deepseek.com/v1"
        keyField.placeholderString = "API Key（sk-…）"
        modelField.placeholderString = "deepseek-chat"

        for field in [baseField, keyField, modelField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 460).isActive = true
            stack.addArrangedSubview(field)
        }

        alert.accessoryView = stack
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.shared.openaiBase = baseField.stringValue
            Settings.shared.openaiKey = keyField.stringValue
            Settings.shared.openaiModel = modelField.stringValue
        }
    }

    // MARK: - 字幕归档

    @objc private func toggleAutoSave() {
        Settings.shared.autoSave.toggle()
        if Settings.shared.autoSave {
            SubtitleRecorder.shared.flush()
        }
        refreshMenuStates()
    }

    @objc private func saveSubtitles() {
        let recorder = SubtitleRecorder.shared
        guard recorder.count > 0 else {
            let alert = NSAlert()
            alert.messageText = "还没有可保存的字幕"
            alert.informativeText = "先播放视频，让字幕识别运行一会儿。"
            alert.runModal()
            return
        }
        do {
            if let videoURL = recorder.sourceURL {
                let dir = videoURL.deletingLastPathComponent()
                let srt = dir.appendingPathComponent(recorder.suggestedFileName)
                try recorder.saveSRT(to: srt, includeJapanese: false)
                let txt = srt.deletingPathExtension().appendingPathExtension("txt")
                try recorder.plainText().write(to: txt, atomically: true, encoding: .utf8)
                notifySaved(srt, extra: txt)
            } else {
                let savePanel = NSSavePanel()
                savePanel.nameFieldStringValue = recorder.suggestedFileName
                savePanel.canCreateDirectories = true
                if savePanel.runModal() == .OK, let url = savePanel.url {
                    try recorder.saveSRT(to: url, includeJapanese: false)
                    let txt = url.deletingPathExtension().appendingPathExtension("txt")
                    try recorder.plainText().write(to: txt, atomically: true, encoding: .utf8)
                    notifySaved(url, extra: txt)
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存字幕失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func notifySaved(_ srt: URL, extra: URL) {
        let alert = NSAlert()
        alert.messageText = "字幕已保存"
        alert.informativeText = "SRT：\(srt.path)\n\n中日对照文本：\(extra.path)"
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "好的")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([srt])
        }
    }

    // MARK: - 批量处理（不播放，直接出字幕）

    @objc private func batchProcess() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "选择视频，自动扫帧识别日文字幕并生成 SRT（无需播放）"
        panel.prompt = "开始生成"
        if panel.runModal() == .OK, let url = panel.url {
            startVideoProcessing(url)
        }
    }

    private func startVideoProcessing(_ url: URL) {
        let wasRecognition = engine.isRecognitionRunning
        if wasRecognition { engine.stopRecognition() }

        let progressWC = ProgressWindowController()
        let flag = progressWC.cancelFlag
        progressWC.show(title: "生成字幕：" + url.lastPathComponent)

        Task {
            do {
                let cues = try await VideoProcessor.process(
                    url: url,
                    regionRatio: Settings.shared.videoSubRatio,
                    progress: { p, text in progressWC.update(p, text) },
                    isCancelled: { flag.isCancelled }
                )

                guard !cues.isEmpty else {
                    progressWC.close()
                    self.showAlert(title: "没有识别到字幕",
                                   message: "画面底部没有找到稳定出现的文字。可把「字幕区域高度」调大后重试，或确认视频本身带内嵌字幕。")
                    if wasRecognition { self.engine.startRecognition() }
                    return
                }

                let srt = url.deletingPathExtension().appendingPathExtension("zh.srt")
                let txt = url.deletingPathExtension().appendingPathExtension("zh.txt")
                try VideoProcessor.srtText(from: cues).write(to: srt, atomically: true, encoding: .utf8)
                try VideoProcessor.plainText(from: cues, title: url.lastPathComponent).write(to: txt, atomically: true, encoding: .utf8)

                progressWC.close()
                self.showVideoDone(cuesCount: cues.count, srt: srt, txt: txt)
            } catch is CancellationError {
                progressWC.close()
                self.showAlert(title: "已取消", message: "本次未保存任何文件。")
            } catch {
                progressWC.close()
                self.showAlert(title: "处理失败", message: error.localizedDescription)
            }

            if wasRecognition {
                self.engine.startRecognition()
            }
        }
    }

    private func showVideoDone(cuesCount: Int, srt: URL, txt: URL) {
        let alert = NSAlert()
        alert.messageText = "字幕已生成（\(cuesCount) 句）"
        alert.informativeText = "SRT：\(srt.path)\n\n中日对照：\(txt.path)\n\n用 JpSub 或 IINA / VLC 打开同一视频即可看到字幕。"
        alert.addButton(withTitle: "在访达中显示")
        alert.addButton(withTitle: "好的")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([srt])
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - 关于与退出

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "JpSub 日语视频字幕播放器"
        alert.informativeText = """
        一个模仿 QuickTime 体验的日语视频播放器：播放的同时，自动识别画面中的日文字幕、离线翻译成中文并叠加显示，还能按时间轴保存成 SRT。

        三种使用方式：
        · 打开视频直接看，字幕自动出现（实时）。
        · 菜单「批量生成字幕…」把整个视频扫一遍，直接产出 .srt，不用播放。
        · 边看边自动保存字幕到视频同目录。

        完全离线：视频解码、文字识别、系统翻译都在本机完成，不需要屏幕录制权限。
        """
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc private func quit() {
        SubtitleRecorder.shared.flush()
        NSApp.terminate(nil)
    }
}
