import AppKit
import CoreText

struct SdkScene: Decodable, Equatable {
    let generation: UInt32
    let phase: UInt32
    let width: Double
    let height: Double
    let root: UInt32
    let nodes: [SdkNode]
    let toast: SdkToast?
    let clientArea: SdkClientArea?
}

struct SdkClientArea: Decodable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct SdkToast: Decodable, Equatable {
    let width: Double
    let height: Double
    let fontSize: Double
    let font: String
    let text: String
    let style: String
}

@MainActor
final class ToastView: NSView {
    var toast: SdkToast?
    var scale: CGFloat = 1
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let toast, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5 * scale, yRadius: 5 * scale).fill()
        let font = NSFont(name: toast.font, size: toast.fontSize * scale) ?? NSFont.systemFont(ofSize: toast.fontSize * scale)
        let text = NSAttributedString(string: toast.text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height);context.scaleBy(x: 1, y: -1);context.textMatrix = .identity
        context.textPosition = CGPoint(x: (bounds.width - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) / 2, y: bounds.height / 2 - ink.midY)
        CTLineDraw(line, context);context.restoreGState()
    }
}

struct SdkNode: Decodable, Equatable {
    let id: UInt32
    let parent: UInt32
    let kind: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let enabled: Bool
    let name: String
    let style: String
    let font: String
    let fontSize: Double
    let bold: Bool
    let text: String?
    let placeholder: String?
    let secure: Bool?
    let checked: Bool?
    let alignment: Int?
    let image: String?
    let type: String?
    let visual: Bool?
    let maxLength: Int?
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

func matches(_ pattern: String, _ string: String) -> [[String]] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
    let source = string as NSString
    return expression.matches(in: string, range: NSRange(location: 0, length: source.length)).map { match in
        (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
    }
}

func styleBlock(_ style: String, state: String? = nil) -> String {
    let blocks = matches("([^{}]+)\\{([^{}]*)\\}", style)
    if let state { return blocks.first { $0[1].contains(":" + state) }?[2] ?? styleBlock(style) }
    return blocks.first { !$0[1].contains(":") }?[2] ?? (blocks.isEmpty ? style : "")
}

func resolvedStyle(_ style: String, state: String?) -> String {
    let base = styleBlock(style)
    guard let state else { return base }
    return styleBlock(style, state: state) + ";" + base
}

func cssValue(_ name: String, _ style: String) -> String? {
    matches("(?:^|[;{])\\s*" + NSRegularExpression.escapedPattern(for: name) + "\\s*:\\s*([^;}]+)", style).first?[1].trimmingCharacters(in: .whitespacesAndNewlines)
}

func cssColor(_ value: String?, fallback: NSColor) -> NSColor {
    guard let value else { return fallback }
    if value == "transparent" { return .clear }
    if value.hasPrefix("#"), let rgb = UInt32(value.dropFirst(), radix: 16) {
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    return fallback
}

func number(_ value: String?, fallback: CGFloat = 0) -> CGFloat {
    guard let value, let result = matches("[-+]?[0-9]*\\.?[0-9]+", value).first?.first, let number = Double(result) else { return fallback }
    return number
}

@MainActor
func sdkFont(_ node: SdkNode, scale: CGFloat) -> NSFont {
    let size = max(1, node.fontSize * scale)
    var font = NSFont(name: node.font, size: size) ?? NSFont(name: "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size)
    if node.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    return font
}

@MainActor
final class SdkAssets {
    let directory: URL
    var cache: [String: NSImage] = [:]
    init(directory: URL) {
        self.directory = directory
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["ttf", "otf"].contains(file.pathExtension) { CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) }
    }
    func image(_ resource: String) -> NSImage? {
        var name = resource
        if name.hasPrefix(":/") {
            for character in ":/\\*?\"<>|" { name = name.replacingOccurrences(of: String(character), with: "_") }
        }
        let high = name.replacingOccurrences(of: "_1280.", with: "_3840.")
        let resolved = FileManager.default.fileExists(atPath: directory.appendingPathComponent(high).path) ? high : name
        if let image = cache[resolved] { return image }
        guard let image = NSImage(contentsOf: directory.appendingPathComponent(resolved)) else { return nil }
        cache[resolved] = image
        return image
    }
    func background(_ style: String) -> NSImage? {
        guard let path = matches("url\\([\"']?([^)'\"]+)", style).first?[1] else { return nil }
        return image(path)
    }
}

@MainActor
final class SdkButton: NSButton {
    var node: SdkNode!
    var assets: SdkAssets!
    var scale: CGFloat = 1
    var invoke: (() -> Void)?
    var hovering = false
    var tracking: NSTrackingArea?
    var backgroundResource: String?
    var textAlignment: NSTextAlignment = .center
    var titleLayoutRect: CGRect?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { nil }
    @objc func activate() { window?.makeFirstResponder(self); invoke?() }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let item = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(item); tracking = item
        if let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let node else { return }
        let activeState = !isEnabled ? "disabled" : (cell?.isHighlighted == true ? "pressed" : (node.checked == true ? "checked" : (hovering ? "hover" : nil)))
        let base = styleBlock(node.style), style = resolvedStyle(node.style, state: activeState)
        if let backgroundResource {
            let suffix = cell?.isHighlighted == true ? "_pressed" : (hovering ? "_hover" : "")
            let changed = backgroundResource.replacingOccurrences(of: "_1280.png", with: suffix + "_1280.png")
            (assets.image(changed) ?? assets.image(backgroundResource))?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        if let image = assets.background(style) ?? assets.background(base) {
            let placedLeft = (cssValue("background-position", base) ?? "").contains("left")
            let rect = placedLeft ? CGRect(x: 0, y: 0, width: min(bounds.width, node.height * scale), height: bounds.height) : bounds
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        let text = node.text ?? ""
        if !text.isEmpty {
            let padding = number(cssValue("padding-left", base)) * scale
            let font = sdkFont(node, scale: scale)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: cssColor(cssValue("color", style) ?? cssValue("color", base), fallback: .labelColor), .kern: (cssValue("letter-spacing", base)?.contains("em") == true ? number(cssValue("letter-spacing", base)) * font.pointSize : 0)]
            let label = NSAttributedString(string: text, attributes: attributes)
            let textBounds = titleLayoutRect ?? bounds
            let line = CTLineCreateWithAttributedString(label)
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let x = textBounds.minX + (textAlignment == .right ? textBounds.width - advance - number(cssValue("padding-right", base)) * scale : (padding > 0 ? padding : (textBounds.width - advance) / 2))
                context.textPosition = CGPoint(x: x, y: bounds.height - textBounds.midY - ink.midY)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
    }
}

@MainActor
final class PassiveImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class NativeScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NativeSdkScroll: NSScrollView {
    let document = NativeScrollDocument()
    var changed: ((Int32) -> Void)?
    var synchronizing = false
    var initializedPosition = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { nil }
    func synchronize(size: CGSize, offset: CGFloat) {
        if initializedPosition && document.frame.size == size { return }
        synchronizing = true
        let previousTotal = max(0, document.bounds.height - contentSize.height)
        let previousFraction = previousTotal > 0 ? contentView.bounds.minY / previousTotal : 0
        document.setFrameSize(size)
        let total = max(0, size.height - contentSize.height)
        contentView.scroll(to: CGPoint(x: 0, y: initializedPosition ? previousFraction * total : max(0, min(total, offset))))
        reflectScrolledClipView(contentView)
        initializedPosition = true
        synchronizing = false
    }
    @objc func scrolled() {
        guard !synchronizing else { return }
        let total = max(0, document.bounds.height - contentSize.height)
        changed?(Int32(total > 0 ? max(0, min(1, contentView.bounds.minY / total)) * 10000 : 0))
    }
}

@MainActor
final class SdkTextView: NSTextView {
    var draggable = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

@MainActor
func drawInputLine(_ text: NSAttributedString, frame: CGRect) {
    let storage = NSTextStorage(attributedString: text)
    let manager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 2
    container.maximumNumberOfLines = 1
    container.lineBreakMode = .byClipping
    storage.addLayoutManager(manager)
    manager.addTextContainer(container)
    manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: frame.origin)
}

@MainActor
func drawInputCell(_ cell: NSTextFieldCell, frame: CGRect, view: NSView) {
    guard !cell.stringValue.isEmpty, (view as? NSTextField)?.currentEditor() == nil else { return }
    drawInputLine(NSAttributedString(string: cell.stringValue, attributes: [.font: cell.font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: cell.textColor ?? NSColor.labelColor]), frame: frame)
}

@MainActor
final class InputCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) { drawInputCell(self, frame: cellFrame, view: controlView) }
}

@MainActor
final class SecureInputCell: NSSecureTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if !stringValue.isEmpty { super.drawInterior(withFrame: cellFrame, in: controlView) }
    }
}

@MainActor
final class SdkInput: NSView, NSTextFieldDelegate {
    var node: SdkNode!
    var assets: SdkAssets!
    var scale: CGFloat = 1
    let field: NSTextField
    let secure: Bool
    var changed: ((String) -> Void)?
    var focused = false
    var hovering = false
    var tracking: NSTrackingArea?
    var prompt = NSAttributedString(string: "")
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    init(secure: Bool) {
        self.secure = secure
        field = secure ? NSSecureTextField() : NSTextField()
        super.init(frame: .zero)
        field.cell = secure ? SecureInputCell(textCell: "") : InputCell(textCell: "")
        wantsLayer = true
        layer?.masksToBounds = true
        field.wantsLayer = true
        field.layer?.masksToBounds = true
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderAttributedString = nil
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        addSubview(field)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let item = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(item); tracking = item
        if let window { hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let style = resolvedStyle(node.style, state: focused || field.currentEditor() != nil ? "focus" : (hovering ? "hover" : nil))
        assets.background(style)?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if (field.currentEditor()?.string ?? field.stringValue).isEmpty { drawInputLine(prompt, frame: field.frame) }
    }
    func configure(_ node: SdkNode, scale: CGFloat, textEnd: CGFloat? = nil) {
        self.node = node; self.scale = scale
        let base = styleBlock(node.style)
        let left = number(cssValue("padding-left", base)) * scale
        let right = number(cssValue("padding-right", base)) * scale
        let sourceFont = sdkFont(node, scale: scale)
        let font = secure ? NSFont.systemFont(ofSize: sourceFont.pointSize) : sourceFont
        if field.font != font { field.font = font }
        field.textColor = cssColor(cssValue("color", base), fallback: .labelColor)
        field.isEnabled = node.enabled
        field.setAccessibilityLabel(node.placeholder ?? "")
        let placeholderStyle = styleBlock(node.style, state: ":placeholder")
        let placeholder = NSAttributedString(string: node.placeholder ?? "", attributes: [.font: font, .foregroundColor: cssColor(cssValue("color", placeholderStyle), fallback: .placeholderTextColor)])
        if !prompt.isEqual(to: placeholder) { prompt = placeholder }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 2 * scale
        let frame = CGRect(x: left, y: (bounds.height - height) / 2, width: max(1, (textEnd ?? (bounds.width - right)) - left), height: height)
        if field.frame != frame { field.frame = frame }
        needsDisplay = true
    }
    func normalized(_ original: String) -> String {
        let phone = node.placeholder == "请输入手机号"
        let value = phone ? String(original.filter { $0 >= "0" && $0 <= "9" }) : original
        var units = Array(value.utf16.prefix(max(0, min(node.maxLength ?? 16384, phone ? 11 : 16384))))
        if let last = units.last, (0xd800...0xdbff).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    func controlTextDidChange(_ obj: Notification) {
        let editor = field.currentEditor() as? NSTextView
        let original = editor?.string ?? field.stringValue
        let value = normalized(original)
        if value != original {
            let selection = editor?.selectedRange() ?? NSRange(location: value.utf16.count, length: 0)
            field.stringValue = value
            editor?.string = value
            editor?.setSelectedRange(NSRange(location: min(selection.location, value.utf16.count), length: 0))
        }
        needsDisplay = true
        changed?(value)
    }
    func controlTextDidBeginEditing(_ obj: Notification) { focused = true; needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { focused = false; needsDisplay = true }
}

func decodeEntities(_ text: String) -> String {
    var result = text
    for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] { result = result.replacingOccurrences(of: entity, with: value) }
    for match in matches("&#(x[0-9a-fA-F]+|[0-9]+);", result).reversed() {
        let raw = match[1]
        let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
        if let number, let scalar = UnicodeScalar(number) { result = result.replacingOccurrences(of: match[0], with: String(scalar)) }
    }
    return result
}

@MainActor
func nativeRichText(_ html: String, node: SdkNode, scale: CGFloat) -> NSAttributedString {
    let stripped = html.replacingOccurrences(of: "(?is)<head[^>]*>.*?</head>|<style[^>]*>.*?</style>|<script[^>]*>.*?</script>", with: "", options: .regularExpression)
    let result = NSMutableAttributedString(string: "")
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    if node.alignment.map({ $0 & 4 != 0 }) == true { paragraph.alignment = .center }
    let baseline: [NSAttributedString.Key: Any] = [.font: sdkFont(node, scale: scale), .foregroundColor: cssColor(cssValue("color", styleBlock(node.style)), fallback: .labelColor), .paragraphStyle: paragraph]
    var attributes = baseline
    var stack: [[NSAttributedString.Key: Any]] = []
    for token in matches("<[^>]*>|[^<]+", stripped).compactMap(\.first) {
        if token.hasPrefix("<") {
            let lower = token.lowercased()
            let tag = matches("^</?\\s*([a-zA-Z0-9]+)", token).first?[1].lowercased() ?? ""
            if tag == "br" { result.append(NSAttributedString(string: "\n", attributes: attributes)); continue }
            if lower.hasPrefix("</") {
                if ["p", "div", "li", "h1", "h2", "h3", "tr"].contains(tag), result.length > 0, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
                if let previous = stack.popLast() { attributes = previous }
            } else if !["html", "body", "meta", "img", "hr"].contains(tag) {
                stack.append(attributes)
                if tag == "a", let href = matches("href\\s*=\\s*[\"']([^\"']+)", token).first?[1] {
                    attributes[.link] = decodeEntities(href)
                    attributes[.foregroundColor] = NSColor(srgbRed: 239 / 255, green: 144 / 255, blue: 61 / 255, alpha: 1)
                    attributes[.underlineStyle] = 0
                }
                if ["b", "strong", "h1", "h2", "h3"].contains(tag), let font = attributes[.font] as? NSFont { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if let style = matches("style\\s*=\\s*[\"']([^\"']+)", token).first?[1] {
                    if let value = cssValue("color", style) { attributes[.foregroundColor] = cssColor(value, fallback: .labelColor) }
                    if let size = cssValue("font-size", style), let current = attributes[.font] as? NSFont {
                        attributes[.font] = NSFont(name: current.fontName, size: number(size) * scale) ?? current
                    }
                    if let height = cssValue("line-height", style), height.contains("px") {
                        let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                        paragraph.minimumLineHeight = number(height) * scale
                        paragraph.maximumLineHeight = number(height) * scale
                        attributes[.paragraphStyle] = paragraph
                    }
                }
                if tag == "font", let color = matches("color\\s*=\\s*[\"']([^\"']+)", token).first?[1] { attributes[.foregroundColor] = cssColor(color, fallback: .labelColor) }
            }
        } else {
            let text = decodeEntities(token).replacingOccurrences(of: "[\t\r\n]+", with: " ", options: .regularExpression)
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
    }
    while result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
    return result
}

@MainActor
final class SdkText: NSScrollView, NSTextViewDelegate {
    let text = SdkTextView()
    var node: SdkNode!
    var invoked: ((UInt32, Int32, String) -> Void)?
    var contentKey = ""
    var suppressPointer = false
    var singleLine = false
    var singleLineText: NSAttributedString?
    override func hitTest(_ point: NSPoint) -> NSView? { suppressPointer ? nil : super.hitTest(point) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.delegate = self
        text.linkTextAttributes = [.foregroundColor: NSColor(srgbRed: 239 / 255, green: 144 / 255, blue: 61 / 255, alpha: 1), .underlineStyle: 0]
        documentView = text
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard singleLine, let value = singleLineText, let context = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(value)
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let alignment = node.alignment ?? 1
        let x = alignment & 4 != 0 ? (bounds.width - advance) / 2 : (alignment & 2 != 0 ? bounds.width - advance : 0)
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height);context.scaleBy(x: 1, y: -1);context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: bounds.height / 2 - ink.midY)
        CTLineDraw(line, context);context.restoreGState()
    }
    func configure(_ node: SdkNode, scale: CGFloat) {
        self.node = node
        text.draggable = false
        hasVerticalScroller = node.kind == "document"
        let key = "\(node.text ?? "")|\(scale)|\(bounds.size)|\(node.alignment ?? 0)|\(node.fontSize)|\(singleLine)"
        if key != contentKey {
            contentKey = key
            let rendered = NSMutableAttributedString(attributedString: nativeRichText(node.text ?? "", node: node, scale: scale))
            if singleLine, rendered.length > 0 {
                let range = NSRange(location: 0, length: rendered.length)
                let paragraph = (rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byClipping
                rendered.addAttribute(.paragraphStyle, value: paragraph, range: range)
                let advance = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(rendered), nil, nil, nil))
                if advance > contentSize.width, contentSize.width > 0 {
                    let ratio = contentSize.width / advance
                    rendered.enumerateAttribute(.font, in: range) { value, fontRange, _ in
                        if let font = value as? NSFont { rendered.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * ratio), range: fontRange) }
                    }
                }
            }
            text.textContainer?.maximumNumberOfLines = singleLine ? 1 : 0
            text.textContainer?.lineBreakMode = singleLine ? .byClipping : .byWordWrapping
            text.textStorage?.setAttributedString(rendered)
            text.isHidden = singleLine
            singleLineText = singleLine ? rendered : nil
            needsDisplay = true
            text.textContainerInset = .zero
            if let container = text.textContainer, let manager = text.layoutManager {
                container.containerSize = CGSize(width: max(1, contentSize.width), height: .greatestFiniteMagnitude)
                manager.ensureLayout(for: container)
                let height = ceil(manager.usedRect(for: container).height)
                let alignment = node.alignment ?? 0
                let padding = node.kind == "label" ? max(0, contentSize.height - height) * (alignment & 128 != 0 ? 0.5 : (alignment & 64 != 0 ? 1 : 0)) : 0
                text.textContainerInset = CGSize(width: 0, height: padding)
                text.setFrameSize(CGSize(width: max(1, contentSize.width), height: max(contentSize.height, height + padding * 2)))
            }
        }
    }
    @objc func scrolled() {
        guard node?.kind == "document" else { return }
        let total = text.bounds.height - contentView.bounds.height
        let fraction = total > 0 ? max(0, min(1, contentView.bounds.minY / total)) : 1
        invoked?(4, Int32(fraction * 10000), "")
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        invoked?(3, 0, (link as? String) ?? (link as? URL)?.absoluteString ?? "")
        return true
    }
}

@MainActor
final class NativeSceneView: NSView {
    var scene: SdkScene?
    var card = CGRect(x: 0, y: 0, width: 430, height: 400)
    var assets: SdkAssets!
    var views: [UInt32: NSView] = [:]
    var send: ((UInt32, UInt32, Int32, String) -> Void)?
    let toastView = ToastView(frame: .zero)
    private var background: NSImage?
    var rootType: String? { scene?.nodes.first(where: { $0.id == scene?.root })?.type }
    var isWelcomeBanner: Bool { rootType == "mj_official_cn::LoginSucceedWnd" }
    var isLoadingOverlay: Bool { ["mj_base::LoadingWnd", "mj_base::WebViewLoadingWidget", "mj_base::MjCaptchaWnd"].contains(rootType ?? "") }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var scale: CGFloat { min(1, bounds.width / card.width, bounds.height / card.height) }
    var origin: CGPoint { CGPoint(x: (bounds.width - card.width * scale) / 2, y: isWelcomeBanner ? min(60 * scale, max(0, bounds.height - card.height * scale)) : (bounds.height - card.height * scale) / 2) }
    func clear() {
        for view in views.values {
            if let input = view as? SdkInput { input.field.stringValue = "" }
            view.removeFromSuperview()
        }
        views.removeAll()
        scene = nil
        toastView.removeFromSuperview();toastView.toast = nil
        background = nil
        needsDisplay = true
    }
    func scrollAncestor(_ node: SdkNode, in nodes: [UInt32: SdkNode]) -> SdkNode? {
        var parent = node.parent
        var visited = Set<UInt32>()
        while let candidate = nodes[parent], visited.insert(parent).inserted {
            if candidate.type == "mj_base::CustomScrollArea" { return candidate }
            parent = candidate.parent
        }
        return nil
    }
    func apply(_ next: SdkScene) -> Bool {
        if scene == next { return false }
        let fresh = scene?.generation != next.generation || scene?.root != next.root
        if fresh { clear() }
        scene = next
        if isLoadingOverlay {
            for view in views.values { view.removeFromSuperview() }
            views.removeAll();background = nil
            card = CGRect(x: 0, y: 0, width: next.width, height: next.height)
            needsDisplay = true
            return fresh
        }
        let candidates = next.nodes.filter { $0.width >= 200 && $0.height >= 140 && $0.width < next.width * 0.95 }
        if isWelcomeBanner, let banner = next.nodes.first(where: { $0.parent == next.root && $0.kind == "label" && $0.image != nil }) { card = banner.rect }
        else if let container = next.nodes.first(where: { $0.type == "mj_base::CenterWidget" && $0.parent == next.root }) { card = container.rect }
        else if next.width <= 800 && next.height <= 800 { card = CGRect(x: 0, y: 0, width: next.width, height: next.height) }
        else if let candidate = candidates.max(by: { left, right in
            let lc = candidates.filter { $0.rect == left.rect }.count
            let rc = candidates.filter { $0.rect == right.rect }.count
            return lc == rc ? left.width * left.height < right.width * right.height : lc < rc
        }) { card = candidate.rect }
        else { card = CGRect(x: 0, y: 0, width: next.width, height: next.height) }
        let backgrounds: [(CGSize, String)] = [(CGSize(width: 430, height: 400), ":/base/img/main_bg_1280.png"), (CGSize(width: 580, height: 374), ":/base/img/agreement_page_bg_1280.png"), (CGSize(width: 388, height: 180), ":/base/img/confirm_popup_bg_1280.png"), (CGSize(width: 430, height: 262), ":/base/img/history_login_bg_1280.png"), (CGSize(width: 460, height: 260), ":/base/img/notification_popup_bg_1280.png")]
        background = backgrounds.first { abs($0.0.width - card.width) < 2 && abs($0.0.height - card.height) < 2 }.flatMap { assets.image($0.1) }
        let currentIDs = Set(next.nodes.map(\.id))
        let nodesByID = Dictionary(uniqueKeysWithValues: next.nodes.map { ($0.id, $0) })
        for (id, view) in views where !currentIDs.contains(id) { view.removeFromSuperview(); views.removeValue(forKey: id) }
        for node in next.nodes where node.rect.intersects(card) || scrollAncestor(node, in: nodesByID) != nil {
            let existing = views[node.id]
            let view: NSView
            switch node.kind {
            case "input":
                let prior = existing as? SdkInput
                let input = prior?.secure == (node.secure == true) ? prior! : SdkInput(secure: node.secure == true)
                if input !== prior { input.field.stringValue = prior?.field.stringValue ?? "" }
                input.assets = assets
                input.changed = { [weak self] text in self?.send?(node.id, 2, 0, text) }
                view = input
            case "button", "check":
                let button = existing as? SdkButton ?? SdkButton(frame: .zero)
                button.node = node; button.assets = assets
                button.isEnabled = node.enabled
                button.title = node.text ?? ""
                button.setAccessibilityLabel(node.text?.isEmpty == false ? node.text : (node.style.contains("close_btn") ? "关闭" : (node.kind == "check" ? "选项" : nil)))
                if existing == nil { button.setButtonType(node.kind == "check" ? .switch : .momentaryPushIn) }
                if button.state != (node.checked == true ? NSControl.StateValue.on : .off) { button.state = node.checked == true ? .on : .off }
                button.invoke = { [weak self] in self?.send?(node.id, 1, 0, "") }
                view = button
            case "label", "document":
                if let filename = node.image, let image = assets.image(filename) {
                    let imageView = existing as? PassiveImage ?? PassiveImage()
                    imageView.image = image
                    imageView.imageScaling = .scaleAxesIndependently
                    view = imageView
                } else {
                    let label = existing as? SdkText ?? SdkText(frame: .zero)
                    label.invoked = { [weak self] action, value, text in self?.send?(node.id, action, value, text) }
                    view = label
                }
            default:
                if node.type == "mj_base::CustomScrollArea" {
                    let scroll = existing as? NativeSdkScroll ?? NativeSdkScroll(frame: .zero)
                    scroll.changed = { [weak self] value in self?.send?(node.id, 4, value, "") }
                    view = scroll
                } else if node.type == "mj_official_cn::UserCenterBtn" || node.type == "mj_official_cn::LicenseAgreementBtn" {
                    let button = existing as? SdkButton ?? SdkButton(frame: .zero)
                    button.node = node;button.assets = assets;button.isEnabled = node.enabled
                    button.backgroundResource = node.type == "mj_official_cn::UserCenterBtn" ? ":/base/img/user_center_btn_bg_1280.png" : nil
                    button.setAccessibilityLabel(next.nodes.first(where: { $0.parent == node.id && $0.kind == "label" })?.text)
                    button.invoke = { [weak self] in self?.send?(node.id, 6, 0, "") }
                    view = button
                } else if node.visual == true {
                    let imageView = existing as? PassiveImage ?? PassiveImage()
                    imageView.imageScaling = .scaleAxesIndependently
                    view = imageView
                } else if let image = assets.background(styleBlock(node.style)) {
                    let imageView = existing as? PassiveImage ?? PassiveImage()
                    imageView.image = image
                    imageView.imageScaling = .scaleAxesIndependently
                    view = imageView
                } else { continue }
            }
            if view !== existing { existing?.removeFromSuperview(); addSubview(view); views[node.id] = view }
        }
        layoutScene()
        return fresh
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutScene() }
    func layoutScene() {
        guard let scene else { return }
        let nodesByID = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0) })
        var geometry = Dictionary(uniqueKeysWithValues: scene.nodes.map { ($0.id, $0.rect) })
        var scrollContent: [UInt32: SdkNode] = [:]
        for scroll in scene.nodes where scroll.type == "mj_base::CustomScrollArea" {
            if let viewport = scene.nodes.first(where: { $0.parent == scroll.id && $0.type == "QWidget" }), let content = scene.nodes.first(where: { $0.parent == viewport.id && $0.type == "QWidget" }) { scrollContent[scroll.id] = content }
        }
        func inputAncestor(_ node: SdkNode) -> SdkNode? {
            var parent = node.parent
            var seen = Set<UInt32>()
            while let candidate = nodesByID[parent], seen.insert(parent).inserted {
                if candidate.kind == "input" { return candidate }
                parent = candidate.parent
            }
            return nil
        }
        let codeButtons = scene.nodes.filter { $0.kind == "button" && $0.text?.isEmpty == false && inputAncestor($0)?.placeholder == "请输入短信验证码" }
        let codeButtonIDs = Set(codeButtons.map(\.id))
        for code in codeButtons {
            guard let input = inputAncestor(code) else { continue }
            let base = styleBlock(code.style)
            let font = sdkFont(code, scale: 1)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: (cssValue("letter-spacing", base)?.contains("em") == true ? number(cssValue("letter-spacing", base)) * font.pointSize : 0)]
            let width = ["获取验证码", code.text ?? ""].map { title in
                CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes)), nil, nil, nil))
            }.max() ?? code.width
            let actionWidth = min(code.width, ceil(width) + number(cssValue("padding-left", base)) + number(cssValue("padding-right", base)))
            let offset = code.width - actionWidth
            geometry[code.id] = CGRect(x: code.rect.maxX - actionWidth, y: code.y, width: actionWidth, height: code.height)
            for node in scene.nodes where inputAncestor(node)?.id == input.id && (node.style.contains("url(:/base/img/phone_edit_del_btn_") || node.style.contains("url(:/base/img/code_edit_divider_line_")) {
                geometry[node.id] = node.rect.offsetBy(dx: offset, dy: 0)
            }
        }
        for node in scene.nodes {
            guard let view = views[node.id] else { continue }
            let rect: CGRect
            if node.kind == "button", node.text?.isEmpty == false, let parent = scene.nodes.first(where: { $0.id == node.parent }), parent.style == "QWidget {border: none;}", parent.height > node.height, parent.width > node.width {
                rect = parent.rect
                if let button = view as? SdkButton {
                    let resources: [(CGSize, String, String)] = [(CGSize(width: 372, height: 44), ":/base/img/long_btn_1280.png", ":/base/img/long_btn_1280.png"), (CGSize(width: 160, height: 40), ":/base/img/little_little_light_btn_1280.png", ":/base/img/little_little_dark_btn_1280.png"), (CGSize(width: 176, height: 40), ":/base/img/little_middle_light_btn_1280.png", ":/base/img/little_middle_dark_btn_1280.png"), (CGSize(width: 196, height: 40), ":/base/img/little_big_light_btn_1280.png", ":/base/img/little_big_dark_btn_1280.png")]
                    let bright = cssValue("color", styleBlock(node.style)) == "#5E2D17"
                    button.backgroundResource = resources.first { $0.0 == parent.rect.size }.map { bright ? $0.2 : $0.1 }
                }
            }
            else { rect = geometry[node.id] ?? node.rect }
            if let scroll = scrollAncestor(node, in: nodesByID), let parent = views[scroll.id] as? NativeSdkScroll, let content = scrollContent[scroll.id] {
                if view.superview !== parent.document { parent.document.addSubview(view) }
                view.frame = CGRect(x: (rect.minX - content.x) * scale, y: (rect.minY - content.y) * scale, width: rect.width * scale, height: rect.height * scale)
            } else {
                if view.superview !== self { addSubview(view) }
                view.frame = CGRect(x: origin.x + (rect.minX - card.minX) * scale, y: origin.y + (rect.minY - card.minY) * scale, width: rect.width * scale, height: rect.height * scale)
            }
            if let input = view as? SdkInput {
                var end = node.rect.maxX - 16
                if let code = codeButtons.first(where: { inputAncestor($0)?.id == node.id }), let button = geometry[code.id] { end = min(end, button.minX - 42) }
                if node.secure == true || node.placeholder?.contains("密码") == true { end = min(end, node.rect.maxX - 76) }
                for child in scene.nodes where child.kind == "button" && inputAncestor(child)?.id == node.id {
                    if let childRect = geometry[child.id] { end = min(end, childRect.minX - 6) }
                }
                input.configure(node, scale: scale, textEnd: (end - node.x) * scale)
            }
            if let button = view as? SdkButton {
                button.titleLayoutRect = isWelcomeBanner ? CGRect(x: (node.x - rect.minX) * scale, y: (node.y - rect.minY) * scale, width: node.width * scale, height: node.height * scale) : nil
                button.textAlignment = codeButtonIDs.contains(node.id) ? .right : .center;button.scale = scale;button.needsDisplay = true
            }
            if let label = view as? SdkText {
                label.suppressPointer = ["mj_official_cn::UserCenterBtn", "mj_official_cn::LicenseAgreementBtn"].contains(nodesByID[node.parent]?.type ?? "")
                label.singleLine = isWelcomeBanner || nodesByID[node.parent]?.type == "mj_official_cn::UserCenterPage" || label.suppressPointer
                label.configure(node, scale: scale)
            }
        }
        for (id, content) in scrollContent {
            if let scroll = views[id] as? NativeSdkScroll, let node = nodesByID[id] {
                scroll.synchronize(size: CGSize(width: content.width * scale, height: content.height * scale), offset: (node.y - content.y) * scale)
            }
        }
        let children = Dictionary(grouping: scene.nodes, by: \.parent)
        var visited = Set<UInt32>()
        var ordered: [NSView] = []
        func append(_ node: SdkNode) {
            guard visited.insert(node.id).inserted else { return }
            if let view = views[node.id] { ordered.append(view) }
            for child in (children[node.id] ?? []).sorted(by: { left, right in
                func rank(_ node: SdkNode) -> Int { node.kind == "view" || node.image != nil ? 0 : node.kind == "input" ? 1 : node.kind == "label" || node.kind == "document" ? 2 : 3 }
                let a = rank(left), b = rank(right)
                return a == b ? left.id < right.id : a < b
            }) { append(child) }
        }
        if let root = nodesByID[scene.root] { append(root) }
        for node in scene.nodes where !visited.contains(node.id) { append(node) }
        if let toast = scene.toast {
            toastView.toast = toast;toastView.scale = scale
            toastView.frame = CGRect(x: origin.x + (card.width - toast.width) * scale / 2, y: origin.y + (card.height - toast.height) * scale / 2, width: toast.width * scale, height: toast.height * scale)
            if toastView.superview !== self { addSubview(toastView) }
            ordered.append(toastView);toastView.needsDisplay = true
        } else { toastView.removeFromSuperview();toastView.toast = nil }
        let topLevel = ordered.filter { $0.superview === self }
        if subviews.map(ObjectIdentifier.init) != topLevel.map(ObjectIdentifier.init) { subviews = topLevel }
        for view in views.values {
            if let scroll = view as? NativeSdkScroll {
                let children = ordered.filter { $0.superview === scroll.document }
                if scroll.document.subviews.map(ObjectIdentifier.init) != children.map(ObjectIdentifier.init) { scroll.document.subviews = children }
            }
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        if !isWelcomeBanner && !isLoadingOverlay {
            NSColor.black.withAlphaComponent(0.02).setFill()
            NSBezierPath(rect: dirtyRect).fill()
        }
        let rect = CGRect(origin: origin, size: CGSize(width: card.width * scale, height: card.height * scale))
        if let background { background.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]) }
        if let scene {
            for node in scene.nodes where node.kind == "button" && node.text == "进入游戏" {
                if let parent = scene.nodes.first(where: { $0.id == node.parent }), parent.width == 372, parent.height == 44 {
                    let target = CGRect(x: origin.x + (parent.x - card.minX) * scale, y: origin.y + (parent.y - card.minY) * scale, width: parent.width * scale, height: parent.height * scale)
                    assets.image(":/base/img/long_btn_1280.png")?.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                }
            }
        }
    }
    func requestClose() {
        if let close = scene?.nodes.first(where: { $0.kind == "button" && $0.style.contains("/close_btn_") }) { send?(close.id, 1, 0, "") }
    }
    func refreshInteraction() {
        guard let window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        for view in views.values {
            let hovering = view.bounds.contains(view.convert(point, from: nil))
            if let input = view as? SdkInput {
                let focused = input.field.currentEditor() != nil
                if input.focused != focused || input.hovering != hovering {
                    input.focused = focused; input.hovering = hovering; input.needsDisplay = true
                }
            }
            if let button = view as? SdkButton, button.hovering != hovering {
                button.hovering = hovering; button.needsDisplay = true
            }
        }
    }
    func syncValue(id: UInt32, value: String) {
        guard let input = views[id] as? SdkInput, input.field.currentEditor() == nil else { return }
        let normalized = input.normalized(value)
        if input.field.stringValue != normalized { input.field.stringValue = normalized }
        if normalized != value { input.changed?(normalized) }
        input.needsDisplay = true
    }
    func syncVisual(id: UInt32, image: CGImage) {
        (views[id] as? NSImageView)?.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }
    override func mouseDown(with event: NSEvent) {}
}
