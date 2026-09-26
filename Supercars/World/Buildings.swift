import Foundation
import SceneKit
import simd

// MARK: - Buildings: the user's building GLBs (merged into chunk geometry) + procedural towers, low-rises, houses, warehouses.
// Everything is written into a WMeshSet per chunk (one draw call per material) and gets an oriented box collider.

private struct WBuildingsMeta: Decodable {
    struct Item: Decodable {
        let name: String
        let size: [Float]
        let hasShops: Bool?
    }
    let buildings: [Item]
}

@MainActor
final class WBuildingBuilder {
    private let mats: WorldMaterials
    private let layout: WCityLayout
    private let colliders: ColliderWorld
    private var models: [WExtracted?] = []
    /// every collider created for a building, by the chunk of its lot: the endless-world clones re-create them at an offset
    private var recorded: [Int: [Collider]] = [:]

    init(mats: WorldMaterials, layout: WCityLayout, colliders: ColliderWorld) {
        self.mats = mats
        self.layout = layout
        self.colliders = colliders
    }

    // MARK: models

    /// Reads buildings_meta.json, loads + extracts the building GLBs. Returns the infos the layout needs.
    func loadModels(assets: AssetLibrary) async -> [WBuildingInfo] {
        var infos: [WBuildingInfo] = []
        models = []
        var meta: WBuildingsMeta? = nil
        do {
            meta = try assets.json("buildings_meta", as: WBuildingsMeta.self)
        } catch {
            assetLog("buildings_meta.json not readable: \(error.localizedDescription)")
        }
        guard let m = meta else { return infos }
        for item in m.buildings {
            if item.size.count < 3 { continue }
            var extracted: WExtracted? = nil
            do {
                let node: SCNNode = try assets.model(item.name)
                extracted = WMeshExtractor.extract(from: node)
            } catch {
                assetLog("building \(item.name) failed: \(error.localizedDescription)")
            }
            if extracted == nil { continue }
            models.append(extracted)
            infos.append(WBuildingInfo(name: item.name, width: item.size[0], height: item.size[1], depth: item.size[2], hasShops: item.hasShops ?? false))
            await Task.yield()
        }
        return infos
    }

    // MARK: entry

    func build(chunkKey: Int, into set: WMeshSet) {
        guard let list = layout.lotsByChunk[chunkKey] else { return }
        for i in list {
            let lot: WLot = layout.lots[i]
            switch lot.kind {
            case .glb: addGLB(lot, set)
            case .tower: addTower(lot, set)
            case .lowrise: addLowrise(lot, set)
            case .house: addHouse(lot, set)
            case .warehouse: addWarehouse(lot, set)
            }
        }
    }

    private func addCollider(_ lot: WLot, width: Float, depth: Float, height: Float) {
        let id: Int = colliders.allocateID()
        let c = Collider.box(id: id, kind: ColliderKind.building, center: lot.center, halfExtents: Vec2(width * 0.5, depth * 0.5),
                             heading: lot.heading, height: height, mass: 1_000_000)
        colliders.add(c)
        let key: Int = wChunkKey(wChunkCoord(lot.center.x), wChunkCoord(lot.center.y))
        if recorded[key] == nil { recorded[key] = [c] } else { recorded[key]!.append(c) }
    }

    /// building colliders of base chunk `sourceKey`, shifted by `offset` (returns the new collider ids)
    func cloneColliders(sourceKey: Int, offset: Vec2) -> [Int] {
        guard let list = recorded[sourceKey] else { return [] }
        var ids: [Int] = []
        for c in list {
            var n: Collider = c
            n.id = colliders.allocateID()
            n.center = c.center + offset
            colliders.add(n)
            ids.append(n.id)
        }
        return ids
    }

    // MARK: user GLB buildings

    private func addGLB(_ lot: WLot, _ set: WMeshSet) {
        if lot.model >= 0 && lot.model < models.count, let ex = models[lot.model] {
            let xf = WXform(x: lot.center.x, y: 0, z: lot.center.y, heading: lot.heading, scale: lot.scale)
            set.append(ex.set, xf)
            addCollider(lot, width: lot.width, depth: lot.depth, height: lot.height)
        } else {
            addLowrise(lot, set)
        }
    }

    // MARK: wall helpers (local space, façade toward +Z)

    private func wallQuad(_ m: WMesh, _ xf: WXform, _ a: Vec2, _ b: Vec2, _ y0: Float, _ y1: Float, _ n2: Vec2,
                          _ u0: Float, _ u1: Float, _ v0: Float, _ v1: Float) {
        let p0 = xf.p(Vec3(a.x, y0, a.y))
        let p1 = xf.p(Vec3(b.x, y0, b.y))
        let p2 = xf.p(Vec3(b.x, y1, b.y))
        let p3 = xf.p(Vec3(a.x, y1, a.y))
        let n = xf.n(Vec3(n2.x, 0, n2.y))
        m.quad(p0, p1, p2, p3, n, u0, v0, u1, v1)
    }

    /// The four wall lines seen from outside, reading left to right: (a, b, outward normal, isFront)
    private func sides(_ hw: Float, _ hd: Float) -> [(Vec2, Vec2, Vec2)] {
        return [
            (Vec2(-hw, hd), Vec2(hw, hd), Vec2(0, 1)),
            (Vec2(hw, -hd), Vec2(-hw, -hd), Vec2(0, -1)),
            (Vec2(hw, hd), Vec2(hw, -hd), Vec2(1, 0)),
            (Vec2(-hw, -hd), Vec2(-hw, hd), Vec2(-1, 0))
        ]
    }

    private func roofQuad(_ set: WMeshSet, _ xf: WXform, _ hw: Float, _ hd: Float, _ y: Float) {
        let m = set.mesh(mats.roofGravel)
        let p0 = xf.p(Vec3(-hw, y, -hd))
        let p1 = xf.p(Vec3(hw, y, -hd))
        let p2 = xf.p(Vec3(hw, y, hd))
        let p3 = xf.p(Vec3(-hw, y, hd))
        m.quad(p0, p1, p2, p3, Vec3(0, 1, 0), 0, 0, (hw * 2) / 6, (hd * 2) / 6)
    }

    private func parapet(_ set: WMeshSet, _ xf: WXform, _ hw: Float, _ hd: Float, _ y: Float) {
        let m = set.mesh(mats.concreteWall)
        let t: Float = 0.35
        let hgt: Float = 0.9
        m.box(center: Vec3(0, y + hgt * 0.5, hd - t * 0.5), size: Vec3(hw * 2, hgt, t), u: 0.3, v: 0.3, xf: xf)
        m.box(center: Vec3(0, y + hgt * 0.5, -hd + t * 0.5), size: Vec3(hw * 2, hgt, t), u: 0.3, v: 0.3, xf: xf)
        m.box(center: Vec3(hw - t * 0.5, y + hgt * 0.5, 0), size: Vec3(t, hgt, hd * 2 - t * 2), u: 0.3, v: 0.3, xf: xf)
        m.box(center: Vec3(-hw + t * 0.5, y + hgt * 0.5, 0), size: Vec3(t, hgt, hd * 2 - t * 2), u: 0.3, v: 0.3, xf: xf)
    }

    private func rooftopUnits(_ set: WMeshSet, _ xf: WXform, _ hw: Float, _ hd: Float, _ y: Float, _ seed: Int) {
        let m = set.mesh(mats.metal)
        let count: Int = 1 + seed % 3
        for k in 0..<count {
            let fx: Float = wHash01(seed, k, 3) - 0.5
            let fz: Float = wHash01(seed, k, 4) - 0.5
            let sx: Float = 1.6 + wHash01(seed, k, 5) * 2.4
            let sz: Float = 1.6 + wHash01(seed, k, 6) * 2.0
            let sy: Float = 1.2 + wHash01(seed, k, 7) * 1.6
            let cx: Float = fx * max(0, hw * 2 - sx - 2)
            let cz: Float = fz * max(0, hd * 2 - sz - 2)
            m.box(center: Vec3(cx, y + sy * 0.5, cz), size: Vec3(sx, sy, sz), u: 0.5, v: 0.5, xf: xf)
        }
    }

    /// One facade shaft (four walls) between y0 and y1. shopSides: bit mask over sides() indices that get a shop ground floor.
    private func shaft(_ set: WMeshSet, _ xf: WXform, _ hw: Float, _ hd: Float, _ y0: Float, _ y1: Float, _ facade: SCNMaterial,
                       shopMask: Int, shopHeight: Float, seed: Int) {
        let fm = set.mesh(facade)
        let tw: Float = WFacades.tileWidth
        let th: Float = WFacades.tileHeight
        let uo: Float = Float(seed % 8) / 8
        var index = 0
        for s in sides(hw, hd) {
            let len: Float = simd_length(s.1 - s.0)
            let hasShop: Bool = (shopMask & (1 << index)) != 0 && !mats.shop.isEmpty
            if hasShop {
                let sm = set.mesh(mats.shop[seed % mats.shop.count])
                let shopU0: Float = Float((seed / 3) % 4) * 0.25
                wallQuad(sm, xf, s.0, s.1, y0, y0 + shopHeight, s.2, shopU0, shopU0 + len / 24, 0, 1)
                wallQuad(fm, xf, s.0, s.1, y0 + shopHeight, y1, s.2, uo, uo + len / tw, 0, (y1 - y0 - shopHeight) / th)
            } else {
                wallQuad(fm, xf, s.0, s.1, y0, y1, s.2, uo, uo + len / tw, 0, (y1 - y0) / th)
            }
            index += 1
        }
    }

    private func awning(_ set: WMeshSet, _ xf: WXform, _ hw: Float, _ hd: Float, _ y: Float) {
        let m = set.mesh(mats.awning)
        let p0 = xf.p(Vec3(-hw + 0.8, y, hd))
        let p1 = xf.p(Vec3(hw - 0.8, y, hd))
        let p2 = xf.p(Vec3(hw - 0.8, y - 0.7, hd + 1.5))
        let p3 = xf.p(Vec3(-hw + 0.8, y - 0.7, hd + 1.5))
        let n = xf.n(Vec3(0, 0.5, 0.86))
        m.quad(p0, p1, p2, p3, n, 0, 0, (hw * 2 - 1.6) / 4, 1)
    }

    // MARK: towers

    private func bays(_ length: Float) -> Float {
        let n: Float = max(2, floorf(length / WFacades.bayWidth))
        return n * WFacades.bayWidth
    }

    private func addTower(_ lot: WLot, _ set: WMeshSet) {
        let w: Float = bays(lot.width)
        let d: Float = bays(lot.depth)
        let floors: Float = max(6, roundf(lot.height / WFacades.floorHeight))
        let h: Float = floors * WFacades.floorHeight
        let xf = WXform(x: lot.center.x, y: 0, z: lot.center.y, heading: 0, scale: 1)
        let facade: SCNMaterial = mats.facadeMaterial(style: lot.style, variant: lot.variant)
        let hw: Float = w * 0.5
        let hd: Float = d * 0.5
        let podium: Float = 5.0
        if h > 110 {
            let h1: Float = roundf(h * 0.62 / WFacades.floorHeight) * WFacades.floorHeight
            shaft(set, xf, hw, hd, 0, h1, facade, shopMask: 15, shopHeight: podium, seed: lot.seed)
            roofQuad(set, xf, hw, hd, h1)
            let w2: Float = bays(w * 0.72)
            let d2: Float = bays(d * 0.72)
            let hw2: Float = w2 * 0.5
            let hd2: Float = d2 * 0.5
            shaft(set, xf, hw2, hd2, h1, h, facade, shopMask: 0, shopHeight: 0, seed: lot.seed + 3)
            roofQuad(set, xf, hw2, hd2, h)
            parapet(set, xf, hw2, hd2, h)
            rooftopUnits(set, xf, hw2, hd2, h, lot.seed)
            addAntenna(set, xf, h, lot.seed)
        } else {
            shaft(set, xf, hw, hd, 0, h, facade, shopMask: 15, shopHeight: podium, seed: lot.seed)
            roofQuad(set, xf, hw, hd, h)
            parapet(set, xf, hw, hd, h)
            rooftopUnits(set, xf, hw, hd, h, lot.seed)
            if h > 70 { addAntenna(set, xf, h, lot.seed) }
        }
        var l = lot
        l.heading = 0
        addCollider(l, width: w, depth: d, height: h)
    }

    private func addAntenna(_ set: WMeshSet, _ xf: WXform, _ h: Float, _ seed: Int) {
        let mm = set.mesh(mats.metal)
        let mast: Float = 10 + Float(seed % 9)
        mm.cylinder(base: Vec3(0, h + 1, 0), radiusBottom: 0.35, radiusTop: 0.06, height: mast, segments: 6, u: 0.5, v: 0.5, capTop: false, xf: xf)
        let bm = set.mesh(mats.beacon)
        bm.box(center: Vec3(0, h + 1 + mast + 0.2, 0), size: Vec3(0.5, 0.5, 0.5), u: 0.5, v: 0.5, xf: xf)
    }

    // MARK: low-rise

    private func addLowrise(_ lot: WLot, _ set: WMeshSet) {
        let w: Float = bays(lot.width)
        let d: Float = max(8, lot.depth)
        let floors: Float = max(3, roundf(lot.height / WFacades.floorHeight))
        let h: Float = floors * WFacades.floorHeight
        let xf = WXform(x: lot.center.x, y: 0, z: lot.center.y, heading: lot.heading, scale: 1)
        let facade: SCNMaterial = mats.facadeMaterial(style: lot.style, variant: lot.variant)
        let hw: Float = w * 0.5
        let hd: Float = d * 0.5
        shaft(set, xf, hw, hd, 0, h, facade, shopMask: 1, shopHeight: 5.0, seed: lot.seed)
        awning(set, xf, hw, hd, 4.6)
        roofQuad(set, xf, hw, hd, h)
        parapet(set, xf, hw, hd, h)
        rooftopUnits(set, xf, hw, hd, h, lot.seed)
        addCollider(lot, width: w, depth: d, height: h)
    }

    // MARK: houses

    private func addHouse(_ lot: WLot, _ set: WMeshSet) {
        let w: Float = lot.width
        let d: Float = lot.depth
        let wallH: Float = 7.2
        let hw: Float = w * 0.5
        let hd: Float = d * 0.5
        let xf = WXform(x: lot.center.x, y: 0, z: lot.center.y, heading: lot.heading, scale: 1)
        let facade: SCNMaterial = mats.facadeMaterial(style: 4 + lot.style % 3, variant: lot.variant)
        shaft(set, xf, hw, hd, 0, wallH, facade, shopMask: 0, shopHeight: 0, seed: lot.seed)

        // gable roof, ridge along local x
        let rh: Float = d * 0.30
        let ov: Float = 0.5
        let roofMat: SCNMaterial = mats.roofTiles.isEmpty ? mats.roofGravel : mats.roofTiles[lot.variant % mats.roofTiles.count]
        let rm = set.mesh(roofMat)
        let slope: Float = sqrtf((hd + ov) * (hd + ov) + rh * rh)
        let nFront = xf.n(Vec3(0, hd + ov, rh).normalizedSafe)
        let nBack = xf.n(Vec3(0, hd + ov, -rh).normalizedSafe)
        let r0 = xf.p(Vec3(-hw - ov, wallH - 0.15, hd + ov))
        let r1 = xf.p(Vec3(hw + ov, wallH - 0.15, hd + ov))
        let r2 = xf.p(Vec3(hw + ov, wallH + rh, 0))
        let r3 = xf.p(Vec3(-hw - ov, wallH + rh, 0))
        rm.quad(r0, r1, r2, r3, nFront, 0, 0, (w + ov * 2) / 2, slope / 2)
        let b0 = xf.p(Vec3(hw + ov, wallH - 0.15, -hd - ov))
        let b1 = xf.p(Vec3(-hw - ov, wallH - 0.15, -hd - ov))
        let b2 = xf.p(Vec3(-hw - ov, wallH + rh, 0))
        let b3 = xf.p(Vec3(hw + ov, wallH + rh, 0))
        rm.quad(b0, b1, b2, b3, nBack, 0, 0, (w + ov * 2) / 2, slope / 2)
        // gable ends
        let fm = set.mesh(facade)
        let tw: Float = WFacades.tileWidth
        let th: Float = WFacades.tileHeight
        for sx in [Float(-1), Float(1)] {
            let x: Float = hw * sx
            let q0 = xf.p(Vec3(x, wallH, -hd))
            let q1 = xf.p(Vec3(x, wallH, hd))
            let q2 = xf.p(Vec3(x, wallH + rh, 0))
            fm.quad(q0, q1, q2, q2, xf.n(Vec3(sx, 0, 0)), 0, wallH / th, d / tw, (wallH + rh) / th)
        }

        // door, garage door, chimney
        let dm = set.mesh(mats.propsDead)
        let doorUV = WTex.atlasCellUV(3)
        let garageUV = WTex.atlasCellUV(13)
        let dz: Float = hd + 0.04
        let dx: Float = -w * 0.22
        let n = xf.n(Vec3(0, 0, 1))
        dm.quad(xf.p(Vec3(dx - 0.5, 0, dz)), xf.p(Vec3(dx + 0.5, 0, dz)), xf.p(Vec3(dx + 0.5, 2.15, dz)), xf.p(Vec3(dx - 0.5, 2.15, dz)),
                n, doorUV.u, doorUV.v, doorUV.u, doorUV.v)
        let gx: Float = w * 0.26
        dm.quad(xf.p(Vec3(gx - 1.4, 0, dz)), xf.p(Vec3(gx + 1.4, 0, dz)), xf.p(Vec3(gx + 1.4, 2.3, dz)), xf.p(Vec3(gx - 1.4, 2.3, dz)),
                n, garageUV.u, garageUV.v, garageUV.u, garageUV.v)
        let cm = set.mesh(mats.concreteWall)
        cm.box(center: Vec3(hw * 0.45, wallH + rh * 0.55, -hd * 0.25), size: Vec3(0.8, rh + 1.8, 0.8), u: 0.4, v: 0.4, xf: xf)
        addCollider(lot, width: w, depth: d, height: wallH + rh)
    }

    // MARK: warehouses

    private func addWarehouse(_ lot: WLot, _ set: WMeshSet) {
        let w: Float = lot.width
        let d: Float = lot.depth
        let h: Float = lot.height
        let hw: Float = w * 0.5
        let hd: Float = d * 0.5
        let xf = WXform(x: lot.center.x, y: 0, z: lot.center.y, heading: lot.heading, scale: 1)
        let wm = set.mesh(mats.warehouseWall)
        for s in sides(hw, hd) {
            let len: Float = simd_length(s.1 - s.0)
            wallQuad(wm, xf, s.0, s.1, 0, h, s.2, 0, len / 6, 0, h / 6)
        }
        roofQuad(set, xf, hw, hd, h)
        parapet(set, xf, hw, hd, h)
        rooftopUnits(set, xf, hw, hd, h, lot.seed)
        let mm = set.mesh(mats.metal)
        let doors: Int = max(1, Int(w / 12))
        for k in 0..<doors {
            let cx: Float = -hw + (Float(k) + 0.5) * (w / Float(doors))
            mm.box(center: Vec3(cx, 2.0, hd + 0.06), size: Vec3(4.2, 4.0, 0.12), u: 0.5, v: 0.5, xf: xf)
        }
        addCollider(lot, width: w, depth: d, height: h)
    }
}
