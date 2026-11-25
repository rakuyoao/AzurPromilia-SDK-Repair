import Foundation
import AppKit
import CryptoKit
import Darwin

struct RepairFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RepairMenuEntry: Codable, Sendable {
    let path: String
    let backup: String
    let managedHash: String
}

struct RepairConfiguration: Codable, Sendable {
    let version: Int
    let bottle: String
    let crossOver: String
    let runtime: String
    let game: String
    let base: String
    var shortcut: String?
    var menuEntries: [RepairMenuEntry]?
    var originalSDK: String
    var originalBrowser: String
    var managedSDK: String
    var managedBrowser: String
    var configurationURL: URL { URL(fileURLWithPath: base).appendingPathComponent("installation.json") }
    var bottleURL: URL { URL(fileURLWithPath: bottle) }
    var gameURL: URL { URL(fileURLWithPath: game) }
    var baseURL: URL { URL(fileURLWithPath: base) }
    var sdkURL: URL { gameURL.appendingPathComponent("AzurPromilia_Data/Plugins/mj_sdk") }
    var wine: URL { URL(fileURLWithPath: crossOver).appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine") }
    var runtimeRoot: URL { URL(fileURLWithPath: runtime).appendingPathComponent("Contents/SharedSupport/CrossOver") }
}

enum RepairEngine {
    static let managerHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/AzurSDKRepair")
    static let officialSDK = "939448f9a0a7a47e6f645d20497a454b43000982406a058965652b53a86fc697"
    static let officialBrowser = "7eaed6b9f620f57a613a81db499eac5ec3005d470b19be5fb9bee29be3aced44"

    static func hash(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, acceptedStatuses: Set<Int32> = [0]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard acceptedStatuses.contains(process.terminationStatus) else { throw RepairFailure(message: "命令失败：\(URL(fileURLWithPath: executable).lastPathComponent)，状态 \(process.terminationStatus)\n\(text.suffix(2500))") }
        return text
    }

    static func replace(_ source: URL, _ destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).azur-stage")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: source, to: temporary)
        if let mode = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw RepairFailure(message: "无法替换文件：\(destination.path)")
        }
    }

    static func bottles() -> [URL] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        return ((try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? []).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cxbottle.conf").path) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func isCrossOver(_ app: URL) -> Bool {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.codeweavers.CrossOver" else { return false }
        return FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine").path)
    }

    @MainActor static func findCrossOver() -> URL? {
        let workspace = NSWorkspace.shared
        var candidates: [URL] = []
        if let preferred = workspace.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver") { candidates.append(preferred) }
        candidates += workspace.urlsForApplications(withBundleIdentifier: "com.codeweavers.CrossOver")
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        for folder in folders {
            candidates += ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        }
        let managed = managerHome.resolvingSymlinksInPath().path + "/"
        var visited = Set<String>()
        return candidates.map { $0.resolvingSymlinksInPath().standardizedFileURL }.first {
            visited.insert($0.path).inserted && !$0.path.hasPrefix(managed) && isCrossOver($0)
        }
    }

    static func findGame(in bottle: URL) -> URL? {
        guard let iterator = FileManager.default.enumerator(at: bottle.appendingPathComponent("drive_c"), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        for case let file as URL in iterator where file.lastPathComponent == "AzurPromilia.exe" {
            let folder = file.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("AzurPromilia_Data/Plugins/mj_sdk/union_pcsdk.dll").path) { return folder }
        }
        return nil
    }

    static func read(_ url: URL) throws -> RepairConfiguration { try JSONDecoder().decode(RepairConfiguration.self, from: Data(contentsOf: url)) }
    static func write(_ configuration: RepairConfiguration) throws {
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: configuration.configurationURL, options: .atomic)
    }

    static func windowsPath(_ url: URL, bottle: URL) -> String {
        let drive = bottle.appendingPathComponent("drive_c").path + "/"
        if url.path.hasPrefix(drive) { return "C:\\" + String(url.path.dropFirst(drive.count)).replacingOccurrences(of: "/", with: "\\") }
        return "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    static func processes(_ configuration: RepairConfiguration) throws -> Set<Int32> {
        let image = windowsPath(configuration.gameURL.appendingPathComponent("AzurPromilia.exe"), bottle: configuration.bottleURL)
        let listing = try run("/bin/ps", ["-axo", "pid=,args="])
        var found = Set<Int32>()
        for row in listing.split(separator: "\n") {
            let parts = row.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2, let pid = Int32(parts[0]), parts[1] == image || parts[1].hasPrefix(image + " ") { found.insert(pid) }
        }
        return found
    }

    static func editBottle(_ file: URL, values: [String: [String: String]]) throws {
        var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        for (section, settings) in values {
            for (key, value) in settings {
                let heading = "[\(section)]"
                if !lines.contains(heading) { lines.append(contentsOf: ["", heading]) }
                let start = lines.firstIndex(of: heading)!
                let end = lines[(start + 1)...].firstIndex(where: { $0.hasPrefix("[") }) ?? lines.endIndex
                let prefix = "\"\(key)\""
                let new = "\"\(key)\" = \"\(value)\""
                if let index = lines[(start + 1)..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }) { lines[index] = new }
                else { lines.insert(new, at: end) }
            }
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    @concurrent static func install(crossOver: URL, bottle: URL, game: URL, payload: URL, manager: URL, progress: @Sendable (String) -> Void) async throws -> RepairConfiguration {
        guard game.path.hasPrefix(bottle.appendingPathComponent("drive_c").path + "/") else { throw RepairFailure(message: "当前版本要求游戏安装在所选容器的 drive_c 内。") }
        guard [crossOver.path, bottle.path, game.path, managerHome.path].allSatisfy({ !$0.contains("\"") && !$0.contains("\n") && !$0.contains("\r") }) else { throw RepairFailure(message: "安装路径包含容器配置不支持的引号或换行。") }
        let identifier = String(SHA256.hash(data: Data((bottle.path + game.path).utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        let base = managerHome.appendingPathComponent(identifier)
        if FileManager.default.fileExists(atPath: base.appendingPathComponent("installation.json").path) { throw RepairFailure(message: "此容器已安装修复。请先恢复原配置，再重新安装。") }
        let sdk = game.appendingPathComponent("AzurPromilia_Data/Plugins/mj_sdk")
        guard try hash(sdk.appendingPathComponent("union_pcsdk.dll")) == officialSDK, try hash(sdk.appendingPathComponent("manjuu_sdk_browser.exe")) == officialBrowser else { throw RepairFailure(message: "这版游戏 SDK 与已验证版本不同，或仍有旧修复。已停止安装，未覆盖原文件。") }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: crossOver.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        let moduleVersion = try String(contentsOf: payload.appendingPathComponent("modules/CROSSOVER_VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = plist?["CFBundleVersion"] as? String, version == moduleVersion || version.hasPrefix(moduleVersion + ".") else { throw RepairFailure(message: "FineWine 模块要求 CrossOver \(moduleVersion)，不能应用到不同版本的运行库。") }
        var config = RepairConfiguration(version: 1, bottle: bottle.path, crossOver: crossOver.path, runtime: base.appendingPathComponent("runtime/CrossOver.app").path, game: game.path, base: base.path, originalSDK: officialSDK, originalBrowser: officialBrowser, managedSDK: try hash(payload.appendingPathComponent("bin/union_pcsdk.dll")), managedBrowser: try hash(payload.appendingPathComponent("bin/azur-policy-browser.exe")))
        guard try processes(config).isEmpty else { throw RepairFailure(message: "请先退出游戏后安装修复。") }
        guard !FileManager.default.fileExists(atPath: base.path) else { throw RepairFailure(message: "存在旧安装目录。请先从原工具恢复配置，避免覆盖备份。") }
        guard !(try containerLaunchEntries(in: bottle)).isEmpty else { throw RepairFailure(message: "未找到这个容器中的官方游戏启动入口。请先在 CrossOver 中确认已有“蓝色星原：旅谣”启动项。") }
        try verifyModules(payload.appendingPathComponent("modules"))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        do {
        try FileManager.default.createDirectory(at: base.appendingPathComponent("backup"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("runtime"), withIntermediateDirectories: true)
        progress("备份容器设置与官方 SDK…")
        try FileManager.default.copyItem(at: bottle.appendingPathComponent("cxbottle.conf"), to: base.appendingPathComponent("backup/cxbottle.conf"))
        try FileManager.default.copyItem(at: sdk.appendingPathComponent("union_pcsdk.dll"), to: base.appendingPathComponent("backup/union_pcsdk.dll"))
        try FileManager.default.copyItem(at: sdk.appendingPathComponent("manjuu_sdk_browser.exe"), to: base.appendingPathComponent("backup/manjuu_sdk_browser.exe"))
        try FileManager.default.copyItem(at: payload.appendingPathComponent("bin"), to: base.appendingPathComponent("bin"))
        try FileManager.default.copyItem(at: manager, to: base.appendingPathComponent("bin/AzurSDKManager"))
        progress("创建独立 CrossOver 运行库副本…")
        try run("/usr/bin/ditto", [crossOver.path, config.runtime])
        let swaps = ["ntdll.so": "lib/wine/x86_64-unix/ntdll.so", "winemac.so": "lib/wine/x86_64-unix/winemac.so", "dwmapi.dll": "lib/wine/x86_64-windows/dwmapi.dll", "kernel32.dll": "lib/wine/x86_64-windows/kernel32.dll", "ntoskrnl.exe": "lib/wine/x86_64-windows/ntoskrnl.exe", "lsass.exe": "lib/wine/x86_64-windows/lsass.exe", "wineboot.exe": "lib/wine/x86_64-windows/wineboot.exe", "rundll32.exe": "lib/wine/x86_64-windows/rundll32.exe", "libMoltenVK.dylib": "lib64/libMoltenVK.dylib"]
        for (module, relative) in swaps { try replace(payload.appendingPathComponent("modules/" + module), config.runtimeRoot.appendingPathComponent(relative)) }
        for relative in ["bin/wineserver", "CrossOver-Hosted Application/wineserver"] { try replace(payload.appendingPathComponent("modules/wineserver"), config.runtimeRoot.appendingPathComponent(relative)) }
        for relative in ["lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-unix/winemac.so", "lib/wine/x86_64-windows/rundll32.exe", "lib64/libMoltenVK.dylib", "bin/wineserver", "CrossOver-Hosted Application/wineserver"] { try run("/usr/bin/codesign", ["--force", "--sign", "-", config.runtimeRoot.appendingPathComponent(relative).path]) }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.runtime).appendingPathComponent("Contents/_CodeSignature"))
        progress("接入容器与启动器…")
        try editBottle(bottle.appendingPathComponent("cxbottle.conf"), values: ["EnvironmentVariables": ["FINEWINE_AZUR_PREVIEW": "1", "FINEWINE_AZUR_NATIVE_UI": "1"], "Wine": ["BinPath": config.runtimeRoot.appendingPathComponent("bin").path, "LibPath": config.runtimeRoot.appendingPathComponent("lib").path]])
        try patchShortcut(&config)
        try patchContainerEntries(&config)
        try write(config)
        try removeLegacyLauncher()
        try config.configurationURL.path.write(to: managerHome.appendingPathComponent("last-installation.txt"), atomically: true, encoding: .utf8)
        progress("安装完成。可以直接从 CrossOver 原容器的游戏启动项进入。")
        return config
        } catch {
            do {
                let backup = base.appendingPathComponent("backup/cxbottle.conf")
                if FileManager.default.fileExists(atPath: backup.path) { try replace(backup, bottle.appendingPathComponent("cxbottle.conf")) }
                if let shortcut = config.shortcut {
                    try replace(base.appendingPathComponent("backup/shortcut-Info.plist"), URL(fileURLWithPath: shortcut).appendingPathComponent("Contents/Info.plist"))
                    try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", shortcut])
                }
                try restoreContainerEntries(config)
                try FileManager.default.removeItem(at: base)
            } catch let rollbackError {
                try? write(config)
                throw RepairFailure(message: "安装未完成，自动恢复也未完成。备份保留于 \(base.path)。恢复错误：\(rollbackError.localizedDescription)")
            }
            throw error
        }
    }

    static func removeLegacyLauncher() throws {
        let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/蓝原启动器（修复）.app")
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "org.azursdkrepair.launcher" else { return }
        try FileManager.default.removeItem(at: app)
    }

    static func containerLaunchEntries(in bottle: URL) throws -> [URL] {
        let root = bottle.appendingPathComponent("desktopdata/cxmenu")
        let file = root.appendingPathComponent("cxmenu_macosx.plist")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let document = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
        var entries: [URL] = []
        func visit(_ value: Any) throws {
            guard let object = value as? [String: Any] else { return }
            if let raw = object["RawPath"] as? String, (raw as NSString).lastPathComponent == "蓝色星原：旅谣.lnk", let command = object["Command"] as? String {
                let quoted = command.count >= 2 && ((command.first == "\"" && command.last == "\"") || (command.first == "'" && command.last == "'"))
                let path = quoted ? String(command.dropFirst().dropLast()) : command
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw RepairFailure(message: "CrossOver 游戏启动项指向无效脚本，已停止接入。") }
                entries.append(url)
            }
            for child in object.values { try visit(child) }
        }
        try visit(document)
        return Array(Set(entries)).sorted { $0.path < $1.path }
    }

    static func patchContainerEntries(_ configuration: inout RepairConfiguration) throws {
        let script = "#!/bin/sh\nexec " + quote(configuration.baseURL.appendingPathComponent("bin/AzurSDKManager").path) + " --launch " + quote(configuration.configurationURL.path) + "\n"
        let data = Data(script.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        for file in try containerLaunchEntries(in: configuration.bottleURL) {
            let entries = configuration.menuEntries ?? []
            if let entry = entries.first(where: { $0.path == file.path }) {
                guard try hash(file) == entry.managedHash else { throw RepairFailure(message: "CrossOver 游戏启动项已被其他程序更新，请先恢复并重新安装修复。") }
            } else {
                let backup = "backup/menu-entry-\(entries.count).sh"
                try FileManager.default.copyItem(at: file, to: configuration.baseURL.appendingPathComponent(backup))
                configuration.menuEntries = entries + [RepairMenuEntry(path: file.path, backup: backup, managedHash: digest)]
            }
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    static func restoreContainerEntries(_ configuration: RepairConfiguration) throws {
        for entry in configuration.menuEntries ?? [] {
            let file = URL(fileURLWithPath: entry.path)
            let managed = FileManager.default.fileExists(atPath: file.path) ? try hash(file) == entry.managedHash : true
            if managed {
                try replace(configuration.baseURL.appendingPathComponent(entry.backup), file)
            }
        }
    }

    static func verifyModules(_ folder: URL) throws {
        let lines = try String(contentsOf: folder.appendingPathComponent("SHA256SUMS"), encoding: .utf8).split(separator: "\n")
        for line in lines {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { throw RepairFailure(message: "运行库校验文件格式无效。") }
            let name = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            guard !name.contains("/"), try hash(folder.appendingPathComponent(name)) == fields[0] else { throw RepairFailure(message: "运行库文件校验失败：\(name)") }
        }
        guard !lines.isEmpty else { throw RepairFailure(message: "运行库校验列表为空。") }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func patchShortcut(_ configuration: inout RepairConfiguration) throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver")
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for app in apps where app.pathExtension == "app" {
            let file = app.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: file), var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let command = plist["CrossOverHelperCommand"] as? String,
                  command.contains(configuration.bottle), plist["CFBundleName"] as? String == "蓝色星原：旅谣" else { continue }
            try data.write(to: configuration.baseURL.appendingPathComponent("backup/shortcut-Info.plist"), options: .atomic)
            configuration.shortcut = app.path
            plist["CrossOverHelperCommand"] = quote(configuration.baseURL.appendingPathComponent("bin/AzurSDKManager").path) + " --launch " + quote(configuration.configurationURL.path)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file, options: .atomic)
            try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
            return
        }
    }

    static func restoreComponents(_ configuration: RepairConfiguration) throws {
        for (name, managed) in [("union_pcsdk.dll", configuration.managedSDK), ("manjuu_sdk_browser.exe", configuration.managedBrowser)] {
            let file = configuration.sdkURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path), try hash(file) == managed { try replace(configuration.baseURL.appendingPathComponent("backup/" + name), file) }
        }
    }

    static func launcher(_ configuration: RepairConfiguration) throws -> URL {
        let root = configuration.gameURL.deletingLastPathComponent()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let candidates = ([root] + folders).map { $0.appendingPathComponent("launcher.exe") }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let latest = candidates.sorted(by: { $0.deletingLastPathComponent().lastPathComponent.compare($1.deletingLastPathComponent().lastPathComponent, options: .numeric) == .orderedDescending }).first else { throw RepairFailure(message: "没有找到官方 launcher.exe。请先确认启动器与游戏位于同一个安装目录。") }
        return latest
    }

    static func launch(_ file: URL) throws {
        let configuration = try read(file)
        guard try processes(configuration).isEmpty else { return }
        try restoreComponents(configuration)
        let log = configuration.baseURL.appendingPathComponent("monitor.log")
        if !FileManager.default.fileExists(atPath: log.path) { _ = FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let output = try FileHandle(forWritingTo: log);try output.seekToEnd()
        let monitor = Process();monitor.executableURL = configuration.baseURL.appendingPathComponent("bin/AzurSDKManager");monitor.arguments = ["--monitor", file.path, String(getpid())];monitor.standardOutput = output;monitor.standardError = output
        try monitor.run()
        defer {
            if monitor.isRunning { monitor.terminate() }
            if (try? processes(configuration).isEmpty) == true { try? restoreComponents(configuration) }
            try? output.close()
        }
        let wine = Process(); wine.executableURL = configuration.wine
        wine.arguments = ["--bottle", configuration.bottleURL.lastPathComponent, "--check", "--wait-children", "--start", windowsPath(try launcher(configuration), bottle: configuration.bottleURL)]
        wine.standardOutput = FileHandle.nullDevice; wine.standardError = FileHandle.nullDevice
        try wine.run(); wine.waitUntilExit()
        guard wine.terminationStatus == 0 else { throw RepairFailure(message: "官方启动器已退出，状态：\(wine.terminationStatus)。") }
    }

    static func monitor(_ file: URL, parent: Int32) throws {
        let config = try read(file)
        let descriptor = Darwin.open(config.baseURL.appendingPathComponent("monitor.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw RepairFailure(message: "无法创建运行锁。") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        func startUI() throws -> Process {
            let process = Process();process.executableURL = config.baseURL.appendingPathComponent("bin/AzurAccountLogin.app/Contents/MacOS/azur-login-ui");process.arguments = [config.bottleURL.appendingPathComponent("drive_c/FineWine/native-endpoint.json").path, String(parent)];try process.run();return process
        }
        var native = try startUI()
        defer { if native.isRunning { native.terminate() } }
        var seen = Set<Int32>()
        var session: Int32 = -1
        let stateRoot = config.bottleURL.appendingPathComponent("drive_c/FineWine")
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        while kill(parent, 0) == 0 {
            let current = try processes(config)
            let pid = current.min() ?? 0
            if pid != session {
                try JSONSerialization.data(withJSONObject: ["pid": pid]).write(to: stateRoot.appendingPathComponent("game-session.json"), options: .atomic)
                session = pid
            }
            if !seen.isEmpty && current.isEmpty { try restoreComponents(config) }
            if !native.isRunning { native = try startUI() }
            for pid in current.subtracting(seen) {
                guard kill(pid, SIGSTOP) == 0 else { continue }
                defer { _ = kill(pid, SIGCONT) }
                do {
                    let target = config.sdkURL.appendingPathComponent("union_pcsdk.dll"), browser = config.sdkURL.appendingPathComponent("manjuu_sdk_browser.exe")
                    let sdkHash = try hash(target), browserHash = try hash(browser)
                    guard [config.originalSDK, config.managedSDK].contains(sdkHash), [config.originalBrowser, config.managedBrowser].contains(browserHash) else { throw RepairFailure(message: "游戏 SDK 已更新。本版兼容层停止接入，原文件保持不变；请先更新修复工具。") }
                    try replace(config.baseURL.appendingPathComponent("backup/union_pcsdk.dll"), config.sdkURL.appendingPathComponent("union_pcsdk_original.dll"))
                    try replace(config.baseURL.appendingPathComponent("bin/union_pcsdk.dll"), target)
                    try replace(config.baseURL.appendingPathComponent("bin/azur-policy-browser.exe"), browser)
                    for name in ["azur-sdk-host.exe", "azur-policy-browser.exe"] { try replace(config.baseURL.appendingPathComponent("bin/" + name), config.gameURL.appendingPathComponent(name)) }
                    print("已接入游戏 SDK。")
                } catch {
                    _ = kill(pid, SIGTERM)
                    let notice = Process();notice.executableURL = config.baseURL.appendingPathComponent("bin/AzurAccountLogin.app/Contents/MacOS/azur-login-ui");notice.arguments = ["--notice", error.localizedDescription];try? notice.run()
                }
            }
            seen = current
            Thread.sleep(forTimeInterval: 0.1)
        }
        if try processes(config).isEmpty { try restoreComponents(config) }
    }

    @concurrent static func uninstall(_ file: URL) async throws {
        let configuration = try read(file)
        guard try processes(configuration).isEmpty else { throw RepairFailure(message: "请先退出游戏和启动器，再恢复原配置。") }
        var environment = ProcessInfo.processInfo.environment;environment["WINEPREFIX"] = configuration.bottle
        try run(configuration.runtimeRoot.appendingPathComponent("bin/wineserver").path, ["-k"], environment: environment, acceptedStatuses: [0, 1])
        try restoreComponents(configuration)
        try replace(configuration.baseURL.appendingPathComponent("backup/cxbottle.conf"), configuration.bottleURL.appendingPathComponent("cxbottle.conf"))
        if let shortcut = configuration.shortcut {
            let app = URL(fileURLWithPath: shortcut)
            try replace(configuration.baseURL.appendingPathComponent("backup/shortcut-Info.plist"), app.appendingPathComponent("Contents/Info.plist"))
            try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", shortcut])
        }
        try restoreContainerEntries(configuration)
        for name in ["azur-sdk-host.exe", "azur-policy-browser.exe"] { try? FileManager.default.removeItem(at: configuration.gameURL.appendingPathComponent(name)) }
        if let path = try? hash(configuration.sdkURL.appendingPathComponent("union_pcsdk_original.dll")), path == configuration.originalSDK { try FileManager.default.removeItem(at: configuration.sdkURL.appendingPathComponent("union_pcsdk_original.dll")) }
        try removeLegacyLauncher()
        try FileManager.default.removeItem(at: configuration.baseURL)
        try? FileManager.default.removeItem(at: managerHome.appendingPathComponent("last-installation.txt"))
    }
}
