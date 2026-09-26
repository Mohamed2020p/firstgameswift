import Foundation
import SceneKit
import UIKit
import Combine
import simd

// MARK: - World: the whole open city (roads, buildings, props, sky, day cycle, colliders). Implements the contract in docs/ARCHITECTURE.md.

@MainActor
final class WChunk {
    let key: Int
    let rect: WRect
    let node = SCNNode()
    init(key: Int, rect: WRect) {
        self.key = key
        self.rect = rect
    }
    var center: Vec2 { return rect.center }
}

@MainActor
final class World {
    let root = SCNNode()
    let colliders = ColliderWorld()
    var sun: SCNNode { return sky.sunLight }
    private(set) var spawn: SpawnPoints
    private(set) var raceRoutes: [RaceRoute] = []
    var timeOfDay: Float = 9

    private unowned let ctx: GameContext
    private let layout = WCityLayout()
    private let mats = WorldMaterials()
    private let sky: WSky
    private var buildings: WBuildingBuilder!
    private var propSystem: WPropSystem!
    private var roadBuilder: WRoadBuilder!
    private var chunks: [WChunk] = []
    private var minimapData = MinimapData()
    private var interior = false
    private var visTimer: Float = 0
    private var lastVisFocus = Vec2(1e9, 1e9)
    private var cancellables = Set<AnyCancellable>()
    private var built = false

    init(ctx: GameContext) {
        self.ctx = ctx
        let z = Spawn(position: Vec3(0, 0, 0), heading: 0)
        spawn = SpawnPoints(houseDoor: z, car: z, player: z, garageDoor: z, raceGate: z, house: z)
        sky = WSky(scene: ctx.scene)
        root.name = "world"
        ctx.settings.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self = self else { return }
                self.applyGraphics(s.graphics)
            }
            .store(in: &cancellables)
    }

    private func applyGraphics(_ g: GraphicsSettings) {
        sky.applyGraphics(g)
        propSystem?.applyGraphics(g)
        lastVisFocus = Vec2(1e9, 1e9)
    }

    // MARK: build

    func build(progress: @escaping (Float, String) -> Void) async {
        if built { return }
        built = true
        ctx.scene.rootNode.addChildNode(root)
        sky.attach()
        sky.applyGraphics(ctx.settings.settings.graphics)

        progress(0.02, "Painting the streets…")
        mats.makeGroundAndRoads()
        await Task.yield()
        progress(0.06, "Designing facades…")
        mats.makeFacades()
        await Task.yield()
        mats.makeProps()
        await Task.yield()

        progress(0.12, "Loading buildings and trees…")
        await ctx.assets.preload(["tree_lod0", "tree_lod1", "tree_lod2"])
        buildings = WBuildingBuilder(mats: mats, layout: layout, colliders: colliders)
        let infos: [WBuildingInfo] = await buildings.loadModels(assets: ctx.assets)

        progress(0.2, "Laying out the city…")
        layout.generate(infos: infos)
        spawn = layout.spawn
        raceRoutes = layout.routes
        await Task.yield()

        propSystem = WPropSystem(ctx: ctx, layout: layout, mats: mats, colliders: colliders, worldRoot: root)
        propSystem.applyGraphics(ctx.settings.settings.graphics)
        propSystem.generate()
        roadBuilder = WRoadBuilder(layout: layout, mats: mats)
        await Task.yield()

        // static geometry, chunk by chunk
        let lo = -11
        let hi = 10
        let total: Float = Float((hi - lo + 1) * (hi - lo + 1))
        var done: Float = 0
        for cx in lo...hi {
            for cz in lo...hi {
                buildChunk(cx: cx, cz: cz)
                done += 1
                if Int(done) % 3 == 0 {
                    progress(0.25 + 0.68 * done / total, "Building the city… \(Int(done / total * 100))%")
                    await Task.yield()
                }
            }
        }

        progress(0.95, "Finishing touches…")
        buildFarGround()
        buildGate()
        buildMinimap()
        applyGraphics(ctx.settings.settings.graphics)
        sky.update(t: timeOfDay, focus: spawn.house.position, camera: spawn.house.position + Vec3(0, 3, 0), dt: 0)
        mats.setNight(sky.night)
        updateVisibility(focus: spawn.player.position, force: true)
        progress(1, "Ready")
    }

    // MARK: chunks

    private func addLayer(_ set: WMeshSet, to parent: SCNNode, order: Int, shadows: Bool, name: String) {
        guard let g = set.makeGeometry() else { return }
        let n = SCNNode(geometry: g)
        n.name = name
        n.renderingOrder = order
        n.castsShadow = shadows
        parent.addChildNode(n)
    }

    private func fillBlocks(_ rect: WRect, _ layers: inout WChunkLayers) {
        for b in layout.blocks where b.rect.overlaps(rect) {
            let x0: Float = max(b.rect.x0, rect.x0)
            let x1: Float = min(b.rect.x1, rect.x1)
            let z0: Float = max(b.rect.z0, rect.z0)
            let z1: Float = min(b.rect.z1, rect.z1)
            if x1 - x0 < 0.01 || z1 - z0 < 0.01 { continue }
            var mat: SCNMaterial = mats.pave
            switch b.kind {
            case .park, .residential: mat = mats.lawn
            case .plaza: mat = mats.plaza
            default: mat = mats.pave
            }
            layers.fill.mesh(mat).groundRect(x0, z0, x1, z1, y: 0.003, tile: 8)
        }
    }

    private func disc(_ m: WMesh, _ c: Vec2, _ r: Float, y: Float, tile: Float) {
        let segs = 32
        for i in 0..<segs {
            let a0: Float = Float(i) / Float(segs) * Float.tau
            let a1: Float = Float(i + 1) / Float(segs) * Float.tau
            let p0 = c + Vec2(cosf(a0), sinf(a0)) * r
            let p1 = c + Vec2(cosf(a1), sinf(a1)) * r
            m.groundQuad(c, p0, p1, c, y: y, tile: tile)
        }
    }

    private func ring(_ m: WMesh, _ c: Vec2, _ r0: Float, _ r1: Float, y: Float, tile: Float) {
        let segs = 32
        for i in 0..<segs {
            let a0: Float = Float(i) / Float(segs) * Float.tau
            let a1: Float = Float(i + 1) / Float(segs) * Float.tau
            let d0 = Vec2(cosf(a0), sinf(a0))
            let d1 = Vec2(cosf(a1), sinf(a1))
            m.groundQuad(c + d0 * r0, c + d1 * r0, c + d1 * r1, c + d0 * r1, y: y, tile: tile)
        }
    }

    private func wallRing(_ m: WMesh, _ c: Vec2, _ r: Float, _ y0: Float, _ y1: Float, outward: Bool) {
        let segs = 32
        for i in 0..<segs {
            let a0: Float = Float(i) / Float(segs) * Float.tau
            let a1: Float = Float(i + 1) / Float(segs) * Float.tau
            let d0 = Vec2(cosf(a0), sinf(a0))
            let d1 = Vec2(cosf(a1), sinf(a1))
            let q0 = c + d0 * r
            let q1 = c + d1 * r
            let mid = ((d0 + d1) * 0.5).normalizedSafe
            let nrm = outward ? Vec3(mid.x, 0, mid.y) : Vec3(-mid.x, 0, -mid.y)
            m.quad(Vec3(q0.x, y0, q0.y), Vec3(q1.x, y0, q1.y), Vec3(q1.x, y1, q1.y), Vec3(q0.x, y1, q0.y), nrm, 0, 0, 1, 1)
        }
    }

    /// plaza fountain and park pond
    private func decorate(_ rect: WRect, _ layers: inout WChunkLayers) {
        let pz = layout.plazaRect
        if pz.width > 10 && rect.containsInclusive(pz.center) {
            let c = pz.center
            disc(layers.fill.mesh(mats.water), c, 9.5, y: 0.12, tile: 6)
            ring(layers.flat.mesh(mats.curb), c, 9.5, 10.6, y: 0.5, tile: 2)
            wallRing(layers.flat.mesh(mats.curb), c, 10.6, 0, 0.5, outward: true)
            wallRing(layers.flat.mesh(mats.curb), c, 9.5, 0.12, 0.5, outward: false)
            disc(layers.flat.mesh(mats.curb), c, 1.6, y: 1.2, tile: 2)
            wallRing(layers.flat.mesh(mats.curb), c, 1.6, 0.1, 1.2, outward: true)
        }
        if let park = layout.parkRects.first, rect.containsInclusive(park.center) {
            disc(layers.fill.mesh(mats.water), park.center, 14, y: 0.02, tile: 6)
            ring(layers.fill.mesh(mats.dirtPath), park.center, 14, 16, y: 0.012, tile: 4)
        }
    }

    private func buildChunk(cx: Int, cz: Int) {
        let key: Int = wChunkKey(cx, cz)
        let rect = WRect(x0: Float(cx) * WC.chunk, z0: Float(cz) * WC.chunk, x1: Float(cx + 1) * WC.chunk, z1: Float(cz + 1) * WC.chunk)
        let chunk = WChunk(key: key, rect: rect)
        chunk.node.name = "chunk_\(cx)_\(cz)"
        var layers = WChunkLayers()
        layers.fill.mesh(mats.ground).groundRect(rect.x0, rect.z0, rect.x1, rect.z1, y: 0, tile: 24)
        fillBlocks(rect, &layers)
        decorate(rect, &layers)
        let lamps: [Vec2] = propSystem.lampPositions(chunkKey: key)
        roadBuilder.build(rect: rect, lamps: lamps, layers: &layers)
        addLayer(layers.fill, to: chunk.node, order: -60, shadows: false, name: "fill")
        addLayer(layers.flat, to: chunk.node, order: -50, shadows: false, name: "flat")
        addLayer(layers.asphalt, to: chunk.node, order: -40, shadows: false, name: "asphalt")
        addLayer(layers.paint, to: chunk.node, order: -30, shadows: false, name: "paint")
        addLayer(layers.decals, to: chunk.node, order: -20, shadows: false, name: "decals")

        let bset = WMeshSet()
        buildings.build(chunkKey: key, into: bset)
        addLayer(bset, to: chunk.node, order: 0, shadows: true, name: "buildings")
        propSystem.makeChunkContent(key: key, chunkNode: chunk.node)
        root.addChildNode(chunk.node)
        chunks.append(chunk)
    }

    private func buildFarGround() {
        let set = WMeshSet()
        set.mesh(mats.ground).groundRect(-7000, -7000, 7000, 7000, y: -0.06, tile: 24)
        addLayer(set, to: root, order: -70, shadows: false, name: "farGround")
    }

    // MARK: race gate

    private func gateBanner() -> UIImage {
        return WTex.render(1024, 128, opaque: true) { c in
            c.setFillColor(WTex.col(0.02, 0.03, 0.05))
            c.fill(CGRect(x: 0, y: 0, width: 1024, height: 128))
            c.setFillColor(WTex.col(0.22, 1.0, 0.53))
            c.fill(CGRect(x: 0, y: 0, width: 1024, height: 8))
            c.setFillColor(WTex.col(1.0, 0.17, 0.84))
            c.fill(CGRect(x: 0, y: 120, width: 1024, height: 8))
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 74, weight: UIFont.Weight.heavy),
                .foregroundColor: UIColor(red: 0.22, green: 1.0, blue: 0.53, alpha: 1),
                .paragraphStyle: para
            ]
            ("SUPERCARS GP  •  c0derz" as NSString).draw(in: CGRect(x: 0, y: 22, width: 1024, height: 92), withAttributes: attrs)
        }
    }

    private func checkerImage() -> UIImage {
        return WTex.render(256, 32, opaque: true) { c in
            for i in 0..<16 {
                for j in 0..<2 {
                    let dark: Bool = (i + j) % 2 == 0
                    c.setFillColor(dark ? WTex.col(0.05, 0.05, 0.05) : WTex.col(0.95, 0.95, 0.95))
                    c.fill(CGRect(x: i * 16, y: j * 16, width: 16, height: 16))
                }
            }
        }
    }

    private func buildGate() {
        guard let route = raceRoutes.first else { return }
        let g = spawn.raceGate
        let w: Float = route.width
        let holder = SCNNode()
        holder.name = "raceGate"
        holder.simdPosition = g.position
        holder.simdEulerAngles = Vec3(0, g.heading, 0)

        let pillarMat: SCNMaterial = MaterialFactory.pbr(color: UIColor(white: 0.16, alpha: 1), metalness: 0.4, roughness: 0.5, name: "gatePillar")
        let banner: UIImage = gateBanner()
        let bannerMat: SCNMaterial = MaterialFactory.texturedEmissive(banner, emission: banner, emissionIntensity: 0.65, metalness: 0, roughness: 0.6, name: "gateBanner")
        let side: Float = w * 0.5 + 1.6
        for sx in [Float(-1), Float(1)] {
            let box = SCNBox(width: 0.9, height: 8, length: 0.9, chamferRadius: 0.05)
            box.materials = [pillarMat]
            let n = SCNNode(geometry: box)
            n.simdPosition = Vec3(sx * side, 4, 0)
            holder.addChildNode(n)
            let cid: Int = colliders.allocateID()
            let world = Vec3(g.position.x, 0, g.position.z) + headingLeft(g.heading) * (sx * side)
            colliders.add(Collider.circle(id: cid, kind: ColliderKind.prop, center: Vec2(world.x, world.z), radius: 0.7, destructible: false, height: 8, mass: 100000))
        }
        let beam = SCNBox(width: CGFloat(side * 2 + 0.9), height: 1.6, length: 0.8, chamferRadius: 0.05)
        beam.materials = [bannerMat, pillarMat, bannerMat, pillarMat, pillarMat, pillarMat]
        let beamNode = SCNNode(geometry: beam)
        beamNode.simdPosition = Vec3(0, 8.3, 0)
        holder.addChildNode(beamNode)
        root.addChildNode(holder)

        // start / finish checker line
        let set = WMeshSet()
        let checker = SCNMaterial()
        checker.lightingModel = SCNMaterial.LightingModel.lambert
        checker.diffuse.contents = checkerImage()
        checker.diffuse.wrapS = SCNWrapMode.repeat
        checker.diffuse.wrapT = SCNWrapMode.repeat
        checker.readsFromDepthBuffer = true
        checker.writesToDepthBuffer = false
        let xf = WXform(x: g.position.x, y: 0, z: g.position.z, heading: g.heading, scale: 1)
        let m = set.mesh(checker)
        let hw: Float = w * 0.5
        m.quad(xf.p(Vec3(-hw, 0.05, -1.0)), xf.p(Vec3(hw, 0.05, -1.0)), xf.p(Vec3(hw, 0.05, 1.0)), xf.p(Vec3(-hw, 0.05, 1.0)),
               Vec3(0, 1, 0), 0, 0, 1, 1)
        addLayer(set, to: root, order: -15, shadows: false, name: "startLine")
    }

    // MARK: minimap

    private func buildMinimap() {
        var mm = MinimapData()
        mm.boundsMin = Vec2(-1500, -1500)
        mm.boundsMax = Vec2(1500, 1500)
        var lines: [[Vec2]] = []
        for r in layout.roads {
            var pts: [Vec2] = r.points
            if pts.count > 90 {
                let step: Int = pts.count / 80 + 1
                var thin: [Vec2] = []
                var i = 0
                while i < pts.count {
                    thin.append(pts[i])
                    i += step
                }
                if r.closed, let f = thin.first { thin.append(f) }
                pts = thin
            } else if r.closed, let f = pts.first {
                pts.append(f)
            }
            lines.append(pts)
        }
        mm.roads = lines
        if let route = raceRoutes.first {
            var pts: [Vec2] = []
            var i = 0
            let step: Int = max(1, route.points.count / 120)
            while i < route.points.count {
                pts.append(route.points[i])
                i += step
            }
            if let f = pts.first { pts.append(f) }
            mm.route = pts
        }
        minimapData = mm
    }

    func minimap() -> MinimapData { return minimapData }

    // MARK: per frame

    func update(dt: Float, focus: Vec3) {
        let dayLen: Float = max(2, ctx.settings.settings.gameplay.dayLengthMinutes)
        timeOfDay += dt * 24 / (dayLen * 60)
        if timeOfDay >= 24 { timeOfDay -= 24 }
        if timeOfDay < 0 { timeOfDay += 24 }
        let cam: Vec3 = ctx.cameraRig.node.simdPosition
        sky.update(t: timeOfDay, focus: focus, camera: cam, dt: dt)
        mats.setNight(sky.night)
        mats.setBeacon(sky.night > 0.4)
        propSystem.update(dt: dt, focus: focus)
        visTimer -= dt
        if visTimer <= 0 {
            visTimer = 0.4
            updateVisibility(focus: focus, force: false)
        }
    }

    private func updateVisibility(focus: Vec3, force: Bool) {
        let f = Vec2(focus.x, focus.z)
        if !force && simd_length(f - lastVisFocus) < 12 { return }
        lastVisFocus = f
        let dd: Float = ctx.settings.settings.graphics.drawDistance
        var radius: Float = 430 * dd
        if interior { radius = 85 }
        let limit: Float = radius + WC.chunk * 0.75
        for c in chunks {
            let hidden: Bool = simd_length(c.center - f) > limit
            if c.node.isHidden != hidden { c.node.isHidden = hidden }
        }
    }

    func setInteriorMode(_ on: Bool) {
        if interior == on { return }
        interior = on
        lastVisFocus = Vec2(1e9, 1e9)
    }

    // MARK: queries

    func surface(at p: Vec2) -> SurfaceType { return layout.surface(at: p) }

    func groundHeight(at p: Vec2) -> Float { return 0 }

    func nearestRoadPoint(to p: Vec2) -> (point: Vec2, heading: Float)? {
        guard let hit = layout.index.nearest(p, maxDist: 80) else { return nil }
        return (hit.point, headingOf(hit.dir))
    }
}
