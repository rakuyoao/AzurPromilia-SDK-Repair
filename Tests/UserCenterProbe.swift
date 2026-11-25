import AppKit

enum UserCenterProbeError: Error { case failed(String) }

@main
struct UserCenterProbe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let source = try JSONDecoder().decode(SdkScene.self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/user-center-scene-fixture.json")))
        let panel = NSPanel(contentRect: CGRect(x: -5000, y: -5000, width: 430, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let scene = NativeSceneView(frame: panel.contentView!.bounds)
        panel.contentView = scene
        scene.assets = SdkAssets(directory: URL(fileURLWithPath: "Tests/Fixtures/Assets"))
        _ = scene.apply(source)
        var clicked: UInt32 = 0
        scene.send = { id, action, _, _ in if action == 6 { clicked = id } }
        let buttons = source.nodes.filter { $0.type == "mj_official_cn::UserCenterBtn" }
        guard buttons.count == 6 else { throw UserCenterProbeError.failed("Six user-center options expected") }
        for node in buttons {
            guard let button = scene.views[node.id] as? SdkButton else { throw UserCenterProbeError.failed("User-center option is passive") }
            for point in [scene.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button), scene.convert(CGPoint(x: 3, y: 3), from: button)] {
                guard scene.hitTest(scene.convert(point, to: scene.superview)) === button else { throw UserCenterProbeError.failed("Option text blocks pointer") }
            }
            button.performClick(nil)
            guard clicked == node.id, button.backgroundResource != nil else { throw UserCenterProbeError.failed("Option action or background missing") }
        }
        for node in source.nodes where node.kind == "label" && node.parent == source.nodes.first(where: { $0.type == "mj_official_cn::UserCenterPage" })?.id {
            guard let label = scene.views[node.id] as? SdkText, let manager = label.text.layoutManager, let container = label.text.textContainer else { continue }
            manager.ensureLayout(for: container)
            let rect = manager.usedRect(for: container)
            guard rect.height <= label.contentSize.height + 1, rect.width <= label.contentSize.width + 1 else { throw UserCenterProbeError.failed("Account header wraps or clips") }
            print("Header", node.id, "glyphs", manager.numberOfGlyphs, "SDK size", node.rect.size, "text layout", rect.size)
        }
        let bitmap = scene.bitmapImageRepForCachingDisplay(in: scene.bounds)!
        scene.cacheDisplay(in: scene.bounds, to: bitmap)
        panel.close()
        print("Six user-center options: background, text hit area and real pointer-action route: PASS")
    }
}
