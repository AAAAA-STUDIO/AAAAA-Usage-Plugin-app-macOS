import Foundation

@main
enum HUDDragGeometryTests {
    static func main() {
        testHorizontalDisplayCrossing()
        testVerticallyStackedDisplayCrossing()
        print("PASS: HUD drag follows the pointer across simulated displays without snapping")
    }

    private static func testHorizontalDisplayCrossing() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 700),
            CGRect(x: 1_000, y: 0, width: 1_000, height: 700)
        ]
        let mouseDownOffset = CGPoint(x: 200, y: 40)
        var pointer = CGPoint(x: 900, y: 320)

        for nextPointer in [
            CGPoint(x: 975, y: 340),
            CGPoint(x: 1_020, y: 360),
            CGPoint(x: 1_120, y: 390)
        ] {
            let windowOrigin = HUDDragGeometry.windowOrigin(
                at: nextPointer,
                mouseDownOffset: mouseDownOffset
            )
            precondition(nextPointer.x - windowOrigin.x == mouseDownOffset.x)
            precondition(nextPointer.y - windowOrigin.y == mouseDownOffset.y)
            pointer = nextPointer
        }

        let windowOrigin = HUDDragGeometry.windowOrigin(at: pointer, mouseDownOffset: mouseDownOffset)
        let hudFrame = CGRect(origin: windowOrigin, size: CGSize(width: 368, height: 79))
        precondition(hudFrame.minX < screens[1].minX && hudFrame.maxX > screens[1].minX)
        precondition(HUDDragGeometry.screenIndex(containing: pointer, frames: screens) == 1)
    }

    private static func testVerticallyStackedDisplayCrossing() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 700),
            CGRect(x: 0, y: 700, width: 1_000, height: 700)
        ]
        let mouseDownOffset = CGPoint(x: 180, y: 140)
        let nextPointer = CGPoint(x: 640, y: 760)
        let nextOrigin = HUDDragGeometry.windowOrigin(
            at: nextPointer,
            mouseDownOffset: mouseDownOffset
        )

        precondition(nextOrigin == CGPoint(x: 460, y: 620))
        precondition(HUDDragGeometry.screenIndex(containing: nextPointer, frames: screens) == 1)
    }
}
