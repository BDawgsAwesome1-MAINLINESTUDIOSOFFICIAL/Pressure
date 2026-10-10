import Foundation

/// Geometry for the side Hub. Coordinates use the AppKit screen space
/// (origin at the bottom left). The compact pill is a vertical Dynamic Island:
/// tucked into the left edge, centered vertically, and the expanded card grows
/// from that same center.
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
    static let collapsedWidth = 54.0
    static let collapsedHeight = 156.0
    static let expandedWidth = 348.0
    static let expandedHeight = 520.0
    static let collapsedCornerRadius = 27.0
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
        let height = min(expanded ? expandedHeight : collapsedHeight, max(collapsedHeight, visibleHeight - 24))
        let tuck = expanded ? 0.0 : edgeTuck
        return HubBox(
            x: visibleMinX - tuck,
            y: visibleMidY - height / 2,
            width: width,
            height: height
        )
    }

    /// Left-middle trigger. Includes the screen edge itself, so the pointer
    /// can arrive from the bezel, and the visible part of the tucked pill.
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
