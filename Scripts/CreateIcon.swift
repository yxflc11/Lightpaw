// xcrun swiftc Sources/BrandMark.swift Scripts/CreateIcon.swift -o /private/tmp/lightpaw-icon
// /private/tmp/lightpaw-icon Resources/MacCare.icns /private/tmp/lightpaw-icon-preview.png
import AppKit
import Foundation

@main struct CreateIcon {
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        var chunks = Data()
        for (size, kind) in [(16,"icp4"),(32,"icp5"),(64,"icp6"),(128,"ic07"),(256,"ic08"),(512,"ic09"),(1024,"ic10")] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            BrandIcon.drawAppIcon(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            let png = bitmap.representation(using: .png, properties: [:])!
            chunks.append(Data(kind.utf8))
            var length = UInt32(png.count + 8).bigEndian
            chunks.append(Data(bytes: &length, count: 4)); chunks.append(png)
            if size == 512, CommandLine.arguments.count > 2 { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
        }
        var result = Data("icns".utf8), length = UInt32(chunks.count + 8).bigEndian
        result.append(Data(bytes: &length, count: 4)); result.append(chunks)
        try result.write(to: destination)
    }
}
