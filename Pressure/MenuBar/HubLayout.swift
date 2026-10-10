import Foundation

/// Geometry for the side island. Coordinates use AppKit screen space
/// (origin at the bottom left). The compact pill sits on the left edge,
/// centered vertically, and the expanded card grows from that same center.
struct HubBox: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func contains(x: Double, y: Double) -> Bool {
        x >= self.x && x < self.x + width && y >= self.y && y < self.y + height
    }

    func insetBy(dx: Double, dy: Double) -> HubBox {
        HubBox(x: x - dx, y: y - dy, width: width + dx * 2, height: height + dy * 2)
    }
}

enum HubLayout {
    static let collapsedWidth = 86.0
    static let collapsedHeight = 168.0
    static let expandedWidth = 368.0
    static let expandedHeight = 820.0
    static let collapsedCornerRadius = 43.0
    static let expandedCornerRadius = 44.0
    static let contentMargin = 14.0
    static let edgeTuck = 0.0

    static var innerCornerRadius: Double { expandedCornerRadius - contentMargin }

    static func panel(
        expanded: Bool,
        visibleMinX: Double,
        visibleMidY: Double,
        visibleHeight: Double = 2000
    ) -> HubBox {
        let width = expanded ? expandedWidth : collapsedWidth
        let natural = expanded ? expandedHeight : collapsedHeight
        let height = min(natural, max(collapsedHeight, visibleHeight - 24))
        let tuck = expanded ? 0.0 : edgeTuck
        return HubBox(
            x: visibleMinX - tuck,
            y: visibleMidY - height / 2,
            width: width,
            height: height
        )
    }

    static func hotZone(screenMinX: Double, visibleMinX: Double, visibleMidY: Double) -> HubBox {
        let width = max(collapsedWidth, visibleMinX - screenMinX + collapsedWidth)
        return HubBox(
            x: screenMinX,
            y: visibleMidY - 110,
            width: width,
            height: 220
        )
    }
}
