import Foundation

@main struct ContainerEntryProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = root.appendingPathComponent("容器 带空格")
        let menu = bottle.appendingPathComponent("desktopdata/cxmenu")
        let entry = menu.appendingPathComponent("Programs/蓝色星原：旅谣.lnk")
        let other = menu.appendingPathComponent("Programs/other.lnk")
        let base = root.appendingPathComponent("修复'目录")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("backup"), withIntermediateDirectories: true)
        let original = "#!/bin/sh\nexit 0\n"
        try original.write(to: entry, atomically: true, encoding: .utf8)
        try original.write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        let document: [String: Any] = ["test": ["Children": ["game": ["RawPath": "Programs/蓝色星原：旅谣.lnk", "Command": "\"" + entry.path + "\""], "other": ["RawPath": "Programs/other.lnk", "Command": "\"" + other.path + "\""]]]]
        try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0).write(to: menu.appendingPathComponent("cxmenu_macosx.plist"))
        var config = RepairConfiguration(version: 1, bottle: bottle.path, crossOver: "", runtime: "", game: "", base: base.path, originalSDK: "", originalBrowser: "", managedSDK: "", managedBrowser: "")
        try RepairEngine.patchContainerEntries(&config)
        guard config.menuEntries?.count == 1, try String(contentsOf: other, encoding: .utf8) == original else { throw RepairFailure(message: "错误修改了其他启动项") }
        try RepairEngine.run("/bin/sh", ["-n", entry.path])
        guard FileManager.default.isExecutableFile(atPath: entry.path) else { throw RepairFailure(message: "启动脚本没有执行权限") }
        try RepairEngine.patchContainerEntries(&config)
        try RepairEngine.restoreContainerEntries(config)
        guard try String(contentsOf: entry, encoding: .utf8) == original else { throw RepairFailure(message: "未恢复原启动脚本") }
        let changed = "#!/bin/sh\nprintf updated\n"
        try changed.write(to: entry, atomically: true, encoding: .utf8)
        try RepairEngine.restoreContainerEntries(config)
        guard try String(contentsOf: entry, encoding: .utf8) == changed else { throw RepairFailure(message: "覆盖了第三方更新的启动项") }
        print("CrossOver 容器入口：精确匹配、路径转义、重复接入、恢复及保留外部更新：PASS")
    }
}
