import Foundation
import SceneKit

// MARK: - NPCPool: every pedestrian model is built once at load time and reused.  Acquire -> configure -> spawn, later
// release -> hide -> back to the pool.  No node is created or destroyed while the game runs (no allocation spikes).

@MainActor
final class NPCPool {
    private(set) var all: [NPCCharacter] = []
    private var free: [Int] = []
    let root = SCNNode()

    init() {
        root.name = "npcRoot"
    }

    var activeCount: Int { return all.count - free.count }
    var capacity: Int { return all.count }
    var freeCount: Int { return free.count }

    /// builds `capacity` pedestrians spread over the archetypes by weight (at least 2 of each)
    func build(capacity: Int, archetypes: [String], assets: AssetLibrary, variants: NPCVariantSystem, parent: SCNNode) async {
        parent.addChildNode(root)
        if archetypes.isEmpty { return }
        var weights: [Float] = []
        var total: Float = 0
        for a in archetypes {
            let w: Float = variants.archetype(a)?.weight ?? 1
            weights.append(w)
            total += w
        }
        var counts: [Int] = []
        for w in weights { counts.append(max(2, Int((Float(capacity) * w / total).rounded()))) }
        var slot: Int = 0
        for (k, a) in archetypes.enumerated() {
            for _ in 0..<counts[k] {
                if let n = NPCCharacter(slot: slot, archetype: a, assets: assets, variants: variants) {
                    root.addChildNode(n.node)
                    all.append(n)
                    free.append(all.count - 1)
                }
                slot += 1
            }
            await Task.yield()
        }
    }

    /// a random free pedestrian
    func acquire(rng: inout SeededRNG) -> NPCCharacter? {
        if free.isEmpty { return nil }
        let k: Int = rng.int(0, free.count - 1)
        let idx: Int = free.remove(at: k)
        return all[idx]
    }

    func release(_ n: NPCCharacter) {
        guard n.isActive else { return }
        n.deactivate()
        if let idx = all.firstIndex(where: { $0 === n }) { free.append(idx) }
    }

    var active: [NPCCharacter] {
        var out: [NPCCharacter] = []
        for n in all where n.isActive { out.append(n) }
        return out
    }
}
