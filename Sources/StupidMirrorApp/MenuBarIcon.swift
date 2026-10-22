import AppKit

/// The app icon's paired mirror surfaces, simplified for an 18-point menu bar slot.
/// Drawing as a template keeps the silhouette sharp at either display scale and
/// lets macOS choose its color for the menu bar background and selection state.
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            for reflected in [false, true] {
                surface(reflected: reflected).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "StupidMirror"
        return image
    }()

    private nonisolated static func surface(reflected: Bool) -> NSBezierPath {
        // A wider separation than the full-color artwork preserves the S-shaped
        // negative space at 1x. The second surface is a half-turn of the first.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let x = reflected ? 100 - x : x
            let y = reflected ? 100 - y : y
            return NSPoint(x: 1 + x * 0.16, y: 1 + y * 0.16)
        }

        let path = NSBezierPath()
        path.move(to: point(15, 5))
        path.curve(to: point(46, 24), controlPoint1: point(25, 0), controlPoint2: point(41, 12))
        path.curve(to: point(40, 44), controlPoint1: point(52, 32), controlPoint2: point(45, 38))
        path.curve(to: point(35, 68), controlPoint1: point(31, 53), controlPoint2: point(31, 59))
        path.curve(to: point(45, 86), controlPoint1: point(37, 76), controlPoint2: point(48, 81))
        path.curve(to: point(16, 94), controlPoint1: point(40, 97), controlPoint2: point(24, 101))
        path.curve(to: point(5, 61), controlPoint1: point(7, 88), controlPoint2: point(5, 75))
        path.curve(to: point(7, 23), controlPoint1: point(3, 47), controlPoint2: point(4, 30))
        path.curve(to: point(15, 5), controlPoint1: point(8, 14), controlPoint2: point(10, 8))
        path.close()
        return path
    }
}
