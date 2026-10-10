import Foundation

/// Geometry for the side island. Coordinates use AppKit screen space
/// (origin at the bottom left). The compact pill sits on the left edge,
/// centered vertically, and grows only for the rows that are actually live.
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
    static let collapsedWidth = 52.0
    static let expandedWidth = 304.0
    static let expandedHeight = 380.0
    static let collapsedCornerRadius = 18.0
    static let expandedCornerRadius = 26.0
    static let contentMargin = 12.0
    static let edgeTuck = 0.0
    static let collapsedPadV = 8.0
    static let collapsedPadH = 4.0
    static let batteryRow = 18.0
    static let mediaRow = 26.0
    static let timeRow = 14.0
    static let cursorRow = 16.0
    static let rowGap = 5.0

    static var innerCornerRadius: Double { expandedCornerRadius - contentMargin }

    static func collapsedHeight(
        nowPlaying: Bool,
        timer: Bool,
        stopwatch: Bool,
        cursor: Bool = false,
        messages: Bool = false,
        actions: Bool = false
    ) -> Double {
        var height = collapsedPadV * 2 + batteryRow
        if messages { height += rowGap + cursorRow }
        if actions { height += rowGap + cursorRow }
        if cursor { height += rowGap + cursorRow }
        if nowPlaying { height += rowGap + mediaRow }
        if timer { height += rowGap + timeRow }
        if stopwatch { height += rowGap + timeRow }
        return height
    }

    static func panel(
        expanded: Bool,
        visibleMinX: Double,
        visibleMidY: Double,
        visibleHeight: Double = 2000,
        nowPlaying: Bool = false,
        timer: Bool = false,
        stopwatch: Bool = false,
        cursor: Bool = false,
        messages: Bool = false,
        actions: Bool = false
    ) -> HubBox {
        let width = expanded ? expandedWidth : collapsedWidth
        let natural = expanded
            ? expandedHeight
            : collapsedHeight(
                nowPlaying: nowPlaying,
                timer: timer,
                stopwatch: stopwatch,
                cursor: cursor,
                messages: messages,
                actions: actions
            )
        let height = min(natural, max(36, visibleHeight - 24))
        let tuck = expanded ? 0.0 : edgeTuck
        return HubBox(
            x: visibleMinX - tuck,
            y: visibleMidY - height / 2,
            width: width,
            height: height
        )
    }

    static func hotZone(screenMinX: Double, visibleMinX: Double, visibleMidY: Double) -> HubBox {
        let width = max(collapsedWidth + 12, visibleMinX - screenMinX + collapsedWidth + 12)
        return HubBox(
            x: screenMinX,
            y: visibleMidY - 70,
            width: width,
            height: 140
        )
    }
}
