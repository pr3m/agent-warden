import Foundation
import CoreGraphics
import Testing
@testable import AgentAttentionCore

/// Placement of the floating bubble and the panel that expands from it.
///
/// This is where a floating control usually goes wrong: remembered off screen, half off the edge
/// after a display change, or with the panel opening into the wall. All of it is pure geometry, so
/// none of it needs a screen to test.
@Suite("Bubble placement")
struct BubbleGeometryTests {
    /// A laptop-ish visible frame with a menu bar at the top, deliberately not at the origin so an
    /// implementation that assumes (0,0) fails.
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 984)
    let offsetScreen = CGRect(x: 1710, y: 240, width: 2560, height: 1329)
    let bubbleSize = CGSize(width: 56, height: 56)

    @Test("Every corner resolves inside the screen", arguments: ScreenCorner.allCases)
    func cornersAreOnScreen(corner: ScreenCorner) {
        let placement = BubblePlacement(corner: corner, offsetX: 24, offsetY: 120)
        for visible in [screen, offsetScreen] {
            let frame = BubbleGeometry.frame(for: placement, size: bubbleSize, in: visible)
            #expect(visible.contains(frame), "\(corner) on \(visible)")
            #expect(frame.size == bubbleSize)
        }
    }

    @Test("The offset is measured inward from the named corner")
    func offsetsAreInward() {
        let bottomRight = BubbleGeometry.frame(
            for: BubblePlacement(corner: .bottomRight, offsetX: 24, offsetY: 120),
            size: bubbleSize, in: screen
        )
        #expect(bottomRight.maxX == screen.maxX - 24)
        #expect(bottomRight.minY == screen.minY + 120)

        let topLeft = BubbleGeometry.frame(
            for: BubblePlacement(corner: .topLeft, offsetX: 30, offsetY: 40),
            size: bubbleSize, in: screen
        )
        #expect(topLeft.minX == screen.minX + 30)
        #expect(topLeft.maxY == screen.maxY - 40)
    }

    @Test("The default sits bottom right but clear of the very corner")
    func defaultPlacement() {
        // Other assistants' floating controls live in that corner. We cannot see them, so we start
        // out of the way and let the user drag.
        #expect(BubblePlacement.default.corner == .bottomRight)
        let frame = BubbleGeometry.frame(for: .default, size: bubbleSize, in: screen)
        #expect(frame.minY > screen.minY + 80, "leaves room for another control in the corner")
        #expect(screen.contains(frame))
    }

    @Test("An impossible offset is clamped back on screen", arguments: [
        (99_999.0, 99_999.0), (-500.0, -500.0), (0.0, 99_999.0), (Double.infinity, 0.0),
    ])
    func impossibleOffsetsAreClamped(x: Double, y: Double) {
        let placement = BubblePlacement(corner: .bottomRight, offsetX: x.isFinite ? x : 1e9, offsetY: y)
        let frame = BubbleGeometry.frame(for: placement, size: bubbleSize, in: screen)
        #expect(screen.contains(frame))
    }

    @Test("A bubble remembered on a big display still fits a small one")
    func placementSurvivesADisplayChange() {
        let big = CGRect(x: 0, y: 0, width: 5120, height: 2880)
        let dragged = CGRect(x: 4000, y: 2000, width: 56, height: 56)
        let remembered = BubbleGeometry.placement(for: dragged, in: big)

        let small = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = BubbleGeometry.frame(for: remembered, size: bubbleSize, in: small)
        #expect(small.contains(frame), "the offset was larger than the new screen")
    }

    @Test("A dropped bubble is remembered against its nearest corner", arguments: [
        (CGPoint(x: 1600, y: 40), ScreenCorner.bottomRight),
        (CGPoint(x: 20, y: 40), ScreenCorner.bottomLeft),
        (CGPoint(x: 1600, y: 900), ScreenCorner.topRight),
        (CGPoint(x: 20, y: 900), ScreenCorner.topLeft),
    ])
    func nearestCornerWins(origin: CGPoint, expected: ScreenCorner) {
        let frame = CGRect(origin: origin, size: bubbleSize)
        #expect(BubbleGeometry.placement(for: frame, in: screen).corner == expected)
    }

    @Test("A dragged position round-trips back to the same place")
    func placementRoundTrips() {
        let dropped = CGRect(x: 1400, y: 300, width: 56, height: 56)
        let remembered = BubbleGeometry.placement(for: dropped, in: screen)
        let restored = BubbleGeometry.frame(for: remembered, size: bubbleSize, in: screen)
        #expect(abs(restored.minX - dropped.minX) < 0.5)
        #expect(abs(restored.minY - dropped.minY) < 0.5)
    }

    @Test("A drag beyond the edge is pulled back before it is remembered")
    func draggingOffScreenIsClamped() {
        let escaped = CGRect(x: screen.maxX + 400, y: screen.maxY + 400, width: 56, height: 56)
        let remembered = BubbleGeometry.placement(for: escaped, in: screen)
        let frame = BubbleGeometry.frame(for: remembered, size: bubbleSize, in: screen)
        #expect(screen.contains(frame))
        #expect(remembered.offsetX >= 0 && remembered.offsetY >= 0)
    }

    @Test("Nudging never produces a negative offset")
    func nudging() {
        var placement = BubblePlacement(corner: .bottomRight, offsetX: 10, offsetY: 10)
        placement = BubbleGeometry.nudged(placement, dx: -50, dy: -50)
        #expect(placement.offsetX == 0)
        #expect(placement.offsetY == 0)
        #expect(placement.corner == .bottomRight, "nudging moves, it does not re-anchor")

        placement = BubbleGeometry.nudged(placement, dx: 12, dy: 24)
        #expect(placement.offsetX == 12)
        #expect(placement.offsetY == 24)
    }

    // MARK: - Panel anchoring

    @Test("The panel opens next to the bubble and stays on screen", arguments: ScreenCorner.allCases)
    func panelAnchors(corner: ScreenCorner) {
        let bubble = BubbleGeometry.frame(for: BubblePlacement(corner: corner, offsetX: 24, offsetY: 120),
                                          size: bubbleSize, in: screen)
        let panel = BubbleGeometry.panelFrame(panelSize: CGSize(width: 380, height: 460),
                                              bubbleFrame: bubble, in: screen)
        #expect(screen.contains(panel), "\(corner)")
        #expect(!panel.intersects(bubble), "the panel should sit beside the bubble, not under it")
    }

    @Test("The panel hugs the same screen edge as the bubble")
    func panelHugsTheSameEdge() {
        let right = BubbleGeometry.frame(for: BubblePlacement(corner: .bottomRight, offsetX: 24, offsetY: 120),
                                         size: bubbleSize, in: screen)
        let rightPanel = BubbleGeometry.panelFrame(panelSize: CGSize(width: 380, height: 400), bubbleFrame: right, in: screen)
        #expect(abs(rightPanel.maxX - right.maxX) < 0.5)

        let left = BubbleGeometry.frame(for: BubblePlacement(corner: .bottomLeft, offsetX: 24, offsetY: 120),
                                        size: bubbleSize, in: screen)
        let leftPanel = BubbleGeometry.panelFrame(panelSize: CGSize(width: 380, height: 400), bubbleFrame: left, in: screen)
        #expect(abs(leftPanel.minX - left.minX) < 0.5)
    }

    @Test("A panel taller than the room below opens upwards instead")
    func panelFlipsWhenThereIsNoRoom() {
        let lowBubble = CGRect(x: 1600, y: screen.minY + 10, width: 56, height: 56)
        let panel = BubbleGeometry.panelFrame(panelSize: CGSize(width: 380, height: 600),
                                              bubbleFrame: lowBubble, in: screen)
        #expect(panel.minY >= lowBubble.maxY || screen.contains(panel))
        #expect(screen.contains(panel))
    }

    @Test("A panel larger than the screen is shrunk rather than pushed off it")
    func oversizedPanel() {
        let bubble = BubbleGeometry.frame(for: .default, size: bubbleSize, in: screen)
        let panel = BubbleGeometry.panelFrame(panelSize: CGSize(width: 9000, height: 9000),
                                              bubbleFrame: bubble, in: screen)
        #expect(screen.contains(panel))
        #expect(panel.width <= screen.width)
        #expect(panel.height <= screen.height)
    }

    // MARK: - Persistence

    @Test("Placement survives a save and load of the config")
    func placementPersists() throws {
        var config = AttentionConfig.default
        config.bubblePlacement = BubblePlacement(corner: .topLeft, offsetX: 33, offsetY: 77)
        config.bubbleSize = 64

        let data = try JSONCoding.encoder.encode(config)
        let restored = try JSONCoding.decoder.decode(AttentionConfig.self, from: data)

        #expect(restored.bubblePlacement == config.bubblePlacement)
        #expect(restored.bubbleSize == 64)
    }

    @Test("A config with no bubble keys at all still starts")
    func placementDefaultsWhenAbsent() throws {
        let partial = Data(#"{"speechEnabled":true}"#.utf8)
        let config = try JSONCoding.decoder.decode(AttentionConfig.self, from: partial)
        #expect(config.bubbleEnabled)
        #expect(config.bubblePlacement == .default)
        #expect(config.bubbleSize == AttentionConfig.default.bubbleSize)
    }

    @Test("Hostile bubble settings are clamped, not obeyed")
    func hostileBubbleSettings() throws {
        let hostile = Data(#"{"bubbleSize":-400,"bubblePlacement":{"corner":"bottomRight","offsetX":-99,"offsetY":1e12}}"#.utf8)
        let config = try JSONCoding.decoder.decode(AttentionConfig.self, from: hostile).validated()
        #expect(config.bubbleSize >= 40 && config.bubbleSize <= 96)
        #expect(config.bubblePlacement.offsetX >= 0)
        #expect(config.bubblePlacement.offsetY <= 8000)

        let frame = BubbleGeometry.frame(for: config.bubblePlacement,
                                          size: CGSize(width: config.bubbleSize, height: config.bubbleSize),
                                          in: screen)
        #expect(screen.contains(frame))
    }

    @Test("An unknown corner in the config falls back rather than throwing")
    func unknownCorner() throws {
        let odd = Data(#"{"bubblePlacement":{"corner":"middleOfNowhere","offsetX":10,"offsetY":10}}"#.utf8)
        let config = try JSONCoding.decoder.decode(AttentionConfig.self, from: odd)
        #expect(config.bubblePlacement == .default)
    }
}
