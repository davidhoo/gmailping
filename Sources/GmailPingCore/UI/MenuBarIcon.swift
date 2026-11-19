import AppKit

public struct MenuBarIcon {
    public static func makeEnvelopeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let insetRect = rect.insetBy(dx: 1.5, dy: 3.0)
            let path = NSBezierPath(roundedRect: insetRect, xRadius: 2.0, yRadius: 2.0)
            path.lineWidth = 1.3
            NSColor.black.setStroke()
            path.stroke()

            // Draw envelope flap lines
            let flapPath = NSBezierPath()
            flapPath.lineWidth = 1.2
            flapPath.move(to: NSPoint(x: insetRect.minX, y: insetRect.maxY))
            flapPath.line(to: NSPoint(x: insetRect.midX, y: insetRect.midY + 0.5))
            flapPath.line(to: NSPoint(x: insetRect.maxX, y: insetRect.maxY))
            flapPath.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}
