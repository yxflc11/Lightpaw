import AppKit

// Approved F glyph cat; one geometry for the icon, menu, views and animation.
enum BrandIcon {
    enum Pose: Int, CaseIterable { case rest, blink, tailUp, tailDown }
    enum Detail { case full, compact }
    static let lavender = NSColor(srgbRed: 204/255, green: 184/255, blue: 224/255, alpha: 1)

    static func image(size: CGFloat = 18) -> NSImage {
        let detail: Detail = size <= 32 ? .compact : .full
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let target = size == 18 ? rect.insetBy(dx: 1, dy: 1) : rect
            draw(in: target, color: .black, detail: detail)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lightpaw 字形猫"
        return image
    }

    static func mascotImage(pose: Pose) -> NSImage {
        let image = NSImage(size: NSSize(width: 160, height: 112), flipped: false) { rect in
            draw(in: rect, color: .black, pose: pose)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lightpaw 字形猫"
        return image
    }

    // AppKit is bottom-up; the approved SVG master is top-down.
    static func draw(in rect: NSRect, color: NSColor, detail: Detail = .full, pose: Pose = .rest) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let width: CGFloat = detail == .full ? 160 : 16
        let height: CGFloat = detail == .full ? 112 : 16
        let scale = min(rect.width / width, rect.height / height)
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX - width * scale / 2, yBy: rect.midY + height * scale / 2)
        transform.scaleX(by: scale, yBy: -scale)
        transform.concat()
        color.setStroke(); color.setFill()
        if detail == .full { fullPaths[pose.rawValue].stroke() }
        else { compactOutline.stroke(); compactEyes.fill() }
    }

    static func drawAppIcon(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / 128)
        transform.concat()
        NSColor(srgbRed: 41/255, green: 41/255, blue: 41/255, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 7.5, y: 7.5, width: 113, height: 113), xRadius: 25, yRadius: 25).fill()
        if rect.width <= 32 {
            draw(in: NSRect(x: 26, y: 26, width: 76, height: 76), color: lavender, detail: .compact)
        } else {
            // F preview: SVG translate(16,31) scale(.60) in a 128-square icon.
            draw(in: NSRect(x: 16, y: 29.8, width: 96, height: 67.2), color: lavender)
        }
    }

    private static func path(_ width: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = width; p.lineCapStyle = .square; p.lineJoinStyle = .miter
        return p
    }
    private static func line(_ p: NSBezierPath, _ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        p.move(to: NSPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { p.line(to: NSPoint(x: point.0, y: point.1)) }
    }
    private static let fullPaths = Pose.allCases.map { pose -> NSBezierPath in
        let p = path(3.3)
        for points: [(CGFloat, CGFloat)] in [
            [(54,25),(62,7)], [(66,7),(73,24)], [(77,26),(87,26)],
            [(90,24),(98,7)], [(103,7),(111,25)],
            [(18,48),(32,48)], [(36,46),(44,30)], [(113,32),(121,49)],
            [(12,56),(5,72)], [(17,75),(31,75)], [(36,75),(50,75)],
            [(123,57),(116,74)], [(6,83),(13,100)],
            [(20,102),(35,102)], [(40,102),(54,102)], [(77,103),(88,103)],
            [(79,65),(86,65)], [(79,70),(86,70)], [(92,68),(96,62),(100,68)],
            [(106,65),(113,65)], [(106,70),(113,70)]
        ] { line(p, points) }
        // Only the left curl moves; the face, paws and image bounds stay fixed.
        switch pose {
        case .tailUp:
            p.move(to: NSPoint(x: 59, y: 80))
            p.curve(to: NSPoint(x: 61, y: 98), controlPoint1: NSPoint(x: 80, y: 77), controlPoint2: NSPoint(x: 79, y: 96))
        case .tailDown:
            p.move(to: NSPoint(x: 59, y: 84))
            p.curve(to: NSPoint(x: 55, y: 105), controlPoint1: NSPoint(x: 69, y: 93), controlPoint2: NSPoint(x: 68, y: 105))
        default:
            p.move(to: NSPoint(x: 59, y: 82))
            p.curve(to: NSPoint(x: 60, y: 102), controlPoint1: NSPoint(x: 73, y: 86), controlPoint2: NSPoint(x: 73, y: 97))
        }
        p.move(to: NSPoint(x: 121, y: 82))
        p.curve(to: NSPoint(x: 120, y: 103), controlPoint1: NSPoint(x: 132, y: 89), controlPoint2: NSPoint(x: 130, y: 98))
        p.move(to: NSPoint(x: 93, y: 103)); p.line(to: NSPoint(x: 93, y: 90))
        p.curve(to: NSPoint(x: 102, y: 91), controlPoint1: NSPoint(x: 93, y: 85), controlPoint2: NSPoint(x: 102, y: 85))
        p.line(to: NSPoint(x: 102, y: 103))
        p.move(to: NSPoint(x: 103, y: 91))
        p.curve(to: NSPoint(x: 113, y: 91), controlPoint1: NSPoint(x: 103, y: 85), controlPoint2: NSPoint(x: 113, y: 85))
        p.line(to: NSPoint(x: 113, y: 103))
        if pose == .blink {
            line(p, [(68,46),(76,46)]); line(p, [(93,46),(101,46)])
        } else {
            p.appendOval(in: NSRect(x: 68.4, y: 39, width: 7.2, height: 10))
            p.appendOval(in: NSRect(x: 93.4, y: 39, width: 7.2, height: 10))
        }
        return p
    }
    private static let compactOutline: NSBezierPath = {
        let p = path(1.15)
        for points: [(CGFloat, CGFloat)] in [
            [(7,6),(8,2),(10,5)], [(11,5),(13,2),(14,6)], [(3,7),(6,7)],
            [(2,8),(1,10)], [(2,12),(3,14),(7,14)], [(9,14),(13,14),(14,12)],
            [(15,8),(14,10)], [(3,10),(6,10),(7,12)]
        ] { line(p, points) }
        return p
    }()
    private static let compactEyes: NSBezierPath = {
        let p = NSBezierPath(rect: NSRect(x: 8, y: 7, width: 1.4, height: 1.4))
        p.appendRect(NSRect(x: 12, y: 7, width: 1.4, height: 1.4))
        return p
    }()
}
