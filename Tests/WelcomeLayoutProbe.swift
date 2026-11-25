import AppKit

enum WelcomeProbeError: Error { case failed(String) }

@main
struct WelcomeLayoutProbe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        func require(_ value: Bool, _ message: String) throws { if !value { throw WelcomeProbeError.failed(message) } }
        let url = URL(fileURLWithPath: "Tests/Fixtures/login-succeed-scene-fixture.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let initial = try JSONDecoder().decode(SdkScene.self, from: Data(contentsOf: url))
        let banner = initial.nodes.first { $0.parent == initial.root && $0.image != nil }!
        let account = initial.nodes.first { $0.kind == "label" && $0.text == "测试账号" }!
        let welcome = initial.nodes.first { $0.kind == "label" && $0.text?.contains("欢迎") == true }!
        let button = initial.nodes.first { $0.kind == "button" && $0.text == "切换账号" }!
        let scene = NativeSceneView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        scene.assets = SdkAssets(directory: URL(fileURLWithPath: "Tests/Fixtures/Assets"))
        _ = scene.apply(initial)
        try require(scene.isWelcomeBanner && scene.card.size == banner.rect.size, "Welcome is not a banner")
        var originalFrames: [UInt32: CGRect] = [:]
        for node in [account, welcome, button] {
            guard let view = scene.views[node.id] else { throw WelcomeProbeError.failed("Welcome content missing") }
            originalFrames[node.id] = view.frame
            try require(CGRect(origin: scene.origin, size: scene.card.size).contains(view.frame), "Welcome content clipped")
        }
        let image = scene.views[banner.id]!
        for node in [account, welcome, button] {
            try require(scene.subviews.firstIndex(of: image)! < scene.subviews.firstIndex(of: scene.views[node.id]!)!, "Banner covers content")
        }
        try require(abs(scene.origin.y - 60) < 0.01 && abs(scene.origin.x + scene.card.width / 2 - scene.bounds.midX) < 0.01, "Welcome top placement")
        for y in [-54.0, 0.0, 60.0] {
            var moved = json
            var nodes = json["nodes"] as! [[String: Any]]
            for index in nodes.indices {
                let id = UInt32(nodes[index]["id"] as! Int)
                if id != initial.root && nodes[index]["type"] as? String != "mj_base::CenterWidget" {
                    nodes[index]["y"] = (nodes[index]["y"] as! Double) + y - banner.y
                }
            }
            moved["nodes"] = nodes
            _ = scene.apply(try JSONDecoder().decode(SdkScene.self, from: JSONSerialization.data(withJSONObject: moved)))
            for (id, frame) in originalFrames { try require(scene.views[id]?.frame == frame, "SDK animation moved native banner") }
        }
        let bitmap = scene.bitmapImageRepForCachingDisplay(in: scene.bounds)!
        scene.cacheDisplay(in: scene.bounds, to: bitmap)
        try require((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01, "White backdrop retained")
        scene.setFrameSize(CGSize(width: 1400, height: 900))
        try require(abs(scene.origin.y - 60) < 0.01 && abs(scene.origin.x + scene.card.width / 2 - 700) < 0.01, "Welcome changed top position after resizing")
        var clicked: UInt32 = 0
        scene.send = { id, action, _, _ in if action == 1 { clicked = id } }
        (scene.views[button.id] as? SdkButton)?.performClick(nil)
        try require(clicked == button.id, "Switch account action missing")
        var loading = json
        var root = (json["nodes"] as! [[String: Any]]).first { ($0["id"] as? Int) == Int(initial.root) }!
        for type in ["mj_base::LoadingWnd", "mj_base::WebViewLoadingWidget", "mj_base::MjCaptchaWnd"] {
            root["type"] = type;loading["nodes"] = [root]
            _ = scene.apply(try JSONDecoder().decode(SdkScene.self, from: JSONSerialization.data(withJSONObject: loading)))
            try require(scene.isLoadingOverlay && scene.views.isEmpty, "Loading overlay remained visible")
            let blank = scene.bitmapImageRepForCachingDisplay(in: scene.bounds)!
            scene.cacheDisplay(in: scene.bounds, to: blank)
            try require((blank.colorAt(x: blank.pixelsWide / 2, y: blank.pixelsHigh / 2)?.alphaComponent ?? 1) < 0.01, "Loading backdrop remained visible")
        }
        print("Welcome content, paint order, fixed top placement, resize and account switch action: PASS")
        print("Welcome animation offsets and three SDK loading roots retain transparent background: PASS")
    }
}
