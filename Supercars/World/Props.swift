import Foundation
import SceneKit
import UIKit
import simd

// MARK: - Street props: lamps, signs, traffic signals, benches (merged per chunk, rebuilt when one is destroyed) and the user's
// mango trees (individual nodes with 3 LODs). Destructible props (lamps, signs, trees) get circle colliders; hitting one plays the
// destruction animation + sound + dust and removes the collider (ColliderWorld.strike -> worldStrike).

enum WPropKind: Int {
    case lamp, tree, sign, signal, bench, hydrant, bin
}

struct WProp {
    var id: Int
    var kind: WPropKind
    var pos: Vec2
    var heading: Float
    var scale: Float
    var variant: Int
    var alive: Bool
    var colliderID: Int
    var chunk: Int
}

@MainActor
final class WTreeInstance {
    let propIndex: Int
    let container = SCNNode()
    let holder = SCNNode()
    var lods: [SCNNode?] = [nil, nil, nil]
    var current: Int = -1
    init(propIndex: Int) { self.propIndex = propIndex }
}

@MainActor
final class WPropSystem: WColliderStrikeHandler {
    private unowned let ctx: GameContext
    private let layout: WCityLayout
    private let mats: WorldMaterials
    private let colliders: ColliderWorld
    private weak var worldRoot: SCNNode?

    private(set) var props: [WProp] = []
    private var byChunk: [Int: [Int]] = [:]
    private var propByCollider: [Int: Int] = [:]
    private var chunkPropNodes: [Int: SCNNode] = [:]
    private var trees: [Int: WTreeInstance] = [:]
    private var treeList: [WTreeInstance] = []
    private var lodTimer: Float = 0
    private var lampsByChunk: [Int: [Vec2]] = [:]
    private let lodNames: [String] = ["tree_lod0", "tree_lod1", "tree_lod2"]
    private var treeDetailFactor: Float = 1
    private var particlesOn = true
    private var dustImage: UIImage?
    private var hasTreeModels = true
    private var freeProps: [Int] = []
    // street furniture (flat, lit colours; merged into the chunk's prop geometry)
    private let hydrantMat: SCNMaterial = WPropSystem.flat(0.62, 0.12, 0.09)
    private let hydrantCapMat: SCNMaterial = WPropSystem.flat(0.55, 0.56, 0.58)
    private let binMat: SCNMaterial = WPropSystem.flat(0.16, 0.24, 0.20)
    private let binLidMat: SCNMaterial = WPropSystem.flat(0.10, 0.11, 0.12)

    private static func flat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = SCNMaterial.LightingModel.lambert
        m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
        return m
    }

    init(ctx: GameContext, layout: WCityLayout, mats: WorldMaterials, colliders: ColliderWorld, worldRoot: SCNNode) {
        self.ctx = ctx
        self.layout = layout
        self.mats = mats
        self.colliders = colliders
        self.worldRoot = worldRoot
        colliders.strikeHandler = self
    }

    func applyGraphics(_ g: GraphicsSettings) {
        let factors: [Float] = [0.45, 0.7, 1.0]
        treeDetailFactor = factors[max(0, min(2, g.treeDetail))]
        particlesOn = g.particles
    }

    // MARK: generation

    private func chunkKey(_ p: Vec2) -> Int { return wChunkKey(wChunkCoord(p.x), wChunkCoord(p.y)) }

    /// registers the collider of a prop of `kind` and returns its id
    private func makeCollider(_ kind: WPropKind, _ pos: Vec2, _ heading: Float, _ scale: Float) -> Int {
        let cid: Int = colliders.allocateID()
        switch kind {
        case .lamp:
            colliders.add(Collider.circle(id: cid, kind: ColliderKind.lamp, center: pos, radius: 0.24, destructible: true, height: 8.2, mass: 260))
        case .sign:
            colliders.add(Collider.circle(id: cid, kind: ColliderKind.sign, center: pos, radius: 0.16, destructible: true, height: 3.0, mass: 40))
        case .tree:
            let r: Float = max(0.32, 0.46 * scale)
            colliders.add(Collider.circle(id: cid, kind: ColliderKind.tree, center: pos, radius: r, destructible: true, height: 6.8 * scale, mass: 2600 * scale))
        case .signal:
            colliders.add(Collider.circle(id: cid, kind: ColliderKind.prop, center: pos, radius: 0.26, destructible: false, height: 4.8, mass: 400))
        case .bench:
            colliders.add(Collider.box(id: cid, kind: ColliderKind.prop, center: pos, halfExtents: Vec2(0.95, 0.32), heading: heading, height: 0.9, mass: 120))
        case .hydrant:
            colliders.add(Collider.circle(id: cid, kind: ColliderKind.prop, center: pos, radius: 0.22, destructible: false, height: 0.8, mass: 400))
        case .bin:
            colliders.add(Collider.circle(id: cid, kind: ColliderKind.prop, center: pos, radius: 0.30, destructible: false, height: 1.0, mass: 120))
        }
        return cid
    }

    private func add(_ kind: WPropKind, _ pos: Vec2, _ heading: Float, _ scale: Float, _ variant: Int) {
        let key: Int = chunkKey(pos)
        let i: Int = props.count
        let cid: Int = makeCollider(kind, pos, heading, scale)
        props.append(WProp(id: i, kind: kind, pos: pos, heading: heading, scale: scale, variant: variant, alive: true, colliderID: cid, chunk: key))
        if byChunk[key] == nil { byChunk[key] = [i] } else { byChunk[key]!.append(i) }
        if cid >= 0 { propByCollider[cid] = i }
        if kind == WPropKind.lamp {
            if lampsByChunk[key] == nil { lampsByChunk[key] = [pos] } else { lampsByChunk[key]!.append(pos) }
        }
    }

    private func lampSpacing(_ cls: WRoadClass) -> Float {
        switch cls {
        case .street: return 36
        case .avenue: return 34
        case .boulevard: return 32
        case .ring: return 38
        case .suburb: return 42
        case .connector: return 40
        }
    }

    private func blocked(_ p: Vec2, _ road: WRoad, margin: Float) -> Bool {
        if abs(p.x) > 1530 || abs(p.y) > 1530 { return true }
        if layout.index.insideAsphalt(p, excluding: road.id, margin: margin) { return true }
        if layout.insidePlot(p, margin: 3) { return true }
        return false
    }

    func generate() {
        props = []
        byChunk = [:]
        propByCollider = [:]
        lampsByChunk = [:]
        let dens: Float = clampf(ctx.settings.settings.graphics.propDensity, 0.2, 1.3)
        for road in layout.roads {
            placeAlongRoad(road, dens)
        }
        placeIntersections(dens)
        placeParks()
    }

    private func placeAlongRoad(_ road: WRoad, _ dens: Float) {
        let len: Float = road.length
        let spacing: Float = lampSpacing(road.cls) / max(0.6, min(1.0, dens))
        let bothSides: Bool = road.cls == WRoadClass.avenue || road.cls == WRoadClass.boulevard || road.cls == WRoadClass.ring
        // lamps
        var s: Float = 14
        var idx = 0
        while s < len - 8 {
            let smp = road.sample(at: s)
            let nrm: Vec2 = smp.dir.leftPerp
            let sideList: [Float] = bothSides ? [1, -1] : [(idx % 2 == 0 ? 1 : -1)]
            for side in sideList {
                let p: Vec2 = smp.p + nrm * side * (road.halfWidth + 1.25)
                if blocked(p, road, margin: 3.8) { continue }
                add(WPropKind.lamp, p, headingOf(nrm * -side), 1, idx)
            }
            s += spacing
            idx += 1
        }
        // trees
        var treeStep: Float = 26
        var treeScale: Float = 0.8
        switch road.cls {
        case .street: treeStep = 46; treeScale = 0.72
        case .avenue: treeStep = 30; treeScale = 0.78
        case .boulevard: treeStep = 15; treeScale = 0.9
        case .ring: treeStep = 26; treeScale = 0.85
        case .suburb: treeStep = 21; treeScale = 1.05
        case .connector: treeStep = 34; treeScale = 0.8
        }
        treeStep = treeStep / max(0.5, min(1.1, dens))
        var t: Float = 5 + spacing * 0.5
        var ti = 0
        while t < len - 6 {
            let smp = road.sample(at: t)
            let nrm: Vec2 = smp.dir.leftPerp
            var places: [Vec2] = []
            if road.cls == WRoadClass.boulevard {
                places.append(smp.p)
            } else if road.cls == WRoadClass.suburb {
                places.append(smp.p + nrm * (road.halfWidth + 5.5))
                places.append(smp.p - nrm * (road.halfWidth + 5.5))
            } else {
                places.append(smp.p + nrm * (road.halfWidth + 3.0))
                places.append(smp.p - nrm * (road.halfWidth + 3.0))
            }
            for (k, p) in places.enumerated() {
                let h: Float = wHash01(ti, k + road.id * 7, 55)
                let keep: Float = road.cls == WRoadClass.street ? 0.55 : 0.92
                if h > keep { continue }
                if blocked(p, road, margin: 5.0) { continue }
                let sc: Float = treeScale * (0.88 + 0.3 * wHash01(ti, k, 17 + road.id))
                add(WPropKind.tree, p, wHash01(ti, k, 3) * Float.tau, sc, ti)
            }
            t += treeStep
            ti += 1
        }
    }

    private func placeIntersections(_ dens: Float) {
        let n = WC.roadN
        for a in -n...n {
            for b in -n...n {
                let clsA = WCityLayout.gridClass(a)
                let clsB = WCityLayout.gridClass(b)
                let hx: Float = WRoad.dimensions(clsA).half
                let hz: Float = WRoad.dimensions(clsB).half
                let centre = Vec2(Float(a) * WC.pitch, Float(b) * WC.pitch)
                let major: Bool = clsA != WRoadClass.street && clsB != WRoadClass.street
                // no intersection exists where the hillside suburb keeps the grid out
                if a >= 9 && b >= 1 && b <= 5 { continue }
                for sx in [Float(-1), Float(1)] {
                    for sz in [Float(-1), Float(1)] {
                        // street furniture: fire hydrants and litter bins along the sidewalks near the corners
                        let fr: Float = wHash01(a + 60, b + 60, Int(sx * 7 + sz * 11 + 40))
                        if fr < 0.20 * dens {
                            let hp = centre + Vec2(sx * (hx + 1.3), sz * (hz + 9.0))
                            if !layout.index.insideAsphalt(hp, excluding: -1, margin: 0.8) { add(WPropKind.hydrant, hp, 0, 1, 0) }
                        } else if fr > 0.84 {
                            let bp = centre + Vec2(sx * (hx + 3.4), sz * (hz + 6.5))
                            if !layout.index.insideAsphalt(bp, excluding: -1, margin: 0.8) { add(WPropKind.bin, bp, 0, 1, 0) }
                        }
                        let p = centre + Vec2(sx * (hx + 2.2), sz * (hz + 2.2))
                        if layout.index.insideAsphalt(p, excluding: -1, margin: 0.5) { continue }
                        let faceX: Bool = sx * sz > 0
                        let faceDir: Vec2 = faceX ? Vec2(-sx, 0) : Vec2(0, -sz)
                        let heading: Float = headingOf(faceDir)
                        let r: Float = wHash01(a + 40, b + 40, Int(sx * 3 + sz * 5 + 20))
                        if major {
                            if faceX == (a % 2 == 0) { add(WPropKind.signal, p, heading, 1, Int(r * 3)) }
                        } else if r < 0.55 * dens {
                            var kind: Int = Int(r * 100) % 8
                            if clsA == WRoadClass.street && clsB == WRoadClass.street && r < 0.3 { kind = 0 }
                            add(WPropKind.sign, p, heading, 1, kind)
                        }
                    }
                }
            }
        }
    }

    private func placeParks() {
        for (pi, r) in layout.parkRects.enumerated() {
            var x: Float = r.x0 + 12
            var ix = 0
            while x < r.x1 - 8 {
                var z: Float = r.z0 + 12
                var iz = 0
                while z < r.z1 - 8 {
                    let jx: Float = (wHash01(ix, iz, 71 + pi) - 0.5) * 9
                    let jz: Float = (wHash01(ix, iz, 72 + pi) - 0.5) * 9
                    let p = Vec2(x + jx, z + jz)
                    let inPond: Bool = pi == 0 && simd_length(p - r.center) < 22
                    if !inPond && wHash01(ix, iz, 73 + pi) < 0.72 {
                        add(WPropKind.tree, p, wHash01(ix, iz, 74) * Float.tau, 1.0 + 0.35 * wHash01(ix, iz, 75), ix + iz)
                    }
                    z += 17
                    iz += 1
                }
                x += 17
                ix += 1
            }
            // benches along the middle path
            var bx: Float = r.x0 + 20
            var bi = 0
            while bx < r.x1 - 15 {
                let nearPond: Bool = pi == 0 && abs(bx + 5 - r.center.x) < 24
                if !nearPond {
                    add(WPropKind.bench, Vec2(bx, (r.z0 + r.z1) * 0.5 + 3), 0, 1, bi)
                    add(WPropKind.bench, Vec2(bx + 10, (r.z0 + r.z1) * 0.5 - 3), Float.pi, 1, bi)
                }
                bx += 34
                bi += 1
            }
        }
        // plaza: ring of trees + benches
        let pz = layout.plazaRect
        if pz.width > 10 {
            let c = pz.center
            for k in 0..<12 {
                let a: Float = Float(k) / 12 * Float.tau
                let p = c + Vec2(cosf(a), sinf(a)) * 34
                add(WPropKind.tree, p, a, 0.95, k)
            }
            for k in 0..<8 {
                let a: Float = (Float(k) + 0.5) / 8 * Float.tau
                let p = c + Vec2(cosf(a), sinf(a)) * 20
                add(WPropKind.bench, p, headingOf(Vec2(cosf(a), sinf(a)) * -1), 1, k)
            }
        }
    }

    func lampPositions(chunkKey key: Int) -> [Vec2] {
        return lampsByChunk[key] ?? []
    }

    // MARK: mesh emission

    private func atlas(_ cell: Int) -> (u: Float, v: Float) { return WTex.atlasCellUV(cell) }

    private func emit(_ p: WProp, _ set: WMeshSet, _ xf: WXform) {
        switch p.kind {
        case .lamp: emitLamp(set, xf)
        case .sign: emitSign(set, xf, p.variant)
        case .signal: emitSignal(set, xf, p.variant)
        case .bench: emitBench(set, xf)
        case .hydrant: emitHydrant(set, xf)
        case .bin: emitBin(set, xf)
        case .tree: break
        }
    }

    private func emitLamp(_ set: WMeshSet, _ xf: WXform) {
        let m = set.mesh(mats.props)
        let c0 = atlas(0)
        let c1 = atlas(1)
        let c2 = atlas(2)
        m.box(center: Vec3(0, 0.25, 0), size: Vec3(0.34, 0.5, 0.34), u: c1.u, v: c1.v, xf: xf)
        m.cylinder(base: Vec3(0, 0.5, 0), radiusBottom: 0.10, radiusTop: 0.065, height: 7.7, segments: 8, u: c0.u, v: c0.v, capTop: false, xf: xf)
        m.box(center: Vec3(0, 8.15, 1.1), size: Vec3(0.09, 0.09, 2.3), u: c0.u, v: c0.v, xf: xf)
        m.box(center: Vec3(0, 8.12, 2.35), size: Vec3(0.42, 0.12, 0.95), u: c1.u, v: c1.v, xf: xf)
        let y: Float = 8.05
        let hw: Float = 0.17
        let z0: Float = 1.95
        let z1: Float = 2.75
        m.quad(xf.p(Vec3(-hw, y, z0)), xf.p(Vec3(hw, y, z0)), xf.p(Vec3(hw, y, z1)), xf.p(Vec3(-hw, y, z1)), xf.n(Vec3(0, -1, 0)), c2.u, c2.v, c2.u, c2.v)
    }

    private func emitSign(_ set: WMeshSet, _ xf: WXform, _ kind: Int) {
        let m = set.mesh(mats.props)
        let c0 = atlas(0)
        let c7 = atlas(7)
        m.cylinder(base: Vec3(0, 0, 0), radiusBottom: 0.045, radiusTop: 0.045, height: 2.95, segments: 6, u: c0.u, v: c0.v, capTop: true, xf: xf)
        let r = WTex.atlasCellRect(16 + ((kind % 8) + 8) % 8)
        let z: Float = 0.06
        m.quad(xf.p(Vec3(-0.4, 2.15, z)), xf.p(Vec3(0.4, 2.15, z)), xf.p(Vec3(0.4, 2.95, z)), xf.p(Vec3(-0.4, 2.95, z)),
               xf.n(Vec3(0, 0, 1)), r.u0, r.v0, r.u1, r.v1)
        m.quad(xf.p(Vec3(-0.4, 2.15, z - 0.01)), xf.p(Vec3(0.4, 2.15, z - 0.01)), xf.p(Vec3(0.4, 2.95, z - 0.01)), xf.p(Vec3(-0.4, 2.95, z - 0.01)),
               xf.n(Vec3(0, 0, -1)), c7.u, c7.v, c7.u, c7.v)
    }

    private func emitSignal(_ set: WMeshSet, _ xf: WXform, _ variant: Int) {
        let m = set.mesh(mats.signal)
        let c0 = atlas(0)
        let c8 = atlas(8)
        m.cylinder(base: Vec3(0, 0, 0), radiusBottom: 0.09, radiusTop: 0.07, height: 4.6, segments: 8, u: c0.u, v: c0.v, capTop: true, xf: xf)
        m.box(center: Vec3(0, 4.35, 0.2), size: Vec3(0.34, 1.05, 0.3), u: c8.u, v: c8.v, xf: xf)
        let lit: Int = ((variant % 3) + 3) % 3
        let cells: [Int] = [9, 10, 11]
        let ys: [Float] = [4.7, 4.35, 4.0]
        let z: Float = 0.36
        for i in 0..<3 {
            let cell: Int = (i == lit) ? cells[i] : 8
            let uv = atlas(cell)
            let y: Float = ys[i]
            m.quad(xf.p(Vec3(-0.11, y - 0.11, z)), xf.p(Vec3(0.11, y - 0.11, z)), xf.p(Vec3(0.11, y + 0.11, z)), xf.p(Vec3(-0.11, y + 0.11, z)),
                   xf.n(Vec3(0, 0, 1)), uv.u, uv.v, uv.u, uv.v)
        }
    }

    private func emitHydrant(_ set: WMeshSet, _ xf: WXform) {
        let body = set.mesh(hydrantMat)
        let cap = set.mesh(hydrantCapMat)
        body.cylinder(base: Vec3(0, 0, 0), radiusBottom: 0.17, radiusTop: 0.15, height: 0.62, segments: 8, u: 0.5, v: 0.5, capTop: true, xf: xf)
        body.box(center: Vec3(0.20, 0.42, 0), size: Vec3(0.16, 0.13, 0.13), u: 0.5, v: 0.5, xf: xf)
        body.box(center: Vec3(-0.20, 0.42, 0), size: Vec3(0.16, 0.13, 0.13), u: 0.5, v: 0.5, xf: xf)
        cap.cylinder(base: Vec3(0, 0.62, 0), radiusBottom: 0.19, radiusTop: 0.10, height: 0.12, segments: 8, u: 0.5, v: 0.5, capTop: true, xf: xf)
        cap.box(center: Vec3(0, 0.25, 0.17), size: Vec3(0.12, 0.12, 0.06), u: 0.5, v: 0.5, xf: xf)
    }

    private func emitBin(_ set: WMeshSet, _ xf: WXform) {
        let body = set.mesh(binMat)
        let lid = set.mesh(binLidMat)
        body.cylinder(base: Vec3(0, 0, 0), radiusBottom: 0.27, radiusTop: 0.31, height: 0.9, segments: 10, u: 0.5, v: 0.5, capTop: false, xf: xf)
        lid.cylinder(base: Vec3(0, 0.9, 0), radiusBottom: 0.33, radiusTop: 0.29, height: 0.09, segments: 10, u: 0.5, v: 0.5, capTop: true, xf: xf)
    }

    private func emitBench(_ set: WMeshSet, _ xf: WXform) {
        let m = set.mesh(mats.propsDead)
        let wood = atlas(3)
        let metal = atlas(0)
        m.box(center: Vec3(0, 0.46, 0), size: Vec3(1.8, 0.07, 0.5), u: wood.u, v: wood.v, xf: xf)
        m.box(center: Vec3(0, 0.78, -0.22), size: Vec3(1.8, 0.4, 0.06), u: wood.u, v: wood.v, xf: xf)
        m.box(center: Vec3(-0.8, 0.22, 0), size: Vec3(0.08, 0.44, 0.44), u: metal.u, v: metal.v, xf: xf)
        m.box(center: Vec3(0.8, 0.22, 0), size: Vec3(0.08, 0.44, 0.44), u: metal.u, v: metal.v, xf: xf)
    }

    private func mergedGeometry(chunk key: Int) -> SCNGeometry? {
        guard let list = byChunk[key] else { return nil }
        let set = WMeshSet()
        for i in list {
            let p: WProp = props[i]
            if !p.alive || p.kind == WPropKind.tree { continue }
            let xf = WXform(x: p.pos.x, y: 0, z: p.pos.y, heading: p.heading, scale: p.scale)
            emit(p, set, xf)
        }
        return set.makeGeometry()
    }

    // MARK: chunk content (called by World while building a chunk)

    func makeChunkContent(key: Int, chunkNode: SCNNode) {
        guard let list = byChunk[key] else { return }
        let node = SCNNode()
        node.name = "props"
        node.geometry = mergedGeometry(chunk: key)
        node.castsShadow = true
        chunkNode.addChildNode(node)
        chunkPropNodes[key] = node
        for i in list where props[i].kind == WPropKind.tree {
            let inst = WTreeInstance(propIndex: i)
            let p: WProp = props[i]
            inst.container.simdPosition = Vec3(p.pos.x, 0, p.pos.y)
            inst.holder.simdEulerAngles = Vec3(0, p.heading, 0)
            inst.holder.simdScale = Vec3(p.scale, p.scale, p.scale)
            inst.container.addChildNode(inst.holder)
            chunkNode.addChildNode(inst.container)
            trees[i] = inst
            treeList.append(inst)
            setLOD(inst, 2)
        }
    }

    // MARK: endless world: copies of a source chunk's props at an offset (one clone chunk = one entry of `byChunk`)

    /// Re-creates the props of base chunk `sourceKey` shifted by `offset` inside `chunkNode` (world coordinates, chunk node at the origin):
    /// merged lamp / sign / bench geometry, individual tree nodes with LOD, and destructible colliders.
    func makeCloneProps(sourceKey: Int, offset: Vec2, cloneKey: Int, chunkNode: SCNNode) {
        guard let list = byChunk[sourceKey] else { return }
        var made: [Int] = []
        for si in list {
            let src: WProp = props[si]
            let pos: Vec2 = src.pos + offset
            let cid: Int = makeCollider(src.kind, pos, src.heading, src.scale)
            let p = WProp(id: 0, kind: src.kind, pos: pos, heading: src.heading, scale: src.scale, variant: src.variant, alive: true, colliderID: cid, chunk: cloneKey)
            var idx: Int
            if let f = freeProps.popLast() {
                idx = f
                var q: WProp = p
                q.id = idx
                props[idx] = q
            } else {
                idx = props.count
                var q: WProp = p
                q.id = idx
                props.append(q)
            }
            propByCollider[cid] = idx
            made.append(idx)
        }
        byChunk[cloneKey] = made
        let node = SCNNode()
        node.name = "props"
        node.geometry = mergedGeometry(chunk: cloneKey)
        node.castsShadow = true
        chunkNode.addChildNode(node)
        chunkPropNodes[cloneKey] = node
        for i in made where props[i].kind == WPropKind.tree {
            let inst = WTreeInstance(propIndex: i)
            let p: WProp = props[i]
            inst.container.simdPosition = Vec3(p.pos.x, 0, p.pos.y)
            inst.holder.simdEulerAngles = Vec3(0, p.heading, 0)
            inst.holder.simdScale = Vec3(p.scale, p.scale, p.scale)
            inst.container.addChildNode(inst.holder)
            chunkNode.addChildNode(inst.container)
            trees[i] = inst
            treeList.append(inst)
            setLOD(inst, 2)
        }
    }

    /// removes a clone chunk's colliders and bookkeeping (its node is removed by the caller)
    func releaseCloneProps(cloneKey: Int) {
        guard let list = byChunk[cloneKey] else { return }
        var gone = Set<Int>()
        for i in list {
            let p: WProp = props[i]
            if p.colliderID >= 0 {
                colliders.remove(id: p.colliderID)
                propByCollider[p.colliderID] = nil
            }
            props[i].alive = false
            props[i].colliderID = -1
            if trees[i] != nil {
                trees[i] = nil
                gone.insert(i)
            }
            freeProps.append(i)
        }
        if !gone.isEmpty { treeList.removeAll(where: { gone.contains($0.propIndex) }) }
        byChunk[cloneKey] = nil
        chunkPropNodes[cloneKey] = nil
    }

    // MARK: tree LOD

    private func setLOD(_ t: WTreeInstance, _ lod: Int) {
        if t.current == lod { return }
        if !hasTreeModels { return }
        if t.lods[lod] == nil {
            do {
                let n: SCNNode = try ctx.assets.model(lodNames[lod])
                let casts: Bool = lod < 2
                n.enumerateHierarchy { (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
                    child.castsShadow = casts
                }
                t.holder.addChildNode(n)
                t.lods[lod] = n
            } catch {
                if lod == 2 { hasTreeModels = false }
                return
            }
        }
        for i in 0..<3 { t.lods[i]?.isHidden = (i != lod) }
        t.current = lod
    }

    func update(dt: Float, focus: Vec3) {
        lodTimer -= dt
        if lodTimer > 0 { return }
        lodTimer = 0.25
        let d0: Float = 45 * treeDetailFactor
        let d1: Float = 140 * treeDetailFactor
        let f2 = Vec2(focus.x, focus.z)
        for t in treeList {
            let p: Vec2 = props[t.propIndex].pos
            let d: Float = simd_length(p - f2)
            var lod = 2
            if d < d0 { lod = 0 } else if d < d1 { lod = 1 }
            if d > 260 && t.current == 2 { continue }
            setLOD(t, lod)
        }
    }

    // MARK: destruction

    func worldStrike(collider: Collider, speed: Float, direction: Vec2) {
        guard let pi = propByCollider[collider.id] else { return }
        propByCollider[collider.id] = nil
        props[pi].alive = false
        let p: WProp = props[pi]
        var dir: Vec2 = direction.normalizedSafe
        if dir.x == 0 && dir.y == 0 { dir = headingForward2(p.heading) }
        let pos3 = Vec3(p.pos.x, 0, p.pos.y)
        let angle: Float = Float.pi * 0.5 * clampf(0.55 + speed / 26, 0.55, 0.97)
        switch p.kind {
        case .lamp:
            rebuildChunk(p.chunk)
            let node = debrisNode(for: p)
            topple(node, at: pos3, dir: dir, angle: angle, duration: 0.75, keep: 14)
            ctx.audio.play(SFX.lampBend, volume: 0.9, rate: 1, position: pos3)
            delayedSound(SFX.lampFall, after: 0.55, position: pos3, volume: 1.0)
            spawnDust(at: pos3 + Vec3(0, 0.3, 0), amount: 0.6)
        case .sign:
            rebuildChunk(p.chunk)
            let node = debrisNode(for: p)
            topple(node, at: pos3, dir: dir, angle: Float.pi * 0.5 * 0.96, duration: 0.45, keep: 12)
            ctx.audio.play(SFX.signClang, volume: 0.9, rate: 1, position: pos3)
            spawnDust(at: pos3 + Vec3(0, 0.2, 0), amount: 0.4)
        case .tree:
            if let inst = trees[pi] {
                trees[pi] = nil
                treeList.removeAll { $0 === inst }
                let container: SCNNode = inst.container
                let axis = SCNVector3(dir.y, 0, -dir.x)
                let fall = SCNAction.rotate(by: CGFloat(angle), around: axis, duration: 1.15)
                fall.timingMode = SCNActionTimingMode.easeIn
                container.runAction(SCNAction.sequence([fall, SCNAction.wait(duration: 16), SCNAction.fadeOut(duration: 1.5), SCNAction.removeFromParentNode()]))
            }
            ctx.audio.play(SFX.treeCrack, volume: 1.0, rate: 1, position: pos3)
            delayedSound(SFX.treeFall, after: 0.6, position: pos3, volume: 1.0)
            delayedSound(SFX.leavesRustle, after: 0.9, position: pos3, volume: 0.8)
            spawnDust(at: pos3 + Vec3(0, 0.5, 0), amount: 1.0)
        default:
            break
        }
    }

    private func rebuildChunk(_ key: Int) {
        chunkPropNodes[key]?.geometry = mergedGeometry(chunk: key)
    }

    private func debrisNode(for p: WProp) -> SCNNode {
        let set = WMeshSet()
        emit(p, set, WXform(x: 0, y: 0, z: 0, heading: p.heading, scale: p.scale))
        let n = SCNNode()
        n.geometry = set.makeGeometry()
        n.castsShadow = true
        return n
    }

    private func topple(_ debris: SCNNode, at pos: Vec3, dir: Vec2, angle: Float, duration: Double, keep: Double) {
        guard let root = worldRoot else { return }
        let container = SCNNode()
        container.simdPosition = pos
        container.addChildNode(debris)
        root.addChildNode(container)
        let axis = SCNVector3(dir.y, 0, -dir.x)
        let fall = SCNAction.rotate(by: CGFloat(angle), around: axis, duration: duration)
        fall.timingMode = SCNActionTimingMode.easeIn
        container.runAction(SCNAction.sequence([fall, SCNAction.wait(duration: keep), SCNAction.fadeOut(duration: 1.2), SCNAction.removeFromParentNode()]))
    }

    private func delayedSound(_ sfx: SFX, after seconds: Double, position: Vec3, volume: Float) {
        Task { @MainActor [weak self] in
            let ns: UInt64 = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            self?.ctx.audio.play(sfx, volume: volume, rate: 1, position: position)
        }
    }

    private func softDot() -> UIImage {
        if let d = dustImage { return d }
        let img = WTex.render(32, 32, opaque: false) { c in
            c.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
            WTex.radial(c, center: CGPoint(x: 16, y: 16), radius: 16, stops: [(0, WTex.col(1, 1, 1, 0.9)), (1, WTex.col(1, 1, 1, 0))])
        }
        dustImage = img
        return img
    }

    private func spawnDust(at pos: Vec3, amount: Float) {
        if !particlesOn { return }
        guard let root = worldRoot else { return }
        let ps = SCNParticleSystem()
        ps.particleImage = softDot()
        ps.birthRate = CGFloat(120 * amount)
        ps.emissionDuration = 0.25
        ps.loops = false
        ps.particleLifeSpan = 1.4
        ps.particleLifeSpanVariation = 0.5
        ps.particleVelocity = 3.2
        ps.particleVelocityVariation = 2.0
        ps.spreadingAngle = 80
        ps.particleSize = CGFloat(0.5 + 0.3 * amount)
        ps.particleSizeVariation = 0.3
        ps.particleColor = UIColor(red: 0.62, green: 0.56, blue: 0.46, alpha: 0.55)
        ps.blendMode = SCNParticleBlendMode.alpha
        ps.acceleration = SCNVector3(0, 0.5, 0)
        ps.isLightingEnabled = false
        let node = SCNNode()
        node.simdPosition = pos
        node.addParticleSystem(ps)
        root.addChildNode(node)
        node.runAction(SCNAction.sequence([SCNAction.wait(duration: 3), SCNAction.removeFromParentNode()]))
    }
}
