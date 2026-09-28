import AppKit
import Testing
@testable import Herdrbar

/// Writes PNG previews of the menu bar glyph states. Opt in with HERDRBAR_PREVIEW_DIR=<folder>.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDRBAR_PREVIEW_DIR"] != nil))
struct GlyphPreviewTests {
    @MainActor @Test func writesPreviews() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERDRBAR_PREVIEW_DIR"]!)
        let pdf = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/Herdrbar/Resources/MenuBarIcon.pdf").standardizedFileURL
        let ram = try #require(NSImage(contentsOf: pdf))
        for (name, attention, down) in [("plain", false, false), ("blocked", true, false), ("down", false, true)] {
            let glyph = try #require(MenuBarGlyph.image(attention: attention, down: down, ram: ram))
            for (appearance, background, tint) in [("light", NSColor(white: 0.93, alpha: 1), NSColor.black),
                                                   ("dark", NSColor(white: 0.16, alpha: 1), NSColor.white)] {
                let scale = 8.0  // 4x a Retina menu bar, for inspection
                let size = NSSize(width: (glyph.size.width + 24) * scale, height: 22 * scale)
                let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                background.setFill()
                NSRect(origin: .zero, size: size).fill()
                // A template image is drawn by its alpha, tinted like the menu bar does.
                let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                    glyph.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: NSRect(x: 4 * scale, y: 3 * scale, width: glyph.size.width * scale, height: glyph.size.height * scale))
                let count = NSAttributedString(string: attention ? "2" : "", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13 * scale, weight: .regular), .foregroundColor: tint])
                count.draw(at: NSPoint(x: (glyph.size.width + 7) * scale, y: 3.5 * scale))
                NSGraphicsContext.restoreGraphicsState()
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "glyph-\(name)-\(appearance).png"))
            }
        }
    }
}
