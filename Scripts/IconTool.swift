import AppKit

enum IconToolFailure: Error { case invalidArguments, invalidImage, encodingFailed, iconUpdateFailed }

@main struct IconTool {
    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw IconToolFailure.invalidArguments }
        if arguments[1] == "--generate" {
            guard let source = NSImage(contentsOfFile: arguments[2]) else { throw IconToolFailure.invalidImage }
            let folder = URL(fileURLWithPath: arguments[3])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let suffix = scale == 2 ? "@2x" : ""
                    try render(source, pixels: size * scale).write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
                }
            }
        } else if arguments[1] == "--set" {
            guard let image = NSImage(contentsOfFile: arguments[2]), NSWorkspace.shared.setIcon(image, forFile: arguments[3], options: []) else { throw IconToolFailure.iconUpdateFailed }
        } else if arguments[1] == "--preview" {
            try render(NSWorkspace.shared.icon(forFile: arguments[2]), pixels: 512).write(to: URL(fileURLWithPath: arguments[3]))
        } else { throw IconToolFailure.invalidArguments }
    }

    @MainActor static func render(_ image: NSImage, pixels: Int) throws -> Data {
        guard image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconToolFailure.invalidImage }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let side = CGFloat(pixels)
        context.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = min(side / image.size.width, side / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconToolFailure.encodingFailed }
        return data
    }
}
