import AppKit

@MainActor final class ManagerApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let crossOver = NSTextField(string: "")
    private let game = NSTextField(string: "")
    private let bottle = NSPopUpButton()
    private let status = NSTextView()
    private let installButton = NSButton(title: "安装修复", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复原配置", target: nil, action: nil)
    private let launchButton = NSButton(title: "打开游戏启动器", target: nil, action: nil)
    private var paths: [URL] = []
    private var configuration: URL?
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出ManjuuSDKFix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ManjuuSDKFix"; window.delegate = self; window.center()
        guard let content = window.contentView else { return }
        func label(_ text: String, _ frame: NSRect, size: CGFloat = 13) {
            let label = NSTextField(wrappingLabelWithString: text); label.frame = frame; label.font = .systemFont(ofSize: size); content.addSubview(label)
        }
        label("选择已安装的 CrossOver 和游戏容器。请先退出这个容器中的游戏与启动器。", NSRect(x: 28, y: 482, width: 660, height: 30))
        label("CrossOver", NSRect(x: 28, y: 437, width: 100, height: 24))
        crossOver.placeholderString = "未检测到 CrossOver，请点击选择…"
        crossOver.stringValue = RepairEngine.findCrossOver()?.path ?? ""
        crossOver.frame = NSRect(x: 135, y: 437, width: 460, height: 24); content.addSubview(crossOver)
        let chooseCrossOver = NSButton(title: "选择…", target: self, action: #selector(selectCrossOver)); chooseCrossOver.frame = NSRect(x: 602, y: 435, width: 90, height: 28); content.addSubview(chooseCrossOver)
        label("游戏容器", NSRect(x: 28, y: 395, width: 100, height: 24))
        bottle.frame = NSRect(x: 133, y: 394, width: 465, height: 28); bottle.target = self; bottle.action = #selector(changeBottle); content.addSubview(bottle)
        paths = RepairEngine.bottles(); bottle.addItems(withTitles: paths.map(\.lastPathComponent))
        label("游戏目录", NSRect(x: 28, y: 353, width: 100, height: 24))
        game.placeholderString = "未检测到游戏，请选择 AzurPromilia.exe 所在目录"
        game.frame = NSRect(x: 135, y: 353, width: 460, height: 24); content.addSubview(game)
        let chooseGame = NSButton(title: "选择…", target: self, action: #selector(selectGame)); chooseGame.frame = NSRect(x: 602, y: 351, width: 90, height: 28); content.addSubview(chooseGame)
        if let selected = paths.firstIndex(where: { RepairEngine.findGame(in: $0) != nil }) { bottle.selectItem(at: selected) }
        changeBottle()
        for (button, action, x, width) in [(installButton, #selector(install), 28.0, 130.0), (restoreButton, #selector(restore), 168.0, 130.0), (launchButton, #selector(launch), 308.0, 174.0)] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; button.frame = NSRect(x: x, y: 300, width: width, height: 34); content.addSubview(button)
        }
        let scroll = NSScrollView(frame: NSRect(x: 28, y: 28, width: 664, height: 253))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.documentView = status
        status.isEditable = false; status.isSelectable = true; status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.textContainerInset = NSSize(width: 10, height: 10); status.isVerticallyResizable = true; status.autoresizingMask = [.width]; status.frame = scroll.bounds
        status.textContainer?.widthTracksTextView = true; content.addSubview(scroll)
        if let path = try? String(contentsOf: RepairEngine.managerHome.appendingPathComponent("last-installation.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            let file = URL(fileURLWithPath: path)
            if let saved = try? RepairEngine.read(file) {
                configuration = file; crossOver.stringValue = saved.crossOver; game.stringValue = saved.game
                if let selected = paths.firstIndex(where: { $0.path == saved.bottle }) { bottle.selectItem(at: selected) }
            }
        }
        append(configuration == nil ? "就绪。安装前会校验版本并备份官方文件。" : "检测到已安装的修复，可以打开启动器或恢复原配置。")
        refresh()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { busy ? .terminateCancel : .terminateNow }
    private func append(_ text: String) { status.string += text + "\n"; status.scrollToEndOfDocument(nil) }
    private func refresh() { installButton.isEnabled = !busy && configuration == nil && !paths.isEmpty; restoreButton.isEnabled = !busy && configuration != nil; launchButton.isEnabled = !busy && configuration != nil; bottle.isEnabled = !busy && configuration == nil }
    @objc private func changeBottle() {
        let index = bottle.indexOfSelectedItem
        if paths.indices.contains(index) { game.stringValue = RepairEngine.findGame(in: paths[index])?.path ?? "" }
    }
    @objc private func selectCrossOver() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url { crossOver.stringValue = url.path }
    }
    @objc private func selectGame() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { game.stringValue = url.path }
    }
    @objc private func install() {
        guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL, paths.indices.contains(bottle.indexOfSelectedItem) else { return }
        let selectedBottle = paths[bottle.indexOfSelectedItem], selectedGame = URL(fileURLWithPath: game.stringValue), selectedCrossOver = URL(fileURLWithPath: crossOver.stringValue)
        busy = true; refresh()
        Task {
            do {
                let result = try await RepairEngine.install(crossOver: selectedCrossOver, bottle: selectedBottle, game: selectedGame, payload: resources.appendingPathComponent("Payload"), manager: executable) { message in
                    Task { @MainActor in self.append(message) }
                }
                configuration = result.configurationURL
            } catch { append(error.localizedDescription) }
            busy = false; refresh()
        }
    }
    @objc private func restore() {
        guard let configuration else { return }; busy = true; refresh()
        Task {
            do { try await RepairEngine.uninstall(configuration); self.configuration = nil; append("原配置已恢复，运行库副本与修复启动项已删除。") }
            catch { append(error.localizedDescription) }
            busy = false; refresh()
        }
    }
    @objc private func launch() {
        guard let configuration, let executable = Bundle.main.executableURL else { return }
        do {
            let process = Process(); process.executableURL = executable; process.arguments = ["--launch", configuration.path]; try process.run()
            append("已打开官方启动器。游戏通过此启动流程自动接入修复。")
        } catch { append(error.localizedDescription) }
    }
}

@main struct ManagerMain {
    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        do {
            if arguments.count >= 3, arguments[1] == "--launch" { try RepairEngine.launch(URL(fileURLWithPath: arguments[2])); return }
            if arguments.count == 4, arguments[1] == "--monitor", let parent = Int32(arguments[3]) { try RepairEngine.monitor(URL(fileURLWithPath: arguments[2]), parent: parent); return }
            if arguments.count == 3, arguments[1] == "--restore" { try await RepairEngine.uninstall(URL(fileURLWithPath: arguments[2])); return }
            if arguments.count == 5, arguments[1] == "--install", let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL {
                let result = try await RepairEngine.install(crossOver: URL(fileURLWithPath: arguments[2]), bottle: URL(fileURLWithPath: arguments[3]), game: URL(fileURLWithPath: arguments[4]), payload: resources.appendingPathComponent("Payload"), manager: executable) { print($0) }
                print(result.configurationURL.path); return
            }
            if arguments.count > 1 { throw RepairFailure(message: "参数无效。请直接打开应用进行安装或恢复。") }
            if let configuration = Bundle.main.object(forInfoDictionaryKey: "AzurSDKConfiguration") as? String { try RepairEngine.launch(URL(fileURLWithPath: configuration)); return }
            runApplication()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            if arguments.count == 1 || arguments.dropFirst().first == "--launch" {
                let app = NSApplication.shared; app.setActivationPolicy(.regular)
                let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
            exit(1)
        }
    }

    @MainActor static func runApplication() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = ManagerApplication(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
