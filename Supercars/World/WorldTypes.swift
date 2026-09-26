import Foundation
import simd

// MARK: - Public world types (exact contract from docs/ARCHITECTURE.md)

enum SurfaceType { case asphalt, sidewalk, grass, dirt, concrete }

struct Spawn {
    var position: Vec3
    var heading: Float
}

struct SpawnPoints {
    var houseDoor: Spawn
    var car: Spawn
    var player: Spawn
    var garageDoor: Spawn
    var raceGate: Spawn
    var house: Spawn
}

struct RaceRoute {
    var name: String
    var points: [Vec2]
    var width: Float
    var closed: Bool
    var length: Float
}

enum ColliderKind { case building, wall, lamp, tree, sign, prop, houseWall, barrier }

/// radius > 0 => circle collider; otherwise oriented box (halfExtents in local x (left) / z (forward), rotated by heading)
struct Collider {
    var id: Int
    var kind: ColliderKind
    var center: Vec2
    var halfExtents: Vec2
    var radius: Float
    var heading: Float
    var destructible: Bool
    var height: Float
    var mass: Float

    static func circle(id: Int, kind: ColliderKind, center: Vec2, radius: Float, destructible: Bool, height: Float, mass: Float) -> Collider {
        return Collider(id: id, kind: kind, center: center, halfExtents: Vec2(radius, radius), radius: radius, heading: 0,
                        destructible: destructible, height: height, mass: mass)
    }

    static func box(id: Int, kind: ColliderKind, center: Vec2, halfExtents: Vec2, heading: Float, height: Float, mass: Float) -> Collider {
        return Collider(id: id, kind: kind, center: center, halfExtents: halfExtents, radius: 0, heading: heading,
                        destructible: false, height: height, mass: mass)
    }
}

// MARK: - Internal constants and helpers shared by the World files

enum WC {
    static let pitch: Float = 140          // distance between grid road centre lines
    static let gridN: Int = 8              // city blocks span grid lines -8 ... 8 (buildings, districts)
    static let roadN: Int = 11             // streets continue through the green belt: lines -11 ... 11 (one endless-world tile = 22 lines)
    static let tileLines: Int = 22         // the world repeats every 22 grid lines = 3080 m (chunks -11 ... 10)
    static let tileChunks: Int = 22
    static let halfWorld: Float = 1500
    static let chunk: Float = 140          // static geometry chunk edge
    static let cell: Float = 70            // prop cell edge
    static let curbH: Float = 0.15
}

@inline(__always) func wChunkCoord(_ v: Float) -> Int { return Int(floorf(v / WC.chunk)) }
@inline(__always) func wChunkKey(_ cx: Int, _ cz: Int) -> Int { return (cx + 4096) * 8192 + (cz + 4096) }
@inline(__always) func wCellCoord(_ v: Float) -> Int { return Int(floorf(v / WC.cell)) }
@inline(__always) func wCellKey(_ cx: Int, _ cz: Int) -> Int { return (cx + 200) * 512 + (cz + 200) }

func wMixVec3(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 { return a + (b - a) * t }

struct WRect {
    var x0: Float
    var z0: Float
    var x1: Float
    var z1: Float
    var width: Float { return x1 - x0 }
    var depth: Float { return z1 - z0 }
    var center: Vec2 { return Vec2((x0 + x1) * 0.5, (z0 + z1) * 0.5) }
    func contains(_ p: Vec2) -> Bool { return p.x >= x0 && p.x < x1 && p.y >= z0 && p.y < z1 }
    func containsInclusive(_ p: Vec2) -> Bool { return p.x >= x0 && p.x <= x1 && p.y >= z0 && p.y <= z1 }
    func expanded(_ m: Float) -> WRect { return WRect(x0: x0 - m, z0: z0 - m, x1: x1 + m, z1: z1 + m) }
    func overlaps(_ o: WRect) -> Bool { return x0 < o.x1 && x1 > o.x0 && z0 < o.z1 && z1 > o.z0 }
}

/// Small deterministic hash -> [0,1)
func wHash01(_ a: Int, _ b: Int, _ seed: Int) -> Float {
    var h: UInt32 = UInt32(truncatingIfNeeded: a &* 374761393 &+ b &* 668265263 &+ seed &* 2246822519)
    h = (h ^ (h >> 13)) &* 1274126177
    h = h ^ (h >> 16)
    return Float(h & 0xFFFFFF) / Float(0x1000000)
}

/// Distance from p to segment a-b, also returns the closest parameter t in [0,1].
func wSegmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> (dist: Float, t: Float) {
    let ab = b - a
    let l2 = simd_dot(ab, ab)
    if l2 < 1e-6 { return (simd_length(p - a), 0) }
    var t = simd_dot(p - a, ab) / l2
    t = clampf(t, 0, 1)
    let q = a + ab * t
    return (simd_length(p - q), t)
}
