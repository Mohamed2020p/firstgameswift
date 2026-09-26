import Foundation
import simd

// MARK: - WGrid: arithmetic description of the street grid, valid for ANY integer grid line (the world is unbounded: the layout of
// one 16 x 16 block period repeats).  Used by pedestrian navigation, traffic routing, waypoints and the endless-world tiler.
// Grid line k runs through x = k * pitch (streets along Z) and z = k * pitch (streets along X); both share one road class.

enum WGrid {
    static let pitch: Float = WC.pitch
    /// number of grid lines after which the world repeats (one endless-world tile = lines -11 ... 10 = 3080 m)
    static let period: Int = WC.tileLines
    static let periodMeters: Float = Float(period) * WC.pitch

    /// maps any grid index into -11 ..< 11
    static func wrapIndex(_ k: Int) -> Int {
        let half: Int = period / 2
        var m: Int = (k + half) % period
        if m < 0 { m += period }
        return m - half
    }

    /// wraps a world coordinate into the base tile (-1120 ..< 1120)
    static func wrapCoordinate(_ v: Float) -> Float {
        let half: Float = periodMeters * 0.5
        var m: Float = (v + half).truncatingRemainder(dividingBy: periodMeters)
        if m < 0 { m += periodMeters }
        return m - half
    }

    static func roadClass(_ k: Int) -> WRoadClass {
        return WCityLayout.gridClass(wrapIndex(k))
    }

    static func line(_ k: Int) -> Float { return Float(k) * pitch }

    static func halfWidth(_ k: Int) -> Float { return WRoad.dimensions(roadClass(k)).half }
    static func sidewalkWidth(_ k: Int) -> Float { return WRoad.dimensions(roadClass(k)).sidewalk }
    static func medianHalf(_ k: Int) -> Float { return WRoad.dimensions(roadClass(k)).median }

    /// distance from the centre line to the middle of a driving lane (right-hand traffic)
    static func laneOffset(_ k: Int) -> Float {
        let d = WRoad.dimensions(roadClass(k))
        return (d.median + d.half) * 0.5
    }

    /// distance from the centre line to the middle of the sidewalk
    static func walkOffset(_ k: Int) -> Float {
        let d = WRoad.dimensions(roadClass(k))
        return d.half + d.sidewalk * 0.5
    }

    /// distance from the centre line to the outer edge of the sidewalk
    static func corridor(_ k: Int) -> Float {
        let d = WRoad.dimensions(roadClass(k))
        return d.half + d.sidewalk
    }

    static func nearestLine(_ v: Float) -> Int { return Int((v / pitch).rounded()) }
    static func blockIndex(_ v: Float) -> Int { return Int(floorf(v / pitch)) }

    /// kind of the city block that contains `p` (any position; the base tile repeats)
    static func blockKind(_ layout: WCityLayout, at p: Vec2) -> WBlockKind {
        let i: Int = wrapIndex(blockIndex(p.x))
        let j: Int = wrapIndex(blockIndex(p.y))
        if let b = layout.blockAt(i: i, j: j) { return b.kind }
        // the green belt between two city islands (no buildings): quiet, like an industrial edge
        return WBlockKind.industrial
    }

    /// true when the block containing `p` is part of a city island (not the green belt)
    static func isCityBlock(_ layout: WCityLayout, at p: Vec2) -> Bool {
        let i: Int = wrapIndex(blockIndex(p.x))
        let j: Int = wrapIndex(blockIndex(p.y))
        return layout.blockAt(i: i, j: j) != nil
    }

    /// wraps a world position into the base tile (-1540 ..< 1540)
    static func wrap(_ p: Vec2) -> Vec2 {
        return Vec2(wrapCoordinate(p.x), wrapCoordinate(p.y))
    }

    /// the hillside suburb (Summit Lane, the player's house) has its own curved streets: the grid and everything that follows it
    /// (sidewalk pedestrians, grid traffic) must stay out of this rectangle
    static let suburbRect = WRect(x0: 1090, z0: 120, x1: 1560, z1: 800)

    /// true where the grid streets physically exist
    static func hasGridStreets(at p: Vec2) -> Bool {
        return !suburbRect.contains(wrap(p))
    }

    /// true when `p` lies on asphalt of the grid (any tile)
    static func isOnGridAsphalt(_ p: Vec2, margin: Float = 0) -> Bool {
        let i: Int = nearestLine(p.x)
        let j: Int = nearestLine(p.y)
        if abs(p.x - line(i)) <= halfWidth(i) + margin { return true }
        if abs(p.y - line(j)) <= halfWidth(j) + margin { return true }
        return false
    }
}

/// a grid intersection
struct WGridNode: Hashable {
    var i: Int
    var j: Int

    var position: Vec2 { return Vec2(WGrid.line(i), WGrid.line(j)) }
    var key: Int { return ((i + 4096) << 16) | (j + 4096) }

    static func nearest(to p: Vec2) -> WGridNode {
        return WGridNode(i: WGrid.nearestLine(p.x), j: WGrid.nearestLine(p.y))
    }
}
