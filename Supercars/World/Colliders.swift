import Foundation
import simd

// MARK: - Collider world: spatial hash grid of 2D colliders (buildings, walls, lamps, trees, signs ...)

/// Implemented by the prop system: plays the destruction animation of a struck destructible.
@MainActor
protocol WColliderStrikeHandler: AnyObject {
    func worldStrike(collider: Collider, speed: Float, direction: Vec2)
}

private struct WColliderEntry {
    var c: Collider
    var minX: Float
    var maxX: Float
    var minZ: Float
    var maxZ: Float
}

@MainActor
final class ColliderWorld {
    private var store: [Int: WColliderEntry] = [:]
    private var cells: [Int: [Int]] = [:]
    private var nextID: Int = 100_000
    private var seen = Set<Int>()
    private var scratch: [Collider] = []
    private let cellSize: Float = 20
    weak var strikeHandler: WColliderStrikeHandler?

    init() {
        scratch.reserveCapacity(64)
    }

    var count: Int { return store.count }

    /// Unique id for colliders created by the world (teammates may also pick their own ids >= 1_000_000_000 or use this).
    func allocateID() -> Int {
        nextID += 1
        return nextID
    }

    func collider(id: Int) -> Collider? {
        return store[id]?.c
    }

    private func cellKey(_ cx: Int, _ cz: Int) -> Int { return (cx + 4096) * 8192 + (cz + 4096) }

    private func bounds(of c: Collider) -> (Float, Float, Float, Float) {
        if c.radius > 0 {
            return (c.center.x - c.radius, c.center.x + c.radius, c.center.y - c.radius, c.center.y + c.radius)
        }
        let ch = abs(cosf(c.heading))
        let sh = abs(sinf(c.heading))
        let ex = ch * c.halfExtents.x + sh * c.halfExtents.y
        let ez = sh * c.halfExtents.x + ch * c.halfExtents.y
        return (c.center.x - ex, c.center.x + ex, c.center.y - ez, c.center.y + ez)
    }

    func add(_ c: Collider) {
        if store[c.id] != nil { remove(id: c.id) }
        let b = bounds(of: c)
        let entry = WColliderEntry(c: c, minX: b.0, maxX: b.1, minZ: b.2, maxZ: b.3)
        store[c.id] = entry
        let cx0 = Int(floorf(b.0 / cellSize))
        let cx1 = Int(floorf(b.1 / cellSize))
        let cz0 = Int(floorf(b.2 / cellSize))
        let cz1 = Int(floorf(b.3 / cellSize))
        var cx = cx0
        while cx <= cx1 {
            var cz = cz0
            while cz <= cz1 {
                let key = cellKey(cx, cz)
                if cells[key] == nil { cells[key] = [c.id] } else { cells[key]!.append(c.id) }
                cz += 1
            }
            cx += 1
        }
    }

    func remove(id: Int) {
        guard let e = store[id] else { return }
        store[id] = nil
        let cx0 = Int(floorf(e.minX / cellSize))
        let cx1 = Int(floorf(e.maxX / cellSize))
        let cz0 = Int(floorf(e.minZ / cellSize))
        let cz1 = Int(floorf(e.maxZ / cellSize))
        var cx = cx0
        while cx <= cx1 {
            var cz = cz0
            while cz <= cz1 {
                let key = cellKey(cx, cz)
                if var list = cells[key] {
                    if let idx = list.firstIndex(of: id) {
                        list.remove(at: idx)
                        cells[key] = list
                    }
                }
                cz += 1
            }
            cx += 1
        }
    }

    /// Colliders whose bounds may touch the circle. The returned array is a copy of an internal scratch buffer.
    func query(center: Vec2, radius: Float) -> [Collider] {
        scratch.removeAll(keepingCapacity: true)
        seen.removeAll(keepingCapacity: true)
        let cx0 = Int(floorf((center.x - radius) / cellSize))
        let cx1 = Int(floorf((center.x + radius) / cellSize))
        let cz0 = Int(floorf((center.y - radius) / cellSize))
        let cz1 = Int(floorf((center.y + radius) / cellSize))
        var cx = cx0
        while cx <= cx1 {
            var cz = cz0
            while cz <= cz1 {
                if let list = cells[cellKey(cx, cz)] {
                    for id in list {
                        if seen.contains(id) { continue }
                        seen.insert(id)
                        guard let e = store[id] else { continue }
                        // circle vs AABB
                        let nx = max(e.minX, min(center.x, e.maxX))
                        let nz = max(e.minZ, min(center.y, e.maxZ))
                        let dx = center.x - nx
                        let dz = center.y - nz
                        if dx * dx + dz * dz <= radius * radius {
                            scratch.append(e.c)
                        }
                    }
                }
                cz += 1
            }
            cx += 1
        }
        return scratch
    }

    /// A vehicle hit destructible `id`. Returns the fraction of momentum absorbed (lamp 0.25, sign 0.15, small tree 0.45, big tree 0.6, other 0.9).
    func strike(id: Int, speed: Float, direction: Vec2) -> Float {
        guard let e = store[id] else { return 0 }
        let c = e.c
        if !c.destructible { return 0.9 }
        var frac: Float = 0.9
        switch c.kind {
        case .lamp: frac = 0.25
        case .sign: frac = 0.15
        case .tree: frac = c.height >= 6.5 ? 0.6 : 0.45
        default: frac = 0.9
        }
        remove(id: id)
        strikeHandler?.worldStrike(collider: c, speed: speed, direction: direction)
        return frac
    }
}
