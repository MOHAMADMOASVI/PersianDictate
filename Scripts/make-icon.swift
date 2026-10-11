// Draws the app icon and writes Resources/AppIcon.icns.  Usage: swift Scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let unit = size / 1024
    context.scaleBy(x: unit, y: unit)

    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill()
    plate.fill()
    context.restoreGState()

    context.saveGState()
    plate.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.62, blue: 0.60, alpha: 1),
                        NSColor(srgbRed: 0.20, green: 0.27, blue: 0.78, alpha: 1)])!
        .draw(in: NSRect(x: 100, y: 100, width: 824, height: 824), angle: 65)
    context.restoreGState()

    // Microphone.
    let configuration = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let height: CGFloat = 430
        let width = height * symbol.size.width / symbol.size.height
        tinted.draw(in: NSRect(x: 512 - width / 2, y: 410, width: width, height: height))
    }

    // A line of text being typed, right to left: two words and the cursor.
    func pill(_ x: CGFloat, _ width: CGFloat, alpha: CGFloat) {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 262, width: width, height: 56), xRadius: 28, yRadius: 28).fill()
    }
    pill(539, 190, alpha: 0.95)
    pill(353, 150, alpha: 0.7)
    NSColor(srgbRed: 1.0, green: 0.80, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 295, y: 240, width: 22, height: 100), xRadius: 11, yRadius: 11).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let png = draw(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
try draw(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print("Wrote \(icns.path)")
