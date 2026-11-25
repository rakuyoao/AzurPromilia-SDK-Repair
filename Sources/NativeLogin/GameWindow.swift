import AppKit

struct GameSession: Decodable {
    let pid: pid_t
}

struct GameWindowState {
    let pid: pid_t
    let number: Int
    let frame: CGRect
    let level: Int
    let visible: Bool
    let panelAbove: Bool
}

@MainActor
func gameWindowState(sessionURL: URL, panelNumber: Int) -> GameWindowState? {
    guard let data = try? Data(contentsOf: sessionURL), let session = try? JSONDecoder().decode(GameSession.self, from: data), kill(session.pid, 0) == 0,
          let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == session.pid }
    let panelIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == panelNumber && ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
    let candidates = owned.compactMap { info -> GameWindowState? in
        guard let number = info[kCGWindowNumber as String] as? Int, let bounds = info[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 128, rect.height > 128 else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let ownerIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == number }
        let above = panelIndex.flatMap { panel in ownerIndex.map { panel < $0 } } ?? false
        return GameWindowState(pid: session.pid, number: number, frame: CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height), level: (info[kCGWindowLayer as String] as? Int) ?? 0, visible: (info[kCGWindowIsOnscreen as String] as? Bool) == true && ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0, panelAbove: above)
    }
    return candidates.max { left, right in
        let a = left.frame.width * left.frame.height, b = right.frame.width * right.frame.height
        return a < b
    }
}
