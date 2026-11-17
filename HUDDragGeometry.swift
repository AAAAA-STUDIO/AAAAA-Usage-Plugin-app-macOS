import CoreGraphics

enum HUDDragGeometry {
    static func windowOrigin(at pointer: CGPoint, mouseDownOffset: CGPoint) -> CGPoint {
        CGPoint(
            x: pointer.x - mouseDownOffset.x,
            y: pointer.y - mouseDownOffset.y
        )
    }

    static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex(where: { $0.contains(point) })
    }
}
