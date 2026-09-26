import Foundation
import SceneKit
import UIKit
import simd

// MARK: - NPCVariantSystem: who a pedestrian is (archetype) and what they wear (colour choices), applied through a material cache.
// The GLB clothing / hair / shoe / hat textures are neutral grey bases, so a colour is just `multiply` on a cached clone of the base
// material: one texture per slot, any number of looks.  Skin materials are never tinted.

struct NPCMeta: Decodable {
    struct Slot: Decodable {
        let material: String
        let palette: String?
    }
    struct Archetype: Decodable {
        let file: String
        let height: Float
        let hipHeight: Float
        let female: Bool
        let weight: Float
        let slots: [Slot]
    }
    struct PaletteColor: Decodable {
        let name: String
        let rgb: [Float]
    }
    let archetypes: [String: Archetype]
    let palettes: [String: [PaletteColor]]
}

/// the concrete look of one pedestrian: a palette index per tinted slot, a hat flag and a body scale
struct NPCAppearance {
    var archetype: String
    var colors: [String: Int] = [:]      // slot material name -> palette index
    var wearsHat: Bool = false
    var scale: Float = 1
}

@MainActor
final class NPCVariantSystem {
    private(set) var meta: NPCMeta?
    private var materialCache: [String: SCNMaterial] = [:]
    private var hiddenMaterial: SCNMaterial

    /// archetype keys in a stable order
    var archetypes: [String] {
        guard let m = meta else { return [] }
        return m.archetypes.keys.sorted()
    }

    init() {
        let h = SCNMaterial()
        h.name = "hidden"
        h.lightingModel = SCNMaterial.LightingModel.constant
        h.colorBufferWriteMask = []
        h.writesToDepthBuffer = false
        h.readsFromDepthBuffer = false
        hiddenMaterial = h
    }

    func load(assets: AssetLibrary) {
        do {
            meta = try assets.json("npc_meta", as: NPCMeta.self)
        } catch {
            assetLog("npc_meta.json not readable: \(error.localizedDescription)")
            meta = nil
        }
    }

    func archetype(_ key: String) -> NPCMeta.Archetype? { return meta?.archetypes[key] }

    /// weighted pick; `femaleShare` around 0.45 gives a natural mix
    func pickArchetype(rng: inout SeededRNG, allowed: [String]) -> String? {
        guard let m = meta, !allowed.isEmpty else { return nil }
        var total: Float = 0
        for k in allowed { total += m.archetypes[k]?.weight ?? 1 }
        var r: Float = rng.float() * total
        for k in allowed {
            r -= m.archetypes[k]?.weight ?? 1
            if r <= 0 { return k }
        }
        return allowed.last
    }

    /// deterministic look from a seed
    func makeAppearance(archetype key: String, seed: UInt64) -> NPCAppearance {
        var rng = SeededRNG(seed: seed)
        var ap = NPCAppearance(archetype: key)
        guard let m = meta, let a = m.archetypes[key] else { return ap }
        var usedClothes: [Int] = []
        for slot in a.slots {
            guard let pal = slot.palette, let list = m.palettes[pal], !list.isEmpty else { continue }
            var idx: Int = rng.int(0, list.count - 1)
            if pal == "clothes" {
                // top and bottom should not be the same colour
                var guardCount: Int = 0
                while usedClothes.contains(idx) && guardCount < 8 {
                    idx = rng.int(0, list.count - 1)
                    guardCount += 1
                }
                usedClothes.append(idx)
            }
            ap.colors[slot.material] = idx
        }
        ap.wearsHat = key == "biker" ? true : rng.chance(0.4)
        ap.scale = rng.float(0.965, 1.045)
        return ap
    }

    /// tinted clone of a base material (cached by archetype / slot / colour index)
    private func tinted(_ base: SCNMaterial, archetype: String, slot: String, index: Int, rgb: [Float]) -> SCNMaterial {
        let key: String = "\(archetype)|\(slot)|\(index)"
        if let hit = materialCache[key] { return hit }
        let copy: SCNMaterial = (base.copy() as? SCNMaterial) ?? base
        let r: CGFloat = rgb.count > 0 ? CGFloat(rgb[0]) : 1
        let g: CGFloat = rgb.count > 1 ? CGFloat(rgb[1]) : 1
        let b: CGFloat = rgb.count > 2 ? CGFloat(rgb[2]) : 1
        copy.multiply.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
        copy.name = key
        materialCache[key] = copy
        return copy
    }

    /// Re-assigns the colour materials of one pedestrian.  `baseMaterials` are the untouched materials of that instance's geometry
    /// (captured once when the instance was built), so the appearance can be changed any number of times.
    func apply(_ ap: NPCAppearance, to model: SCNNode, baseMaterials: [ObjectIdentifier: [SCNMaterial]]) {
        guard let m = meta, let arch = m.archetypes[ap.archetype] else { return }
        model.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            guard let geo = n.geometry, let bases = baseMaterials[ObjectIdentifier(geo)] else { return }
            var out: [SCNMaterial] = []
            for base in bases {
                let name: String = base.name ?? ""
                var replaced: SCNMaterial = base
                for slot in arch.slots where slot.material == name {
                    guard let pal = slot.palette, let list = m.palettes[pal], let idx = ap.colors[name], idx >= 0, idx < list.count else { continue }
                    replaced = self.tinted(base, archetype: ap.archetype, slot: name, index: idx, rgb: list[idx].rgb)
                    if name == "hat" && !ap.wearsHat { replaced = self.hiddenMaterial }
                }
                out.append(replaced)
            }
            geo.materials = out
        }
    }
}
