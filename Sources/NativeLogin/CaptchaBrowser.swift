import AppKit
import WebKit
import Darwin

struct NativeBrowserCallback: Decodable, Sendable {
    let port: UInt16
    let token: String
}

struct SdkBrowserRequest: Decodable, Sendable {
    let type: Int
    let url: String?
    let scene: String?
    let page_id: String?
    let app_id: String?
    let width: Double?
    let height: Double?
    let native_callback: NativeBrowserCallback?
}

enum CaptchaRelay {
    @concurrent static func deliver(callback: NativeBrowserCallback, page: String, result: String?) async -> Bool {
        guard callback.port > 0, callback.token.utf8.count == 64 else { return false }
        var object: [String: Any] = ["type": result == nil ? 204 : 200, "page_id": page]
        if let result { object["result"] = result }
        guard var payload = try? JSONSerialization.data(withJSONObject: object), payload.count <= 65536 else { return false }
        defer { payload.resetBytes(in: 0..<payload.count) }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = callback.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return false }
        var packet = Data(callback.token.utf8)
        var size = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(payload)
        defer { packet.resetBytes(in: 0..<packet.count) }
        let sent = packet.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard sent else { return false }
        var accepted: UInt32 = 0
        let received = withUnsafeMutableBytes(of: &accepted) { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.recv(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return received && UInt32(littleEndian: accepted) == 1
    }
}

@MainActor
final class CaptchaBrowser: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let request: SdkBrowserRequest
    let panel: LoginPanel
    let webView: WKWebView
    weak var owner: LoginPanel?
    var finished = false
    var delivering = false
    var pageReady = false
    var status: ((String) -> Void)?
    var closed: (() -> Void)?

    static func supports(_ request: SdkBrowserRequest) -> Bool {
        guard request.scene == "captcha", let raw = request.url, let url = URL(string: raw),
              url.scheme == "https", url.host == "plat-cdn.manjuu.com", request.page_id?.isEmpty == false, request.native_callback != nil else { return false }
        return ["/pc/sdk-webview/sha/g_captcha.html", "/pc/sdk-webview/sha/t_captcha.html"].contains(url.path)
    }

    static func bridgeScript(appID: String) -> String {
        let literal = String(data: (try? JSONEncoder().encode(appID)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        return """
        (() => {
            if (location.protocol !== 'https:' || location.hostname !== 'plat-cdn.manjuu.com') return;
            const appID = \(literal);
            window.MjSdkBridge = {invoke(method, message) {
                if (method === 'HandleCaptcha' && typeof message === 'string') window.webkit.messageHandlers.finewineCaptcha.postMessage(message);
            }};
            window.cefViewQuery = query => {
                if (query.request === 'qt200' && typeof query.onSuccess === 'function') query.onSuccess(appID);
            };
            window.addEventListener('load', () => {
                if (location.pathname === '/pc/sdk-webview/sha/t_captcha.html' && /(iPhone|iPad|iPod|iOS|Macintosh)/i.test(navigator.userAgent) && typeof window.callbackIOSAppId === 'function') {
                    window.callbackIOSAppId(new URLSearchParams(location.search).get('appid') || appID);
                }
            }, {once: true});
        })();
        """
    }

    init(request: SdkBrowserRequest, owner: LoginPanel) {
        self.request = request
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let url = URL(string: request.url!)!
        let appID = request.app_id ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "appid" })?.value ?? ""
        configuration.userContentController.addUserScript(WKUserScript(source: Self.bridgeScript(appID: appID), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        panel = LoginPanel(contentRect: CGRect(x: 0, y: 0, width: min(max(1, request.width ?? 430), owner.frame.width), height: min(max(1, request.height ?? 400), owner.frame.height)), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        self.owner = owner
        panel.title = "安全验证"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = webView
        panel.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.userContentController.add(self, name: "finewineCaptcha")
        configuration.userContentController.add(self, name: "captchaResult")
        follow(owner: owner)
        webView.load(URLRequest(url: url))
    }

    func follow(owner: LoginPanel) {
        guard !finished else { return }
        self.owner = owner
        let frame = CGRect(x: owner.frame.midX - panel.frame.width / 2, y: owner.frame.midY - panel.frame.height / 2, width: panel.frame.width, height: panel.frame.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if panel.level != owner.level { panel.level = owner.level }
        if owner.isVisible && pageReady {
            if panel.parent !== owner { owner.addChildWindow(panel, ordered: .above) }
            if !panel.isVisible { panel.orderFrontRegardless();panel.makeKey() }
        } else if panel.isVisible { panel.orderOut(nil) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !finished, !delivering, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https", message.frameInfo.securityOrigin.host == "plat-cdn.manjuu.com",
              let result = message.body as? String, !result.isEmpty, result.utf8.count <= 60000 else { return }
        complete(result: result)
    }

    func complete(result: String?) {
        guard !finished, !delivering, let callback = request.native_callback, let page = request.page_id else { return }
        delivering = true
        status?("returning-result")
        Task { [weak self] in
            let accepted = await CaptchaRelay.deliver(callback: callback, page: page, result: result)
            guard let self, !self.finished else { return }
            self.delivering = false
            self.status?(accepted ? "result-delivered" : "return-failed")
            if accepted || result == nil { self.dismiss() }
            else {
                let alert = NSAlert()
                alert.messageText = "验证结果未能传回游戏"
                alert.informativeText = "本次验证会话可能已过期。请关闭安全验证窗口，再从游戏中重新获取验证码。"
                alert.addButton(withTitle: "知道了")
                _ = await alert.beginSheetModal(for: self.panel)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { complete(result: nil);return false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        if let owner { follow(owner: owner) }
        status?("page-loaded")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { status?("page-load-failed") }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert();alert.messageText = "安全验证";alert.informativeText = message;alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: panel) { _ in completionHandler() }
    }

    func dismiss() {
        guard !finished else { return }
        finished = true
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "finewineCaptcha")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "captchaResult")
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.delegate = nil
        closed?()
    }
}
