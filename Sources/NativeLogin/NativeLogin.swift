import AppKit
import Darwin

struct Endpoint: Decodable {
    let revision: Int
    let port: UInt16
    let token: String
    let host: UInt32
}

@MainActor
final class LoginPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option),
              let editor = firstResponder as? NSTextView else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where editor.isSelectable:
            editor.copy(nil)
        case "x" where editor.isEditable:
            editor.cut(nil)
        case "v" where editor.isEditable:
            editor.pasteAsPlainText(nil)
        case "a" where editor.isSelectable:
            editor.selectAll(nil)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

@MainActor
final class LoginApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let endpointURL: URL
    let parent: pid_t
    var socket: Int32 = -1
    var buffer = Data()
    var panel: LoginPanel!
    let form = NativeSceneView()
    var timer: Timer?
    var lastAttempt = Date.distantPast
    var endpointHost: UInt32 = 0
    var shown = false
    var lastFrame = Date.distantPast
    var lockFile: Int32 = -1
    var generation: UInt32 = 0
    var owner: GameWindowState?
    var orderedOwner: Int?
    var lastState: Data?
    var presentationCount = 0
    var hideCount = 0
    var stateHistory: [Data] = []
    var browserOpenCount = 0
    var browserOpenFailures = 0
    var captcha: CaptchaBrowser?
    var captchaStatus = "idle"

    init(endpointURL: URL, parent: pid_t) {
        self.endpointURL = endpointURL
        self.parent = parent
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = endpointURL.deletingLastPathComponent().appendingPathComponent("native-ui.lock").path
        lockFile = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
        guard lockFile >= 0, flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSTextView.pasteAsPlainText(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        panel = LoginPanel(contentRect: CGRect(x: 0, y: 0, width: 430, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "账户登录"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .normal
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(scopeChanged), name: name, object: nil)
        }
        form.assets = SdkAssets(directory: endpointURL.deletingLastPathComponent().appendingPathComponent("native-assets"))
        form.frame = panel.contentView!.bounds
        form.autoresizingMask = [.width, .height]
        panel.contentView = form
        form.send = { [weak self] id, action, value, text in
            guard let self else { return }
            self.sendInput(kind: 5, x: Int32(action == 6 ? 1 : action), y: value, button: 0, buttons: 0, modifiers: 0, key: id, text: text)
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        form.requestClose()
        return false
    }

    func windowDidMove(_ notification: Notification) { writeState() }
    func windowDidResize(_ notification: Notification) { writeState() }
    func windowDidResignKey(_ notification: Notification) { writeState() }
    @objc func scopeChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.didActivateApplicationNotification,
           let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            if application.processIdentifier != owner?.pid && application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                if panel.isVisible { panel.orderOut(nil); hideCount += 1 }
                captcha?.follow(owner: panel)
                orderedOwner = nil; writeState(); return
            }
            if application.processIdentifier == ProcessInfo.processInfo.processIdentifier && panel.isVisible { return }
        }
        orderedOwner = nil; followGame()
    }
    func writeState() {
        guard let panel else { return }
        let state: [String: Any] = ["generation": generation, "visible": panel.isVisible, "root": form.scene?.root ?? 0, "sceneType": form.rootType ?? "", "x": panel.frame.minX, "y": panel.frame.minY, "width": panel.frame.width, "height": panel.frame.height, "scale": form.scale, "level": panel.level.rawValue, "gamePID": owner?.pid ?? 0, "gameWindow": owner?.number ?? 0, "gameVisible": owner?.visible ?? false, "gameLevel": owner?.level ?? 0, "panelAboveGame": owner?.panelAbove ?? false, "gameX": owner?.frame.minX ?? 0, "gameY": owner?.frame.minY ?? 0, "gameWidth": owner?.frame.width ?? 0, "gameHeight": owner?.frame.height ?? 0, "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, "frontApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "presentationCount": presentationCount, "hideCount": hideCount, "browserOpenCount": browserOpenCount, "browserOpenFailures": browserOpenFailures, "captchaStatus": captchaStatus, "captchaVisible": captcha?.panel.isVisible ?? false]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), data != lastState {
            lastState = data
            try? data.write(to: endpointURL.deletingLastPathComponent().appendingPathComponent("native-ui-state.json"), options: .atomic)
            stateHistory.append(data)
            if stateHistory.count > 64 { stateHistory.removeFirst(stateHistory.count - 64) }
            var history = Data()
            for entry in stateHistory { history.append(entry); history.append(10) }
            try? history.write(to: endpointURL.deletingLastPathComponent().appendingPathComponent("native-ui-state-history.jsonl"), options: .atomic)
        }
    }

    func connect() {
        guard Date().timeIntervalSince(lastAttempt) > 1 else { return }
        lastAttempt = Date()
        guard let data = try? Data(contentsOf: endpointURL), let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data), endpoint.revision == 2, endpoint.token.utf8.count == 64 else { return }
        let candidate = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard candidate >= 0 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(candidate); return }
        var noSignal: Int32 = 1
        _ = setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let authenticated = endpoint.token.utf8CString.withUnsafeBytes { Darwin.send(candidate, $0.baseAddress, 64, 0) == 64 }
        guard authenticated else { Darwin.close(candidate); return }
        _ = fcntl(candidate, F_SETFL, O_NONBLOCK)
        socket = candidate
        buffer.removeAll(keepingCapacity: true)
        if endpointHost != endpoint.host { endpointHost = endpoint.host }
        lastFrame = Date()
        _ = chmod(endpointURL.path, 0o600)
    }

    func disconnect() {
        captcha?.dismiss()
        if socket >= 0 { Darwin.close(socket) }
        socket = -1
        buffer.removeAll(keepingCapacity: true)
        panel.orderOut(nil)
        form.clear()
        shown = false
        writeState()
    }

    func tick() {
        form.refreshInteraction()
        if socket < 0 { connect() }
        if socket >= 0 {
            var chunk = [UInt8](repeating: 0, count: 262144)
            var readCount = 0
            while readCount < 64 {
                let count = Darwin.recv(socket, &chunk, chunk.count, 0)
                if count > 0 {
                    buffer.append(contentsOf: chunk.prefix(count))
                    parseFrames()
                    readCount += 1
                } else {
                    if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { disconnect() }
                    break
                }
            }
        }
        if parent > 0, kill(parent, 0) != 0, socket < 0 { NSApp.terminate(nil) }
        if shown, Date().timeIntervalSince(lastFrame) > 5 { disconnect() }
        followGame()
    }

    func followGame() {
        guard shown else { return }
        owner = gameWindowState(sessionURL: endpointURL.deletingLastPathComponent().appendingPathComponent("game-session.json"), panelNumber: panel.windowNumber)
        guard let owner, owner.visible else {
            if panel.isVisible { panel.orderOut(nil); hideCount += 1 }
            captcha?.follow(owner: panel)
            orderedOwner = nil
            writeState()
            return
        }
        var target = owner.frame
        if let client = form.scene?.clientArea, client.x >= 0, client.y >= 0, client.width > 0, client.height > 0, client.x + client.width <= 1.001, client.y + client.height <= 1.001 {
            target = CGRect(x: owner.frame.minX + client.x * owner.frame.width, y: owner.frame.maxY - (client.y + client.height) * owner.frame.height, width: client.width * owner.frame.width, height: client.height * owner.frame.height)
        }
        if panel.frame != target { panel.setFrame(target, display: true) }
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard active == owner.pid || active == ProcessInfo.processInfo.processIdentifier else {
            if panel.isVisible { panel.orderOut(nil); hideCount += 1 }
            captcha?.follow(owner: panel)
            orderedOwner = nil
            writeState()
            return
        }
        let level = NSWindow.Level(rawValue: panel.isVisible ? max(panel.level.rawValue, owner.level + 1) : owner.level + 1)
        let changedLevel = panel.level != level
        if changedLevel { panel.level = level }
        if !panel.isVisible || orderedOwner != owner.number || changedLevel {
            panel.orderFrontRegardless()
            panel.makeKey()
            orderedOwner = owner.number
            presentationCount += 1
        }
        captcha?.follow(owner: panel)
        writeState()
    }

    func word(_ offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func parseFrames() {
        while buffer.count >= 36 {
            let magic = word(0), revision = word(4), kind = word(8)
            let bytes = Int(word(28))
            let frameGeneration = word(32)
            guard magic == 0x49555a41, revision == 2, bytes <= 64 * 1024 * 1024 else { disconnect(); return }
            guard buffer.count >= 36 + bytes else { return }
            if kind == 6 {
                let json = buffer.subdata(in: (buffer.startIndex + 36)..<(buffer.startIndex + 36 + bytes))
                if let request = try? JSONDecoder().decode(SdkBrowserRequest.self, from: json) {
                    if request.scene == "captcha" {
                        if request.type == 201 { captcha?.dismiss();captchaStatus = "closed-by-sdk" }
                        else if request.type == 200, CaptchaBrowser.supports(request) {
                            captcha?.dismiss()
                            captchaStatus = "loading"
                            let browser = CaptchaBrowser(request: request, owner: panel)
                            captcha = browser
                            browser.status = { [weak self] status in self?.captchaStatus = status;self?.writeState() }
                            browser.closed = { [weak self] in self?.captcha = nil;self?.writeState() }
                            browserOpenCount += 1
                        } else { browserOpenFailures += 1;captchaStatus = "unsupported-request" }
                    } else if request.type == 200, let raw = request.url, let url = URL(string: raw), ["https", "http"].contains(url.scheme), url.host != nil, NSWorkspace.shared.open(url) { browserOpenCount += 1 }
                } else { browserOpenFailures += 1 }
                writeState()
            } else if kind == 2 {
                captcha?.dismiss()
                panel.orderOut(nil)
                        form.clear()
                shown = false
                generation = frameGeneration
                writeState()
            } else if kind == 3 {
                let json = buffer.subdata(in: (buffer.startIndex + 36)..<(buffer.startIndex + 36 + bytes))
                if let scene = try? JSONDecoder().decode(SdkScene.self, from: json) { presentScene(scene) }
                lastFrame = Date()
            } else if kind == 4, frameGeneration == generation {
                let values = buffer.subdata(in: (buffer.startIndex + 36)..<(buffer.startIndex + 36 + bytes))
                var offset = 0
                while offset + 8 <= values.count {
                    let id = values.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
                    let count = values.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))) }
                    guard count <= 16384, offset + 8 + count * 2 <= values.count else { break }
                    let text = values.subdata(in: (offset + 8)..<(offset + 8 + count * 2))
                    if let value = String(data: text, encoding: .utf16LittleEndian) { form.syncValue(id: id, value: value) }
                    offset += 8 + count * 2
                }
            } else if kind == 5, frameGeneration == generation {
                let width = Int(word(12)), height = Int(word(16)), id = word(20)
                if width > 0, height > 0, width <= 4096, height <= 4096, bytes == width * height * 4 {
                    let pixels = buffer.subdata(in: (buffer.startIndex + 36)..<(buffer.startIndex + 36 + bytes))
                    if let provider = CGDataProvider(data: pixels as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue).union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) { form.syncVisual(id: id, image: image) }
                }
            }
            buffer.removeFirst(36 + bytes)
        }
    }

    func presentScene(_ scene: SdkScene) {
        generation = scene.generation
        _ = form.apply(scene)
        panel.title = scene.phase == 1 ? "用户协议" : "账户登录"
        if !shown {
            shown = true
        }
        followGame()
        writeState()
    }

    func sendInput(kind: UInt32, x: Int32, y: Int32, button: UInt32, buttons: UInt32, modifiers: UInt32, key: UInt32, text: String) {
        guard socket >= 0 else { return }
        let characters = Array(text.utf16.prefix(16384))
        var payload = Data()
        for value in [kind, UInt32(bitPattern: x), UInt32(bitPattern: y), button, buttons, modifiers, key, UInt32(characters.count), generation] {
            var encoded = value.littleEndian
            withUnsafeBytes(of: &encoded) { payload.append(contentsOf: $0) }
        }
        for character in characters {
            var encoded = character.littleEndian
            withUnsafeBytes(of: &encoded) { payload.append(contentsOf: $0) }
        }
        var length = UInt32(payload.count).littleEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(payload)
        let sent = packet.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, packet.count, 0) }
        if sent != packet.count { disconnect() }
        payload.resetBytes(in: 0..<payload.count)
        packet.resetBytes(in: 0..<packet.count)
    }
}

@main
struct NativeLoginMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { exit(2) }
        let app = NSApplication.shared
        if arguments[1] == "--notice", arguments.count >= 3 {
            app.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "账户登录"
            alert.informativeText = arguments[2]
            alert.addButton(withTitle: "知道了")
            alert.window.level = .normal
            app.activate(ignoringOtherApps: true)
            alert.runModal()
            exit(0)
        }
        let delegate = LoginApplication(endpointURL: URL(fileURLWithPath: arguments[1]), parent: arguments.count > 2 ? pid_t(arguments[2]) ?? 0 : 0)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
