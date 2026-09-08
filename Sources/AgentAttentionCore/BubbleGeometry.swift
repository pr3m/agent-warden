import Foundation
import CoreGraphics

/// Which corner a floating element is anchored to.
public enum ScreenCorner: String, Codable, Sendable, CaseIterable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    public var label: String {
        switch self {
        case .bottomRight: return "Bottom right"
        case .bottomLeft: return "Bottom left"
        case .topRight: return "Top right"
        case .topLeft: return "Top left"
        }
    }
}

/// Where the bubble sits, remembered as a corner plus an inward offset rather than an absolute
/// point.
///
/// A corner survives what an absolute point does not: a different display, a resolution change, a
/// menu bar appearing or disappearing. "24 points in from the bottom right" still means the same
/// thing on a 6K monitor and on a laptop panel.
public struct BubblePlacement: Codable, Sendable, Equatable {
    public var corner: ScreenCorner
    /// Inward from the corner, in points. Always positive.
    public var offsetX: Double
    public var offsetY: Double

    public init(corner: ScreenCorner = .bottomRight, offsetX: Double = 20, offsetY: Double = 20) {
        self.corner = corner
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// Bottom right, lifted clear of the very corner.
    ///
    /// Other assistants' floating controls tend to live in the bottom-right corner too. We cannot
    /// see them — that would need window-list access we are not asking for — so the default simply
    /// leaves room above the corner, and the bubble is draggable and configurable for the cases
    /// where the guess is wrong.
    public static let `default` = BubblePlacement(corner: .bottomRight, offsetX: 24, offsetY: 120)
}

/// Pure geometry for the floating bubble and the panel that expands from it.
///
/// Deliberately free of AppKit so placement, clamping and persistence can be tested without a
/// screen — which is most of what can go wrong here.
public enum BubbleGeometry {

    /// Resolve a remembered placement into a frame, clamped so the bubble is entirely on screen.
    public static func frame(for placement: BubblePlacement, size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let offsetX = max(0, placement.offsetX)
        let offsetY = max(0, placement.offsetY)

        var origin: CGPoint
        switch placement.corner {
        case .bottomLeft:
            origin = CGPoint(x: visibleFrame.minX + offsetX, y: visibleFrame.minY + offsetY)
        case .bottomRight:
            origin = CGPoint(x: visibleFrame.maxX - offsetX - width, y: visibleFrame.minY + offsetY)
        case .topLeft:
            origin = CGPoint(x: visibleFrame.minX + offsetX, y: visibleFrame.maxY - offsetY - height)
        case .topRight:
            origin = CGPoint(x: visibleFrame.maxX - offsetX - width, y: visibleFrame.maxY - offsetY - height)
        }
        return clamp(CGRect(origin: origin, size: CGSize(width: width, height: height)), in: visibleFrame)
    }

    /// Turn a dragged position back into something worth remembering.
    ///
    /// The nearest corner wins, so a bubble dropped near the bottom-right stays bottom-right when
    /// the window is later resized or the display changes.
    public static func placement(for frame: CGRect, in visibleFrame: CGRect) -> BubblePlacement {
        let clamped = clamp(frame, in: visibleFrame)
        let distanceToLeft = clamped.minX - visibleFrame.minX
        let distanceToRight = visibleFrame.maxX - clamped.maxX
        let distanceToBottom = clamped.minY - visibleFrame.minY
        let distanceToTop = visibleFrame.maxY - clamped.maxY

        let corner: ScreenCorner
        switch (distanceToLeft <= distanceToRight, distanceToBottom <= distanceToTop) {
        case (true, true): corner = .bottomLeft
        case (false, true): corner = .bottomRight
        case (true, false): corner = .topLeft
        case (false, false): corner = .topRight
        }

        return BubblePlacement(
            corner: corner,
            offsetX: max(0, corner == .bottomLeft || corner == .topLeft ? distanceToLeft : distanceToRight),
            offsetY: max(0, corner == .bottomLeft || corner == .bottomRight ? distanceToBottom : distanceToTop)
        )
    }

    /// Where the expanded panel goes, relative to the bubble.
    ///
    /// It opens on whichever side has more room, hugs the bubble's nearest horizontal edge so the
    /// two read as one control, and is then clamped into the screen.
    public static func panelFrame(
        panelSize: CGSize,
        bubbleFrame: CGRect,
        in visibleFrame: CGRect,
        gap: CGFloat = 10
    ) -> CGRect {
        let width = min(panelSize.width, visibleFrame.width)
        let height = min(panelSize.height, visibleFrame.height)

        let roomAbove = visibleFrame.maxY - bubbleFrame.maxY
        let roomBelow = bubbleFrame.minY - visibleFrame.minY
        let y: CGFloat = roomBelow >= height + gap || roomBelow >= roomAbove
            ? bubbleFrame.minY - gap - height   // open downwards from the bubble's bottom edge
            : bubbleFrame.maxY + gap            // otherwise upwards

        // Align the panel's near edge with the bubble's, so it grows away from the screen edge.
        let hugsRightEdge = (visibleFrame.maxX - bubbleFrame.maxX) <= (bubbleFrame.minX - visibleFrame.minX)
        let x = hugsRightEdge ? bubbleFrame.maxX - width : bubbleFrame.minX

        return clamp(CGRect(x: x, y: y, width: width, height: height), in: visibleFrame)
    }

    /// Push a frame back inside the visible area. Never returns something partly off screen.
    public static func clamp(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Nudge the bubble one step, for keyboard and menu-driven placement.
    public static func nudged(_ placement: BubblePlacement, dx: Double, dy: Double) -> BubblePlacement {
        var moved = placement
        moved.offsetX = max(0, placement.offsetX + dx)
        moved.offsetY = max(0, placement.offsetY + dy)
        return moved
    }
}
