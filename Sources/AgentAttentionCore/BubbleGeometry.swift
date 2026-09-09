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

    /// How far the window extends past the disc on every side, leaving room for the roam halo
    /// ring to be drawn without being clipped.
    ///
    /// The bubble's window is exactly the size of its content, and content painted outside that
    /// rectangle is clipped — `BubbleController.applyAppearance` already had to move the disc's
    /// drop shadow from the view's layer to the window for exactly this reason, because a shadow
    /// clipped to a circle's own bounds renders as a square with a hole in it. A halo ring drawn
    /// outside the 56pt disc needs the same accommodation: a window `haloInset` points larger on
    /// every side than the disc it contains.
    ///
    /// That margin is constant, not conditional on whether roam is currently on: resizing the
    /// window only while roaming would mean a window resize and a placement recomputation on
    /// every toggle, and the bubble visibly jumping. Keeping it constant costs 8pt of permanently
    /// transparent window (4pt on each side) in exchange for a roam toggle that never touches the
    /// window's size or position.
    public static let haloInset: CGFloat = 4

    /// Resolve a remembered placement into a frame, clamped so the whole returned rect — the disc
    /// *and* its halo margin — is entirely on screen.
    ///
    /// - Parameters:
    ///   - size: The window's size — the disc plus its halo margin on every side.
    ///   - haloInset: How much of `size` on each edge is halo margin rather than disc. The stored
    ///     `placement` offset always measures to the disc's edge, not the window's, so the disc
    ///     is positioned first (at `size` shrunk by `haloInset` on every side) and the window rect
    ///     is then grown back out around it — the disc, not the window, is what the user placed.
    ///     Defaults to 0, not `BubbleGeometry.haloInset`: a caller that has not started passing the
    ///     larger, halo-aware `size` must keep getting the window it always got, not one silently
    ///     shifted by the margin. `haloInset: 0` and an unchanged `size` reproduce today's frame
    ///     exactly; a caller ready for the halo passes both the bigger `size` and the margin.
    public static func frame(for placement: BubblePlacement, size: CGSize, in visibleFrame: CGRect,
                              haloInset: CGFloat = 0) -> CGRect {
        let discSize = CGSize(width: size.width - haloInset * 2, height: size.height - haloInset * 2)
        let width = min(discSize.width, visibleFrame.width)
        let height = min(discSize.height, visibleFrame.height)
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
        // Clamped into the visible area *shrunk by the margin*, not into the visible area itself.
        // The returned rect is the disc grown back out by `haloInset` on every side, so clamping
        // the disc flush against the screen edge would push that grown rect `haloInset` points off
        // it — and `BubbleController` drags with `clamp(window)`, which keeps the whole window on
        // screen, so a dragged bubble and a restored one would not agree about where the edge is.
        // At `haloInset: 0` this inset is the identity and the frame is exactly what it always was.
        let bounds = visibleFrame.insetBy(dx: haloInset, dy: haloInset)
        let discFrame = clamp(CGRect(origin: origin, size: CGSize(width: width, height: height)), in: bounds)
        return discFrame.insetBy(dx: -haloInset, dy: -haloInset)
    }

    /// Turn a dragged position back into something worth remembering.
    ///
    /// The nearest corner wins, so a bubble dropped near the bottom-right stays bottom-right when
    /// the window is later resized or the display changes.
    ///
    /// - Parameters:
    ///   - frame: The dragged window's frame — the disc plus its halo margin.
    ///   - haloInset: The same margin `frame(for:size:in:haloInset:)` was given. Reading the
    ///     offset from the window rect instead of the disc rect would make the bubble creep
    ///     `haloInset` points further from its corner on every drag, since each round trip through
    ///     `frame(for:)` would re-add the margin this function failed to remove. Defaults to 0 for
    ///     the same reason as `frame(for:size:in:haloInset:)`: a caller still passing window frames
    ///     sized without a halo must get exactly today's placement back, not one nudged by a margin
    ///     its frames never had.
    public static func placement(for frame: CGRect, in visibleFrame: CGRect,
                                  haloInset: CGFloat = 0) -> BubblePlacement {
        let frame = frame.insetBy(dx: haloInset, dy: haloInset)
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
    ///
    /// - Parameters:
    ///   - bubbleFrame: The bubble's window frame — the disc plus its halo margin.
    ///   - haloInset: The same margin `frame(for:size:in:haloInset:)` was given. The panel hugs
    ///     the disc's edge, not the window's, so `bubbleFrame` is trimmed back to the disc before
    ///     any of the arithmetic below runs. Defaults to 0 for the same reason as the other two
    ///     functions: a caller passing a halo-less `bubbleFrame` must get exactly today's panel
    ///     placement, not one pulled in by a margin that frame never had.
    public static func panelFrame(
        panelSize: CGSize,
        bubbleFrame: CGRect,
        in visibleFrame: CGRect,
        gap: CGFloat = 10,
        haloInset: CGFloat = 0
    ) -> CGRect {
        let bubbleFrame = bubbleFrame.insetBy(dx: haloInset, dy: haloInset)
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
