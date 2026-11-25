import AppKit

enum PolicyListProbeError: Error { case failed(String) }

@main
struct PolicyListProbe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let source = try JSONDecoder().decode(SdkScene.self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/user-center-policy-scene-fixture.json")))
        let owner = NSPanel(contentRect: CGRect(x: -5000, y: -5000, width: 430, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let scene = NativeSceneView(frame: owner.contentView!.bounds)
        scene.assets = SdkAssets(directory: URL(fileURLWithPath: "Tests/Fixtures/Assets"))
        owner.contentView = scene
        _ = scene.apply(source)
        guard let scrollNode = source.nodes.first(where: { $0.type == "mj_base::CustomScrollArea" }), let scroll = scene.views[scrollNode.id] as? NativeSdkScroll else { throw PolicyListProbeError.failed("SDK scroll container missing") }
        guard scroll.frame.height == 290, scroll.document.bounds.height == 468 else { throw PolicyListProbeError.failed("SDK viewport or content size differs") }
        let entries = source.nodes.filter { $0.type == "mj_official_cn::LicenseAgreementBtn" }
        guard entries.count == 8, entries.allSatisfy({ scene.views[$0.id] is SdkButton }) else { throw PolicyListProbeError.failed("Policy entry missing") }
        var clicked: UInt32 = 0
        var scrollPosition: Int32 = -1
        scene.send = { id, action, value, _ in
            if action == 6 { clicked = id }
            if action == 4 && id == scrollNode.id { scrollPosition = value }
        }
        for node in entries {
            guard let button = scene.views[node.id] as? SdkButton else { continue }
            let y = max(0, min(button.frame.midY - scroll.contentSize.height / 2, scroll.document.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y));scroll.reflectScrolledClipView(scroll.contentView)
            let point = scene.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
            guard scene.hitTest(scene.convert(point, to: scene.superview)) === button else { throw PolicyListProbeError.failed("Policy label blocks entry hit") }
            button.performClick(nil)
            guard clicked == node.id else { throw PolicyListProbeError.failed("Policy entry click failed") }
            if let labelNode = source.nodes.first(where: { $0.parent == node.id && $0.kind == "label" }), let label = scene.views[labelNode.id] as? SdkText, let manager = label.text.layoutManager, let container = label.text.textContainer {
                manager.ensureLayout(for: container)
                guard label.singleLine, let rendered = label.singleLineText else { throw PolicyListProbeError.failed("Policy title wraps") }
                let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(rendered), [.useGlyphPathBounds])
                guard ink.height <= label.contentSize.height + 1 else { throw PolicyListProbeError.failed("Policy title clips") }
            }
        }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.document.bounds.height - scroll.contentSize.height))
        scroll.scrolled()
        guard scrollPosition == 10000 else { throw PolicyListProbeError.failed("SDK scrollbar action missing") }
        scroll.synchronize(size: scroll.document.frame.size, offset: 0)
        guard abs(scroll.contentView.bounds.minY - 178) < 1 else { throw PolicyListProbeError.failed("Stale SDK frame pulled scroll back") }
        let bitmap = scene.bitmapImageRepForCachingDisplay(in: scene.bounds)!
        scene.cacheDisplay(in: scene.bounds, to: bitmap)
        owner.close()
        print("Policy list: SDK viewport/content sizes, eight entries, clipped scrolling, one-line titles and all hit targets: PASS")
    }
}
