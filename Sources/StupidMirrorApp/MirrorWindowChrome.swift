import CoreGraphics

enum MirrorWindowChrome {
    static let height: CGFloat = 44
    static let cornerHitSize: CGFloat = 56
    // Keep resizing confined to the outer frame. The rest of the title bar is
    // intentionally reserved for window dragging and chrome controls.
    static let resizeEdgeHitThickness: CGFloat = 6
}
