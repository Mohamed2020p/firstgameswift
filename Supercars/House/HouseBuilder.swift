import Foundation
import SceneKit
import UIKit
import simd

// MARK: - Geometry of the player's house: modern villa + attached garage, interior rooms, furniture, c0derz murals.
// Everything is authored in PLOT-LOCAL coordinates (x = left, z = forward toward the road, y up) and parented under a root node that is
// placed at the plot centre with the plot heading. Static pieces are merged per material (WMeshSet) so the whole house is a handful of
// draw calls.  Colliders are registered in world space through `worldPoint`.

@MainActor
final class HouseMaterials {
    let plaster: SCNMaterial
    let plasterDark: SCNMaterial
    let cladding: SCNMaterial
    let woodFloor: SCNMaterial
    let woodDark: SCNMaterial
    let woodWarm: SCNMaterial
    let tile: SCNMaterial
    let epoxy: SCNMaterial
    let ceiling: SCNMaterial
    let fabric: SCNMaterial
    let fabricAccent: SCNMaterial
    let sheet: SCNMaterial
    let blanket: SCNMaterial
    let leather: SCNMaterial
    let metal: SCNMaterial
    let black: SCNMaterial
    let counter: SCNMaterial
    let cabinet: SCNMaterial
    let hedge: SCNMaterial
    let lawn: SCNMaterial
    let driveway: SCNMaterial
    let rug: SCNMaterial
    let safety: SCNMaterial
    let glassExterior: SCNMaterial
    let windowView: SCNMaterial
    let neonGreen: SCNMaterial
    let neonMagenta: SCNMaterial
    let neonWhite: SCNMaterial
    let neonCyan: SCNMaterial
    let muralLiving: SCNMaterial
    let muralOffice: SCNMaterial
    let muralGarage: SCNMaterial
    let muralExterior: SCNMaterial
    let muralBedroom: SCNMaterial
    let signMat: SCNMaterial
    let posterA: SCNMaterial
    let posterB: SCNMaterial
    let garageDoor: SCNMaterial
    let tvScreen: SCNMaterial
    let codeScreen: SCNMaterial

    private static func flat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ name: String) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.lambert
        m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
        return m
    }

    private static func textured(_ img: UIImage, _ name: String, tint: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.lambert
        MaterialFactory.setTexture(m.diffuse, img, repeating: true)
        m.diffuse.intensity = tint
        return m
    }

    private static func neon(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ name: String, intensity: CGFloat = 1.2) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.constant
        let c = UIColor(red: r, green: g, blue: b, alpha: 1)
        m.diffuse.contents = c
        m.emission.contents = c
        m.emission.intensity = intensity
        return m
    }

    private static func artMaterial(_ img: UIImage, _ name: String, glow: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.lambert
        m.diffuse.contents = img
        m.diffuse.wrapS = SCNWrapMode.clamp
        m.diffuse.wrapT = SCNWrapMode.clamp
        m.emission.contents = img
        m.emission.intensity = glow
        m.emission.wrapS = SCNWrapMode.clamp
        m.emission.wrapT = SCNWrapMode.clamp
        return m
    }

    init() {
        plaster = HouseMaterials.flat(0.93, 0.93, 0.91, "plaster")
        plasterDark = HouseMaterials.flat(0.15, 0.16, 0.18, "plasterDark")
        cladding = HouseMaterials.flat(0.09, 0.10, 0.12, "cladding")
        woodFloor = HouseMaterials.textured(ProceduralTextures.woodFloor(size: 512, planks: 6, seed: 61), "woodFloor")
        woodDark = HouseMaterials.flat(0.20, 0.13, 0.08, "woodDark")
        woodWarm = HouseMaterials.flat(0.55, 0.36, 0.20, "woodWarm")
        tile = HouseMaterials.textured(ProceduralTextures.concreteTiles(size: 512, tiles: 4, seed: 23), "tile", tint: 1.35)
        epoxy = HouseMaterials.textured(ProceduralTextures.concreteTiles(size: 512, tiles: 2, seed: 77), "epoxy", tint: 0.9)
        ceiling = HouseMaterials.flat(0.96, 0.96, 0.96, "ceiling")
        fabric = HouseMaterials.flat(0.22, 0.25, 0.31, "fabric")
        fabricAccent = HouseMaterials.flat(0.07, 0.40, 0.32, "fabricAccent")
        sheet = HouseMaterials.flat(0.92, 0.92, 0.94, "sheet")
        blanket = HouseMaterials.flat(0.32, 0.09, 0.42, "blanket")
        leather = HouseMaterials.flat(0.05, 0.05, 0.06, "leather")
        metal = HouseMaterials.flat(0.62, 0.64, 0.68, "metal")
        black = HouseMaterials.flat(0.02, 0.02, 0.03, "black")
        counter = HouseMaterials.flat(0.86, 0.86, 0.84, "counter")
        cabinet = HouseMaterials.flat(0.15, 0.16, 0.19, "cabinet")
        hedge = HouseMaterials.flat(0.09, 0.28, 0.11, "hedge")
        lawn = HouseMaterials.textured(ProceduralTextures.grass(size: 512, seed: 51), "houseLawn")
        driveway = HouseMaterials.textured(ProceduralTextures.concreteTiles(size: 512, tiles: 4, seed: 21), "driveway", tint: 1.2)
        rug = HouseMaterials.flat(0.13, 0.05, 0.20, "rug")
        safety = HouseMaterials.flat(0.92, 0.75, 0.05, "safety")

        let gm = SCNMaterial()
        gm.name = "houseGlass"
        gm.lightingModel = SCNMaterial.LightingModel.blinn
        gm.diffuse.contents = UIColor(red: 0.04, green: 0.08, blue: 0.13, alpha: 1)
        gm.specular.contents = UIColor(white: 0.9, alpha: 1)
        gm.shininess = 0.9
        gm.emission.contents = UIColor(red: 1.0, green: 0.74, blue: 0.42, alpha: 1)
        gm.emission.intensity = 0
        glassExterior = gm

        let wv = SCNMaterial()
        wv.name = "windowView"
        wv.lightingModel = SCNMaterial.LightingModel.constant
        wv.diffuse.contents = UIColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1)
        windowView = wv

        neonGreen = HouseMaterials.neon(0.22, 1.0, 0.53, "neonGreen")
        neonMagenta = HouseMaterials.neon(1.0, 0.17, 0.84, "neonMagenta")
        neonWhite = HouseMaterials.neon(0.95, 0.97, 1.0, "neonWhite", intensity: 1.0)
        neonCyan = HouseMaterials.neon(0.17, 0.9, 1.0, "neonCyan")

        muralLiving = HouseMaterials.artMaterial(C0derzArt.mural(width: 1024, height: 512, seed: 1), "muralLiving", glow: 0.75)
        muralOffice = HouseMaterials.artMaterial(C0derzArt.mural(width: 1024, height: 400, seed: 2), "muralOffice", glow: 0.8)
        muralGarage = HouseMaterials.artMaterial(C0derzArt.mural(width: 1024, height: 400, seed: 3), "muralGarage", glow: 0.8)
        muralExterior = HouseMaterials.artMaterial(C0derzArt.mural(width: 1024, height: 384, seed: 4), "muralExterior", glow: 0.7)
        muralBedroom = HouseMaterials.artMaterial(C0derzArt.mural(width: 768, height: 512, seed: 5), "muralBedroom", glow: 0.7)
        signMat = HouseMaterials.artMaterial(C0derzArt.sign(width: 512, height: 128), "houseSign", glow: 1.3)
        posterA = HouseMaterials.artMaterial(C0derzArt.poster(seed: 1, text: "V16"), "posterA", glow: 0.4)
        posterB = HouseMaterials.artMaterial(C0derzArt.poster(seed: 3, text: "GT3"), "posterB", glow: 0.4)

        let gd = SCNMaterial()
        gd.name = "garageDoor"
        gd.lightingModel = SCNMaterial.LightingModel.lambert
        gd.diffuse.contents = HouseMaterials.garageDoorImage()
        garageDoor = gd

        let tv = SCNMaterial()
        tv.name = "tv"
        tv.lightingModel = SCNMaterial.LightingModel.constant
        tv.diffuse.contents = C0derzArt.tvScreen()
        tvScreen = tv

        let cs = SCNMaterial()
        cs.name = "codeScreen"
        cs.lightingModel = SCNMaterial.LightingModel.constant
        let code = C0derzArt.codeScreen(seed: 1)
        cs.diffuse.contents = code
        cs.diffuse.wrapT = SCNWrapMode.repeat
        cs.diffuse.wrapS = SCNWrapMode.repeat
        codeScreen = cs
    }

    static func garageDoorImage() -> UIImage {
        return WTex.render(64, 256, opaque: true) { c in
            c.setFillColor(WTex.col(0.62, 0.64, 0.68))
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 256))
            for i in 0..<5 {
                let y: CGFloat = CGFloat(i) * 51.2
                c.setFillColor(WTex.col(0.30, 0.31, 0.34))
                c.fill(CGRect(x: 0, y: y, width: 64, height: 4))
                c.setFillColor(WTex.col(0.75, 0.77, 0.80))
                c.fill(CGRect(x: 0, y: y + 5, width: 64, height: 2))
            }
            c.setFillColor(WTex.col(0.22, 1.0, 0.53))
            c.fill(CGRect(x: 0, y: 249, width: 64, height: 6))
        }
    }
}

struct HousePlan {
    // outer shell of the villa (plot local)
    static let vx0: Float = -15
    static let vx1: Float = 6
    static let vz0: Float = -12
    static let vz1: Float = 8
    static let ceilingH: Float = 3.2
    // garage
    static let gx0: Float = 6.12
    static let gx1: Float = 20.32
    static let gz0: Float = -10.12
    static let gz1: Float = 8.12
    static let garageH: Float = 4.2
    static let doorX0: Float = 11.2
    static let doorX1: Float = 16.8
    static let doorH: Float = 3.1
    // key points
    static let frontDoorX: Float = -3
    static let carSpot = Vec2(14, -0.5)
    static let bedHips = Vec3(-13.85, 0.60, -6.0)
    static let bedGetUp = Vec2(-11.8, -6.0)
}

@MainActor
final class HouseBuilder {
    let mats: HouseMaterials
    private unowned let ctx: GameContext
    private let center: Vec2
    private let heading: Float

    let exteriorNode = SCNNode()
    let interiorNode = SCNNode()
    let garageNode = SCNNode()
    let extrasNode = SCNNode()
    private let ext = WMeshSet()
    private let inn = WMeshSet()
    private let gar = WMeshSet()

    private(set) var lights: [SCNNode] = []
    private(set) var garageLights: [SCNNode] = []
    private(set) var showroomSpots: [SCNNode] = []
    private(set) var animatedScreens: [SCNMaterial] = []
    private(set) var garageDoorNode: SCNNode? = nil
    private(set) var tvNode: SCNNode? = nil
    private(set) var liftRing: SCNNode? = nil
    private(set) var windowViewMaterial: SCNMaterial
    private var colliderCount: Int = 0

    init(ctx: GameContext, center: Vec2, heading: Float) {
        self.ctx = ctx
        self.center = center
        self.heading = heading
        mats = HouseMaterials()
        windowViewMaterial = mats.windowView
        exteriorNode.name = "houseExterior"
        interiorNode.name = "houseInterior"
        garageNode.name = "houseGarage"
        extrasNode.name = "houseExtras"
    }

    // MARK: coordinate helpers

    func worldPoint(_ lx: Float, _ lz: Float) -> Vec2 {
        return center + headingLeft2(heading) * lx + headingForward2(heading) * lz
    }

    func worldHeading(localAngle a: Float) -> Float { return wrapAngle(heading + a) }

    // MARK: primitives (plot local)

    private func box(_ set: WMeshSet, _ mat: SCNMaterial, _ cx: Float, _ cy: Float, _ cz: Float, _ sx: Float, _ sy: Float, _ sz: Float) {
        set.mesh(mat).box(center: Vec3(cx, cy, cz), size: Vec3(sx, sy, sz), u: 0.5, v: 0.5)
    }

    private func boxRange(_ set: WMeshSet, _ mat: SCNMaterial, x0: Float, x1: Float, y0: Float, y1: Float, z0: Float, z1: Float) {
        box(set, mat, (x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5, abs(x1 - x0), abs(y1 - y0), abs(z1 - z0))
    }

    private func collider(cx: Float, cz: Float, sx: Float, sz: Float, kind: ColliderKind, height: Float) {
        guard let w = ctx.world else { return }
        let wc: Vec2 = worldPoint(cx, cz)
        let id: Int = w.colliders.allocateID()
        w.colliders.add(Collider.box(id: id, kind: kind, center: wc, halfExtents: Vec2(sx * 0.5, sz * 0.5), heading: heading, height: height, mass: 50_000))
        colliderCount += 1
    }

    private func circleCollider(cx: Float, cz: Float, r: Float, height: Float) {
        guard let w = ctx.world else { return }
        let id: Int = w.colliders.allocateID()
        w.colliders.add(Collider.circle(id: id, kind: ColliderKind.prop, center: worldPoint(cx, cz), radius: r, destructible: false, height: height, mass: 5_000))
        colliderCount += 1
    }

    /// solid furniture piece: visible box + collider
    private func furniture(_ set: WMeshSet, _ mat: SCNMaterial, _ cx: Float, _ cz: Float, _ sx: Float, _ sz: Float, y0: Float, y1: Float, collide: Bool = true) {
        boxRange(set, mat, x0: cx - sx * 0.5, x1: cx + sx * 0.5, y0: y0, y1: y1, z0: cz - sz * 0.5, z1: cz + sz * 0.5)
        if collide { collider(cx: cx, cz: cz, sx: sx, sz: sz, kind: ColliderKind.prop, height: y1) }
    }

    /// wall segment (plan rectangle) from y0 to y1 with collider
    private func wallBox(_ set: WMeshSet, _ mat: SCNMaterial, x0: Float, x1: Float, z0: Float, z1: Float, y0: Float, y1: Float, collide: Bool) {
        boxRange(set, mat, x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1)
        if collide {
            collider(cx: (x0 + x1) * 0.5, cz: (z0 + z1) * 0.5, sx: abs(x1 - x0), sz: abs(z1 - z0), kind: ColliderKind.houseWall, height: y1)
        }
    }

    /// wall running along x at z (thickness t), with doorway gaps (x0, x1); lintels above the gaps
    private func wallRunX(_ set: WMeshSet, _ mat: SCNMaterial, z: Float, x0: Float, x1: Float, t: Float, top: Float, gaps: [(Float, Float)]) {
        var cursor: Float = x0
        let sorted = gaps.sorted { $0.0 < $1.0 }
        for g in sorted {
            if g.0 > cursor { wallBox(set, mat, x0: cursor, x1: g.0, z0: z - t * 0.5, z1: z + t * 0.5, y0: 0, y1: top, collide: true) }
            wallBox(set, mat, x0: g.0, x1: g.1, z0: z - t * 0.5, z1: z + t * 0.5, y0: HousePlan.doorH - 0.75, y1: top, collide: false)
            cursor = g.1
        }
        if x1 > cursor { wallBox(set, mat, x0: cursor, x1: x1, z0: z - t * 0.5, z1: z + t * 0.5, y0: 0, y1: top, collide: true) }
    }

    private func wallRunZ(_ set: WMeshSet, _ mat: SCNMaterial, x: Float, z0: Float, z1: Float, t: Float, top: Float, gaps: [(Float, Float)]) {
        var cursor: Float = z0
        let sorted = gaps.sorted { $0.0 < $1.0 }
        for g in sorted {
            if g.0 > cursor { wallBox(set, mat, x0: x - t * 0.5, x1: x + t * 0.5, z0: cursor, z1: g.0, y0: 0, y1: top, collide: true) }
            wallBox(set, mat, x0: x - t * 0.5, x1: x + t * 0.5, z0: g.0, z1: g.1, y0: HousePlan.doorH - 0.75, y1: top, collide: false)
            cursor = g.1
        }
        if z1 > cursor { wallBox(set, mat, x0: x - t * 0.5, x1: x + t * 0.5, z0: cursor, z1: z1, y0: 0, y1: top, collide: true) }
    }

    private func floorRect(_ set: WMeshSet, _ mat: SCNMaterial, x0: Float, x1: Float, z0: Float, z1: Float, y: Float, tile: Float) {
        set.mesh(mat).groundRect(x0, z0, x1, z1, y: y, tile: tile)
    }

    private func ceilingRect(_ set: WMeshSet, _ mat: SCNMaterial, x0: Float, x1: Float, z0: Float, z1: Float, y: Float) {
        set.mesh(mat).quad(Vec3(x0, y, z0), Vec3(x1, y, z0), Vec3(x1, y, z1), Vec3(x0, y, z1), Vec3(0, -1, 0), 0, 0, 1, 1)
    }

    /// picture / mural on a wall. facing = outward normal of the wall face (local axes). (a, b) = horizontal range along the wall
    private func art(_ set: WMeshSet, _ mat: SCNMaterial, facing: Vec2, at: Float, from a: Float, to b: Float, y0: Float, y1: Float) {
        let m = set.mesh(mat)
        if facing.x != 0 {
            // wall along z at x = at, facing +x / -x ; a,b are z values
            let n = Vec3(facing.x, 0, 0)
            if facing.x > 0 {
                m.quad(Vec3(at, y0, b), Vec3(at, y0, a), Vec3(at, y1, a), Vec3(at, y1, b), n, 0, 0, 1, 1)
            } else {
                m.quad(Vec3(at, y0, a), Vec3(at, y0, b), Vec3(at, y1, b), Vec3(at, y1, a), n, 0, 0, 1, 1)
            }
        } else {
            let n = Vec3(0, 0, facing.y)
            if facing.y > 0 {
                m.quad(Vec3(a, y0, at), Vec3(b, y0, at), Vec3(b, y1, at), Vec3(a, y1, at), n, 0, 0, 1, 1)
            } else {
                m.quad(Vec3(b, y0, at), Vec3(a, y0, at), Vec3(a, y1, at), Vec3(b, y1, at), n, 0, 0, 1, 1)
            }
        }
    }

    private func addLight(_ pos: Vec3, color: UIColor, intensity: CGFloat, range: CGFloat, garage: Bool) {
        let n = SCNNode()
        let l = SCNLight()
        l.type = SCNLight.LightType.omni
        l.color = color
        l.intensity = intensity
        l.attenuationStartDistance = 1.5
        l.attenuationEndDistance = range
        l.categoryBitMask = 8
        l.castsShadow = false
        n.light = l
        n.simdPosition = pos
        (garage ? garageNode : interiorNode).addChildNode(n)
        if garage { garageLights.append(n) } else { lights.append(n) }
    }

    // MARK: build

    func build() {
        buildYard()
        buildVillaShell()
        buildVillaInterior()
        buildGarage()
        finish()
    }

    private func finish() {
        func attach(_ set: WMeshSet, to parent: SCNNode, category: Int, shadows: Bool, name: String) {
            guard let g = set.makeGeometry() else { return }
            let n = SCNNode(geometry: g)
            n.name = name
            n.categoryBitMask = category
            n.castsShadow = shadows
            parent.addChildNode(n)
        }
        attach(ext, to: exteriorNode, category: 1, shadows: true, name: "villaShell")
        attach(inn, to: interiorNode, category: 8, shadows: false, name: "villaInterior")
        attach(gar, to: garageNode, category: 8, shadows: false, name: "garageInterior")
        // interior ambient (the sky lights do not reach category 8)
        let amb = SCNNode()
        let al = SCNLight()
        al.type = SCNLight.LightType.ambient
        al.color = UIColor(red: 1.0, green: 0.90, blue: 0.80, alpha: 1)
        al.intensity = 330
        al.categoryBitMask = 8
        amb.light = al
        interiorNode.addChildNode(amb)
        let amb2 = SCNNode()
        let al2 = SCNLight()
        al2.type = SCNLight.LightType.ambient
        al2.color = UIColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1)
        al2.intensity = 300
        al2.categoryBitMask = 8
        amb2.light = al2
        garageNode.addChildNode(amb2)
    }

    // MARK: yard

    private func buildYard() {
        // lawn + driveway (drawn above the world's ground layers)
        let lm = ext.mesh(mats.lawn)
        lm.groundRect(-23.5, -21, 23.5, 17.5, y: 0.012, tile: 6)
        let dm = ext.mesh(mats.driveway)
        dm.groundRect(HousePlan.doorX0 - 0.6, 8.1, HousePlan.doorX1 + 0.6, 18.2, y: 0.02, tile: 3)
        dm.groundRect(-4.4, 8.1, -1.6, 12.5, y: 0.02, tile: 3)      // path to the front door
        // hedges + collider boxes
        let hedgeH: Float = 1.3
        boxRange(ext, mats.hedge, x0: -23.5, x1: -22.9, y0: 0, y1: hedgeH, z0: -21, z1: 15)
        boxRange(ext, mats.hedge, x0: 22.9, x1: 23.5, y0: 0, y1: hedgeH, z0: -21, z1: 15)
        boxRange(ext, mats.hedge, x0: -23.5, x1: 23.5, y0: 0, y1: hedgeH, z0: -21, z1: -20.4)
        collider(cx: -23.2, cz: -3, sx: 0.6, sz: 36, kind: ColliderKind.barrier, height: hedgeH)
        collider(cx: 23.2, cz: -3, sx: 0.6, sz: 36, kind: ColliderKind.barrier, height: hedgeH)
        collider(cx: 0, cz: -20.7, sx: 47, sz: 0.6, kind: ColliderKind.barrier, height: hedgeH)
        // low garden wall along the front, with an opening for the path and the driveway
        let wallH: Float = 0.55
        boxRange(ext, mats.plasterDark, x0: -23.5, x1: -4.8, y0: 0, y1: wallH, z0: 15.2, z1: 15.6)
        boxRange(ext, mats.plasterDark, x0: -1.2, x1: 10.6, y0: 0, y1: wallH, z0: 15.2, z1: 15.6)
        boxRange(ext, mats.plasterDark, x0: 17.4, x1: 23.5, y0: 0, y1: wallH, z0: 15.2, z1: 15.6)
        // neon posts at the driveway
        boxRange(ext, mats.neonGreen, x0: 10.4, x1: 10.6, y0: 0.2, y1: 1.0, z0: 15.0, z1: 15.2)
        boxRange(ext, mats.neonMagenta, x0: 17.4, x1: 17.6, y0: 0.2, y1: 1.0, z0: 15.0, z1: 15.2)
        // patio slab behind the house
        floorRect(ext, mats.driveway, x0: -14, x1: 4, z0: -17, z1: -12.2, y: 0.022, tile: 3)
        // planters + a bench
        for (i, x) in [Float(-8), Float(-5.5), Float(1.5), Float(4)].enumerated() {
            _ = i
            boxRange(ext, mats.plasterDark, x0: x - 0.5, x1: x + 0.5, y0: 0, y1: 0.55, z0: 8.4, z1: 9.2)
            boxRange(ext, mats.hedge, x0: x - 0.42, x1: x + 0.42, y0: 0.55, y1: 1.25, z0: 8.5, z1: 9.1)
            collider(cx: x, cz: 8.8, sx: 1.0, sz: 0.8, kind: ColliderKind.prop, height: 1.2)
        }
        // mango trees (the user's asset) around the yard
        let treeSpots: [(Float, Float, Float)] = [(-19.5, -15, 1.25), (19, -15.5, 1.15), (-20.5, 5, 1.05), (21, -5, 1.2), (-19, 12.5, 0.95)]
        for t in treeSpots {
            if let tree = try? ctx.assets.model("tree_lod0") {
                let holder = SCNNode()
                holder.simdPosition = Vec3(t.0, 0, t.1)
                holder.simdScale = Vec3(t.2, t.2, t.2)
                holder.addChildNode(tree)
                extrasNode.addChildNode(holder)
            }
            circleCollider(cx: t.0, cz: t.1, r: 0.5 * t.2, height: 6)
        }
    }

    // MARK: villa shell (exterior)

    private func buildVillaShell() {
        let x0 = HousePlan.vx0
        let x1: Float = HousePlan.gx0
        let z0 = HousePlan.vz0
        let z1 = HousePlan.vz1
        let h = HousePlan.ceilingH
        let t: Float = 0.24
        // outer walls (solid, colliders)
        wallBox(ext, mats.plaster, x0: x0, x1: x0 + t, z0: z0, z1: z1, y0: 0, y1: h, collide: true)              // west
        wallBox(ext, mats.plaster, x0: x0, x1: x1, z0: z0, z1: z0 + t, y0: 0, y1: h, collide: true)              // back
        wallBox(ext, mats.plaster, x0: x0, x1: x1, z0: z1 - t, z1: z1, y0: 0, y1: h, collide: true)              // front
        // roof slab + edge
        boxRange(ext, mats.plasterDark, x0: x0 - 0.7, x1: x1 + 0.2, y0: h, y1: h + 0.32, z0: z0 - 0.7, z1: z1 + 0.9)
        boxRange(ext, mats.neonMagenta, x0: x0 - 0.7, x1: x1 + 0.2, y0: h + 0.26, y1: h + 0.32, z0: z1 + 0.85, z1: z1 + 0.9)
        // upper volume (decorative second storey)
        boxRange(ext, mats.cladding, x0: -14.2, x1: -5.6, y0: h + 0.32, y1: h + 3.1, z0: -7.5, z1: 4.5)
        boxRange(ext, mats.plaster, x0: -14.3, x1: -5.5, y0: h + 3.1, y1: h + 3.3, z0: -7.6, z1: 4.6)
        // long window band on the upper volume (front and side)
        boxRange(ext, mats.glassExterior, x0: -13.4, x1: -6.4, y0: h + 0.9, y1: h + 2.3, z0: 4.5, z1: 4.53)
        boxRange(ext, mats.neonGreen, x0: -13.4, x1: -6.4, y0: h + 0.86, y1: h + 0.9, z0: 4.5, z1: 4.54)
        boxRange(ext, mats.glassExterior, x0: -5.6, x1: -5.57, y0: h + 0.9, y1: h + 2.3, z0: -6, z1: 3)
        // front door assembly
        let dx = HousePlan.frontDoorX
        boxRange(ext, mats.cladding, x0: dx - 1.05, x1: dx + 1.05, y0: 0, y1: 2.75, z0: z1, z1: z1 + 0.18)
        boxRange(ext, mats.woodDark, x0: dx - 0.55, x1: dx + 0.55, y0: 0, y1: 2.35, z0: z1 + 0.18, z1: z1 + 0.24)
        boxRange(ext, mats.metal, x0: dx + 0.35, x1: dx + 0.42, y0: 0.9, y1: 1.15, z0: z1 + 0.24, z1: z1 + 0.3)
        boxRange(ext, mats.neonWhite, x0: dx - 0.9, x1: dx + 0.9, y0: 2.78, y1: 2.84, z0: z1 + 0.1, z1: z1 + 0.16)
        // canopy over the door
        boxRange(ext, mats.plasterDark, x0: dx - 1.6, x1: dx + 1.6, y0: 2.85, y1: 3.0, z0: z1, z1: z1 + 1.8)
        // wooden slat wall left of the door
        var sx: Float = dx - 4.6
        while sx < dx - 1.3 {
            boxRange(ext, mats.woodWarm, x0: sx, x1: sx + 0.07, y0: 0, y1: 3.0, z0: z1, z1: z1 + 0.1)
            sx += 0.16
        }
        // windows on the front wall (glass + frame); the living room and kitchen ones
        let frontWindows: [(Float, Float, Float, Float)] = [(-13.8, -10.6, 0.7, 2.6), (-9.2, -5.8, 0.7, 2.6), (1.2, 5.0, 1.0, 2.4)]
        for w in frontWindows {
            boxRange(ext, mats.black, x0: w.0 - 0.07, x1: w.1 + 0.07, y0: w.2 - 0.07, y1: w.3 + 0.07, z0: z1, z1: z1 + 0.05)
            boxRange(ext, mats.glassExterior, x0: w.0, x1: w.1, y0: w.2, y1: w.3, z0: z1 + 0.05, z1: z1 + 0.07)
        }
        // big c0derz mural on the west wall
        art(ext, mats.muralExterior, facing: Vec2(-1, 0), at: x0 - 0.02, from: -9, to: 2.5, y0: 0.35, y1: 3.0)
        // neon strip along the west wall top
        boxRange(ext, mats.neonGreen, x0: x0 - 0.05, x1: x0 - 0.02, y0: 3.05, y1: 3.1, z0: -9.5, z1: 3.2)
        // chimney-like tower with the neon sign at the front corner
        boxRange(ext, mats.cladding, x0: 4.6, x1: 6.3, y0: 0, y1: h + 1.4, z0: 8.0, z1: 8.6)
        art(ext, mats.signMat, facing: Vec2(0, 1), at: 8.62, from: 4.7, to: 6.2, y0: h - 0.6, y1: h + 0.55)
    }

    // MARK: villa interior

    private func buildVillaInterior() {
        let h = HousePlan.ceilingH
        let ix0: Float = HousePlan.vx0 + 0.24
        let ix1: Float = HousePlan.gx0 - 0.24
        let iz0: Float = HousePlan.vz0 + 0.24
        let iz1: Float = HousePlan.vz1 - 0.24
        // floors + ceiling
        floorRect(inn, mats.woodFloor, x0: ix0, x1: ix1, z0: iz0, z1: iz1, y: 0.004, tile: 2.5)
        floorRect(inn, mats.tile, x0: -4, x1: 0, z0: 1, z1: iz1, y: 0.008, tile: 2)
        floorRect(inn, mats.tile, x0: 0, x1: ix1, z0: 1, z1: iz1, y: 0.008, tile: 2)
        floorRect(inn, mats.tile, x0: -7, x1: -3, z0: -8, z1: -1.5, y: 0.008, tile: 2)
        floorRect(inn, mats.epoxy, x0: -7, x1: -3, z0: iz0, z1: -8, y: 0.008, tile: 2)
        ceilingRect(inn, mats.ceiling, x0: ix0, x1: ix1, z0: iz0, z1: iz1, y: h)
        // partitions
        let t: Float = 0.16
        wallRunX(inn, mats.plaster, z: 1.0, x0: ix0, x1: ix1, t: t, top: h, gaps: [(-3.4, -0.6), (2.4, 3.6)])
        wallRunX(inn, mats.plaster, z: -1.5, x0: -7, x1: ix1, t: t, top: h, gaps: [(-5.6, -4.4), (-0.4, 0.8)])
        wallRunX(inn, mats.plaster, z: -8, x0: -7, x1: -3, t: t, top: h, gaps: [])
        wallRunZ(inn, mats.plaster, x: -7, z0: iz0, z1: 1.0, t: t, top: h, gaps: [(-1.1, 0.3)])
        wallRunZ(inn, mats.plaster, x: -4, z0: 1.0, z1: iz1, t: t, top: h, gaps: [(3.0, 6.2)])
        wallRunZ(inn, mats.plaster, x: 0, z0: 1.0, z1: iz1, t: t, top: h, gaps: [(2.6, 5.8)])
        wallRunZ(inn, mats.plaster, x: -3, z0: iz0, z1: -1.5, t: t, top: h, gaps: [])
        // east wall (shared with the garage): kitchen door to the garage
        wallRunZ(inn, mats.plaster, x: ix1 + 0.12, z0: iz0, z1: iz1, t: 0.24, top: h, gaps: [(3.8, 5.0)])
        // skirting + LED strips
        boxRange(inn, mats.neonGreen, x0: ix0, x1: ix0 + 0.03, y0: h - 0.12, y1: h - 0.08, z0: 1.2, z1: iz1 - 0.2)
        boxRange(inn, mats.neonMagenta, x0: ix0 + 0.03, x1: ix1 - 0.2, y0: h - 0.12, y1: h - 0.08, z0: iz0, z1: iz0 + 0.03)

        buildLiving(h)
        buildHall(h)
        buildKitchen(h)
        buildBedroom(h)
        buildBathroom(h)
        buildOffice(h)
        buildWindowsInside(h)
    }

    private func buildLiving(_ h: Float) {
        // feature wall: c0derz mural on the west wall
        art(inn, mats.muralLiving, facing: Vec2(1, 0), at: -14.74, from: 1.8, to: 7.4, y0: 0.35, y1: 2.9)
        // TV wall (z = 1.08 facing +z)
        furniture(inn, mats.black, -9.5, 1.5, 3.4, 0.5, y0: 0.0, y1: 0.55)
        boxRange(inn, mats.cabinet, x0: -11.2, x1: -7.8, y0: 0.05, y1: 0.5, z0: 1.1, z1: 1.7)
        let tvPlane = SCNPlane(width: 2.1, height: 1.18)
        tvPlane.materials = [mats.tvScreen]
        let tv = SCNNode(geometry: tvPlane)
        tv.simdPosition = Vec3(-9.5, 1.55, 1.1)
        tv.categoryBitMask = 8
        interiorNode.addChildNode(tv)
        tvNode = tv
        boxRange(inn, mats.black, x0: -10.62, x1: -8.38, y0: 0.94, y1: 2.16, z0: 1.07, z1: 1.09)
        // rug, sofa (L shape), coffee table
        floorRect(inn, mats.rug, x0: -12.3, x1: -6.7, z0: 2.4, z1: 6.4, y: 0.014, tile: 4)
        furniture(inn, mats.fabric, -9.5, 6.0, 3.6, 1.0, y0: 0.0, y1: 0.45)
        boxRange(inn, mats.fabric, x0: -11.3, x1: -7.7, y0: 0.45, y1: 0.95, z0: 6.4, z1: 6.62)
        furniture(inn, mats.fabric, -11.6, 4.6, 1.0, 2.0, y0: 0.0, y1: 0.45)
        boxRange(inn, mats.fabricAccent, x0: -10.9, x1: -10.2, y0: 0.45, y1: 0.8, z0: 5.3, z1: 5.9)
        furniture(inn, mats.woodDark, -9.5, 3.7, 1.5, 0.8, y0: 0.0, y1: 0.42)
        boxRange(inn, mats.neonCyan, x0: -10.2, x1: -8.8, y0: 0.42, y1: 0.44, z0: 3.4, z1: 3.5)
        // floor lamp + plants
        boxRange(inn, mats.metal, x0: -6.8, x1: -6.7, y0: 0, y1: 1.7, z0: 6.9, z1: 7.0)
        boxRange(inn, mats.neonWhite, x0: -7.0, x1: -6.5, y0: 1.7, y1: 1.95, z0: 6.75, z1: 7.15)
        circleCollider(cx: -6.75, cz: 6.95, r: 0.25, height: 2)
        for p in [(-14.2, 7.2), (-14.2, 1.6), (-4.6, 1.5)] {
            boxRange(inn, mats.plasterDark, x0: Float(p.0) - 0.3, x1: Float(p.0) + 0.3, y0: 0, y1: 0.45, z0: Float(p.1) - 0.3, z1: Float(p.1) + 0.3)
            boxRange(inn, mats.hedge, x0: Float(p.0) - 0.4, x1: Float(p.0) + 0.4, y0: 0.45, y1: 1.5, z0: Float(p.1) - 0.4, z1: Float(p.1) + 0.4)
            circleCollider(cx: Float(p.0), cz: Float(p.1), r: 0.35, height: 1.5)
        }
        addLight(Vec3(-9.5, h - 0.3, 4.3), color: UIColor(red: 1.0, green: 0.82, blue: 0.6, alpha: 1), intensity: 520, range: 11, garage: false)
        addLight(Vec3(-12.5, h - 0.4, 2.5), color: UIColor(red: 0.6, green: 1.0, blue: 0.8, alpha: 1), intensity: 260, range: 8, garage: false)
    }

    private func buildHall(_ h: Float) {
        // shoe cabinet, mirror, exit door (inside face of the front door)
        furniture(inn, mats.woodDark, -1.0, 1.9, 1.6, 0.5, y0: 0, y1: 0.9)
        art(inn, mats.posterA, facing: Vec2(-1, 0), at: -0.09, from: 1.9, to: 2.9, y0: 1.2, y1: 2.5)
        boxRange(inn, mats.cladding, x0: HousePlan.frontDoorX - 0.55, x1: HousePlan.frontDoorX + 0.55, y0: 0, y1: 2.35, z0: 7.7, z1: 7.76)
        boxRange(inn, mats.metal, x0: HousePlan.frontDoorX - 0.4, x1: HousePlan.frontDoorX - 0.33, y0: 0.9, y1: 1.15, z0: 7.66, z1: 7.7)
        boxRange(inn, mats.neonGreen, x0: HousePlan.frontDoorX - 0.6, x1: HousePlan.frontDoorX + 0.6, y0: 2.4, y1: 2.44, z0: 7.7, z1: 7.76)
        addLight(Vec3(-2, h - 0.3, 4.5), color: UIColor(red: 1.0, green: 0.86, blue: 0.68, alpha: 1), intensity: 420, range: 9, garage: false)
    }

    private func buildKitchen(_ h: Float) {
        // counters along the front wall + fridge
        furniture(inn, mats.cabinet, 3.0, 7.35, 5.0, 0.7, y0: 0, y1: 0.9)
        boxRange(inn, mats.counter, x0: 0.5, x1: 5.5, y0: 0.9, y1: 0.95, z0: 7.0, z1: 7.72)
        boxRange(inn, mats.cabinet, x0: 0.5, x1: 5.5, y0: 1.6, y1: 2.4, z0: 7.44, z1: 7.72)
        boxRange(inn, mats.neonWhite, x0: 0.5, x1: 5.5, y0: 1.56, y1: 1.6, z0: 7.44, z1: 7.7)
        furniture(inn, mats.metal, 5.3, 1.75, 0.9, 0.8, y0: 0, y1: 1.95)
        // island + stools
        furniture(inn, mats.cabinet, 2.4, 3.2, 2.6, 1.0, y0: 0, y1: 0.92)
        boxRange(inn, mats.counter, x0: 1.05, x1: 3.75, y0: 0.92, y1: 0.97, z0: 2.65, z1: 3.75)
        for sx in [Float(1.6), Float(2.4), Float(3.2)] {
            boxRange(inn, mats.leather, x0: sx - 0.18, x1: sx + 0.18, y0: 0.6, y1: 0.66, z0: 4.05, z1: 4.4)
            boxRange(inn, mats.metal, x0: sx - 0.03, x1: sx + 0.03, y0: 0, y1: 0.6, z0: 4.2, z1: 4.25)
        }
        // door to the garage (inside the kitchen, east wall): a dark frame
        boxRange(inn, mats.neonMagenta, x0: 5.7, x1: 5.76, y0: 2.3, y1: 2.34, z0: 3.8, z1: 5.0)
        addLight(Vec3(3, h - 0.3, 4.5), color: UIColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 1), intensity: 520, range: 10, garage: false)
    }

    private func buildBedroom(_ h: Float) {
        // bed (head at the west wall)
        furniture(inn, mats.woodDark, -13.7, -6.0, 2.4, 2.0, y0: 0, y1: 0.35)
        boxRange(inn, mats.sheet, x0: -14.85, x1: -12.5, y0: 0.35, y1: 0.55, z0: -6.95, z1: -5.05)
        boxRange(inn, mats.blanket, x0: -13.6, x1: -12.5, y0: 0.55, y1: 0.63, z0: -6.98, z1: -5.02)
        boxRange(inn, mats.sheet, x0: -14.8, x1: -14.2, y0: 0.55, y1: 0.7, z0: -6.7, z1: -5.9)
        boxRange(inn, mats.sheet, x0: -14.8, x1: -14.2, y0: 0.55, y1: 0.7, z0: -6.1, z1: -5.3)
        boxRange(inn, mats.cladding, x0: -14.76, x1: -14.6, y0: 0.2, y1: 1.5, z0: -7.2, z1: -4.8)
        boxRange(inn, mats.neonMagenta, x0: -14.6, x1: -14.57, y0: 1.5, y1: 1.54, z0: -7.2, z1: -4.8)
        // nightstands with lamps
        furniture(inn, mats.woodDark, -14.4, -7.6, 0.6, 0.6, y0: 0, y1: 0.5)
        furniture(inn, mats.woodDark, -14.4, -4.4, 0.6, 0.6, y0: 0, y1: 0.5)
        boxRange(inn, mats.neonWhite, x0: -14.55, x1: -14.25, y0: 0.5, y1: 0.75, z0: -7.75, z1: -7.45)
        boxRange(inn, mats.neonWhite, x0: -14.55, x1: -14.25, y0: 0.5, y1: 0.75, z0: -4.55, z1: -4.25)
        // feature wall behind the bed (north wall) + wardrobe
        art(inn, mats.muralBedroom, facing: Vec2(0, 1), at: -11.74, from: -14.0, to: -8.0, y0: 0.6, y1: 2.9)
        furniture(inn, mats.cabinet, -10.5, 0.5, 3.4, 0.9, y0: 0, y1: 2.5)
        art(inn, mats.posterB, facing: Vec2(-1, 0), at: -7.09, from: -9.6, to: -8.4, y0: 1.2, y1: 2.8)
        floorRect(inn, mats.rug, x0: -12.2, x1: -8.6, z0: -8.0, z1: -4.0, y: 0.014, tile: 4)
        boxRange(inn, mats.neonGreen, x0: -14.7, x1: -7.2, y0: h - 0.12, y1: h - 0.08, z0: -11.7, z1: -11.66)
        addLight(Vec3(-11, h - 0.3, -6), color: UIColor(red: 1.0, green: 0.62, blue: 0.85, alpha: 1), intensity: 430, range: 10, garage: false)
    }

    private func buildBathroom(_ h: Float) {
        furniture(inn, mats.counter, -3.6, -6.8, 0.8, 1.4, y0: 0, y1: 0.85)
        boxRange(inn, mats.metal, x0: -3.75, x1: -3.6, y0: 0.95, y1: 1.1, z0: -7.0, z1: -6.6)
        boxRange(inn, mats.black, x0: -3.16, x1: -3.14, y0: 1.1, y1: 2.2, z0: -7.4, z1: -6.2)
        furniture(inn, mats.counter, -6.4, -4.0, 0.7, 0.5, y0: 0, y1: 0.42)
        furniture(inn, mats.glassExterior, -5.2, -7.1, 1.6, 1.6, y0: 0, y1: 2.1)
        boxRange(inn, mats.neonCyan, x0: -6.9, x1: -3.1, y0: h - 0.12, y1: h - 0.08, z0: -1.6, z1: -1.55)
        addLight(Vec3(-5, h - 0.3, -4.5), color: UIColor(red: 0.85, green: 0.95, blue: 1.0, alpha: 1), intensity: 380, range: 7, garage: false)
    }

    private func buildOffice(_ h: Float) {
        // circuit-board mural wall + desk with three code monitors, chair, server rack
        art(inn, mats.muralOffice, facing: Vec2(0, 1), at: -11.74, from: -2.6, to: 5.5, y0: 0.5, y1: 2.9)
        furniture(inn, mats.woodDark, 1.4, -10.9, 4.0, 1.0, y0: 0.7, y1: 0.76)
        boxRange(inn, mats.black, x0: -0.4, x1: -0.3, y0: 0, y1: 0.7, z0: -11.3, z1: -10.5)
        boxRange(inn, mats.black, x0: 3.2, x1: 3.3, y0: 0, y1: 0.7, z0: -11.3, z1: -10.5)
        collider(cx: 1.4, cz: -10.9, sx: 4.0, sz: 1.0, kind: ColliderKind.prop, height: 0.8)
        for (i, mx) in [Float(0.2), Float(1.4), Float(2.6)].enumerated() {
            let plane = SCNPlane(width: 1.05, height: 0.6)
            let mat: SCNMaterial = (mats.codeScreen.copy() as? SCNMaterial) ?? mats.codeScreen
            mat.diffuse.contentsTransform = SCNMatrix4MakeScale(1, 0.55, 1)
            plane.materials = [mat]
            let n = SCNNode(geometry: plane)
            n.simdPosition = Vec3(mx, 1.12, -11.32)
            n.simdEulerAngles = Vec3(0, 0, 0)
            n.categoryBitMask = 8
            interiorNode.addChildNode(n)
            animatedScreens.append(mat)
            _ = i
            boxRange(inn, mats.black, x0: mx - 0.55, x1: mx + 0.55, y0: 0.82, y1: 1.44, z0: -11.4, z1: -11.35)
            boxRange(inn, mats.black, x0: mx - 0.04, x1: mx + 0.04, y0: 0.76, y1: 0.85, z0: -11.4, z1: -11.3)
        }
        // gaming chair
        boxRange(inn, mats.leather, x0: 1.0, x1: 1.8, y0: 0.45, y1: 0.55, z0: -9.7, z1: -9.0)
        boxRange(inn, mats.leather, x0: 1.05, x1: 1.75, y0: 0.55, y1: 1.35, z0: -9.05, z1: -8.95)
        boxRange(inn, mats.neonMagenta, x0: 1.05, x1: 1.75, y0: 1.35, y1: 1.4, z0: -9.05, z1: -8.95)
        boxRange(inn, mats.metal, x0: 1.35, x1: 1.45, y0: 0, y1: 0.45, z0: -9.4, z1: -9.3)
        circleCollider(cx: 1.4, cz: -9.35, r: 0.4, height: 1.4)
        // server rack
        furniture(inn, mats.black, 5.2, -6.5, 0.8, 1.0, y0: 0, y1: 2.1)
        boxRange(inn, mats.neonGreen, x0: 4.78, x1: 4.8, y0: 0.4, y1: 1.9, z0: -6.75, z1: -6.7)
        boxRange(inn, mats.neonMagenta, x0: 4.78, x1: 4.8, y0: 0.5, y1: 1.7, z0: -6.4, z1: -6.36)
        // shelf
        boxRange(inn, mats.woodWarm, x0: -2.7, x1: -2.5, y0: 0, y1: 2.2, z0: -9.5, z1: -4.0)
        collider(cx: -2.6, cz: -6.75, sx: 0.3, sz: 5.5, kind: ColliderKind.prop, height: 2.2)
        addLight(Vec3(1.5, h - 0.3, -6), color: UIColor(red: 0.7, green: 1.0, blue: 0.85, alpha: 1), intensity: 460, range: 10, garage: false)
        addLight(Vec3(0.5, h - 0.3, 0.0), color: UIColor(red: 1.0, green: 0.9, blue: 0.75, alpha: 1), intensity: 300, range: 9, garage: false)
    }

    private func buildWindowsInside(_ h: Float) {
        // "windows" on the inside of the front wall showing the sky (emissive); the exterior panes are on the outside
        let frontWindows: [(Float, Float, Float, Float)] = [(-13.8, -10.6, 0.7, 2.6), (-9.2, -5.8, 0.7, 2.6), (1.2, 5.0, 1.0, 2.4)]
        let m = inn.mesh(mats.windowView)
        for w in frontWindows {
            let z: Float = HousePlan.vz1 - 0.245
            m.quad(Vec3(w.1, w.2, z), Vec3(w.0, w.2, z), Vec3(w.0, w.3, z), Vec3(w.1, w.3, z), Vec3(0, 0, -1), 0, 0, 1, 1)
            boxRange(inn, mats.black, x0: w.0 - 0.05, x1: w.1 + 0.05, y0: w.3, y1: w.3 + 0.07, z0: z - 0.02, z1: z)
            boxRange(inn, mats.black, x0: w.0 - 0.05, x1: w.1 + 0.05, y0: w.2 - 0.07, y1: w.2, z0: z - 0.02, z1: z)
            boxRange(inn, mats.black, x0: (w.0 + w.1) * 0.5 - 0.03, x1: (w.0 + w.1) * 0.5 + 0.03, y0: w.2, y1: w.3, z0: z - 0.02, z1: z)
        }
        _ = h
    }

    // MARK: garage

    private func buildGarage() {
        let gx0 = HousePlan.gx0
        let gx1 = HousePlan.gx1
        let gz0 = HousePlan.gz0
        let gz1 = HousePlan.gz1
        let gh = HousePlan.garageH
        let t: Float = 0.24
        let ch: Float = 3.7
        // exterior walls (drawn in the exterior mesh so the outside is lit by the sun)
        wallBox(ext, mats.plasterDark, x0: gx1 - t, x1: gx1, z0: gz0, z1: gz1, y0: 0, y1: gh, collide: true)      // east
        wallBox(ext, mats.plasterDark, x0: gx0, x1: gx1, z0: gz0, z1: gz0 + t, y0: 0, y1: gh, collide: true)      // back
        wallBox(ext, mats.plasterDark, x0: gx0, x1: HousePlan.doorX0, z0: gz1 - t, z1: gz1, y0: 0, y1: gh, collide: true)
        wallBox(ext, mats.plasterDark, x0: HousePlan.doorX1, x1: gx1, z0: gz1 - t, z1: gz1, y0: 0, y1: gh, collide: true)
        wallBox(ext, mats.plasterDark, x0: HousePlan.doorX0, x1: HousePlan.doorX1, z0: gz1 - t, z1: gz1, y0: HousePlan.doorH, y1: gh, collide: false)
        wallBox(ext, mats.plasterDark, x0: gx0 - 0.24, x1: gx0, z0: gz0, z1: gz1, y0: HousePlan.ceilingH, y1: gh, collide: false)   // garage wall above the villa roof
        boxRange(ext, mats.plasterDark, x0: gx0 - 0.1, x1: gx1 + 0.5, y0: gh, y1: gh + 0.3, z0: gz0 - 0.5, z1: gz1 + 0.9)
        boxRange(ext, mats.neonGreen, x0: gx0 - 0.1, x1: gx1 + 0.5, y0: gh + 0.24, y1: gh + 0.3, z0: gz1 + 0.85, z1: gz1 + 0.9)
        // exterior art: mural left of the door, sign above the door, frame around the opening
        art(ext, mats.muralGarage, facing: Vec2(0, 1), at: gz1 + 0.01, from: gx0 + 0.3, to: HousePlan.doorX0 - 0.3, y0: 0.4, y1: 3.4)
        art(ext, mats.signMat, facing: Vec2(0, 1), at: gz1 + 0.01, from: 11.9, to: 16.1, y0: 3.2, y1: 4.0)
        boxRange(ext, mats.neonMagenta, x0: HousePlan.doorX0 - 0.1, x1: HousePlan.doorX0, y0: 0, y1: HousePlan.doorH, z0: gz1, z1: gz1 + 0.06)
        boxRange(ext, mats.neonMagenta, x0: HousePlan.doorX1, x1: HousePlan.doorX1 + 0.1, y0: 0, y1: HousePlan.doorH, z0: gz1, z1: gz1 + 0.06)
        boxRange(ext, mats.neonGreen, x0: HousePlan.doorX0 - 0.1, x1: HousePlan.doorX1 + 0.1, y0: HousePlan.doorH, y1: HousePlan.doorH + 0.08, z0: gz1, z1: gz1 + 0.06)

        // roll-up door (animated node, no collider so the car can leave)
        let panel = SCNBox(width: CGFloat(HousePlan.doorX1 - HousePlan.doorX0), height: CGFloat(HousePlan.doorH), length: 0.08, chamferRadius: 0)
        panel.materials = [mats.garageDoor]
        let dn = SCNNode(geometry: panel)
        dn.simdPosition = Vec3((HousePlan.doorX0 + HousePlan.doorX1) * 0.5, HousePlan.doorH * 0.5, gz1 - 0.12)
        dn.categoryBitMask = 1
        extrasNode.addChildNode(dn)
        garageDoorNode = dn

        // interior
        floorRect(gar, mats.epoxy, x0: gx0, x1: gx1 - t, z0: gz0 + t, z1: gz1, y: 0.004, tile: 3)
        ceilingRect(gar, mats.ceiling, x0: gx0, x1: gx1 - t, z0: gz0 + t, z1: gz1 - 0.1, y: ch)
        // inner faces of the walls (dark panels) so the interior is closed from the inside
        boxRange(gar, mats.plasterDark, x0: gx1 - t - 0.04, x1: gx1 - t, y0: 0, y1: ch, z0: gz0 + t, z1: gz1)
        boxRange(gar, mats.plasterDark, x0: gx0, x1: gx1 - t, y0: 0, y1: ch, z0: gz0 + t, z1: gz0 + t + 0.04)
        // safety stripes + showroom ring around the car spot
        let cs = HousePlan.carSpot
        floorRect(gar, mats.safety, x0: cs.x - 2.6, x1: cs.x - 2.45, z0: cs.y - 3.4, z1: cs.y + 3.4, y: 0.012, tile: 1)
        floorRect(gar, mats.safety, x0: cs.x + 2.45, x1: cs.x + 2.6, z0: cs.y - 3.4, z1: cs.y + 3.4, y: 0.012, tile: 1)
        let ring = SCNNode()
        let rm = WMeshSet()
        let neonRing = mats.neonGreen
        let rmesh = rm.mesh(neonRing)
        let segs = 40
        for i in 0..<segs {
            let a0: Float = Float(i) / Float(segs) * Float.tau
            let a1: Float = Float(i + 1) / Float(segs) * Float.tau
            let d0 = Vec2(cosf(a0), sinf(a0))
            let d1 = Vec2(cosf(a1), sinf(a1))
            let c = Vec2(cs.x, cs.y)
            rmesh.groundQuad(c + d0 * 3.4, c + d1 * 3.4, c + d1 * 3.5, c + d0 * 3.5, y: 0.02, tile: 1)
        }
        ring.geometry = rm.makeGeometry()
        ring.categoryBitMask = 8
        ring.isHidden = true
        garageNode.addChildNode(ring)
        liftRing = ring
        // tool wall + mural on the back wall
        art(gar, mats.muralGarage, facing: Vec2(0, 1), at: gz0 + t + 0.05, from: 8.0, to: 19.4, y0: 0.5, y1: 3.4)
        boxRange(gar, mats.cabinet, x0: 6.3, x1: 7.6, y0: 0, y1: 1.0, z0: -9.8, z1: -6.2)
        collider(cx: 6.95, cz: -8.0, sx: 1.3, sz: 3.6, kind: ColliderKind.prop, height: 1.0)
        boxRange(gar, mats.woodWarm, x0: 6.3, x1: 7.6, y0: 1.0, y1: 1.06, z0: -9.8, z1: -6.2)
        boxRange(gar, mats.neonMagenta, x0: 6.2, x1: 6.24, y0: 1.5, y1: 1.56, z0: -9.8, z1: -6.2)
        // tyre rack on the east wall
        for i in 0..<4 {
            for j in 0..<3 {
                let cz: Float = -8.6 + Float(j) * 0.95
                let cy: Float = 0.14 + Float(i) * 0.28
                gar.mesh(mats.black).cylinder(base: Vec3(19.6, cy - 0.14, cz), radiusBottom: 0.33, radiusTop: 0.33, height: 0.26, segments: 12, u: 0.5, v: 0.5, capTop: true)
            }
        }
        collider(cx: 19.6, cz: -7.6, sx: 0.9, sz: 3.2, kind: ColliderKind.prop, height: 1.2)
        // lift posts beside the car spot
        boxRange(gar, mats.metal, x0: cs.x - 2.3, x1: cs.x - 2.1, y0: 0, y1: 3.0, z0: cs.y - 1.6, z1: cs.y - 1.4)
        boxRange(gar, mats.metal, x0: cs.x + 2.1, x1: cs.x + 2.3, y0: 0, y1: 3.0, z0: cs.y - 1.6, z1: cs.y - 1.4)
        boxRange(gar, mats.metal, x0: cs.x - 2.3, x1: cs.x + 2.3, y0: 2.9, y1: 3.0, z0: cs.y - 1.6, z1: cs.y - 1.4)
        collider(cx: cs.x - 2.2, cz: cs.y - 1.5, sx: 0.3, sz: 0.3, kind: ColliderKind.prop, height: 3)
        collider(cx: cs.x + 2.2, cz: cs.y - 1.5, sx: 0.3, sz: 0.3, kind: ColliderKind.prop, height: 3)
        // customise console (a kiosk with a glowing screen)
        boxRange(gar, mats.black, x0: 8.3, x1: 9.1, y0: 0, y1: 1.1, z0: 1.0, z1: 1.5)
        boxRange(gar, mats.neonCyan, x0: 8.35, x1: 9.05, y0: 0.75, y1: 1.05, z0: 1.5, z1: 1.52)
        collider(cx: 8.7, cz: 1.25, sx: 0.8, sz: 0.5, kind: ColliderKind.prop, height: 1.1)
        // workbench along the shared wall
        furniture(gar, mats.woodWarm, 6.8, -3.6, 0.8, 2.6, y0: 0.85, y1: 0.92)
        boxRange(gar, mats.metal, x0: 6.5, x1: 7.2, y0: 0, y1: 0.85, z0: -4.9, z1: -4.8)
        boxRange(gar, mats.metal, x0: 6.5, x1: 7.2, y0: 0, y1: 0.85, z0: -2.4, z1: -2.3)
        // ceiling strip lights
        for i in 0..<4 {
            let z: Float = -7 + Float(i) * 4.2
            boxRange(gar, mats.neonWhite, x0: 9.0, x1: 9.3, y0: ch - 0.05, y1: ch, z0: z, z1: z + 2.2)
            boxRange(gar, mats.neonWhite, x0: 17.6, x1: 17.9, y0: ch - 0.05, y1: ch, z0: z, z1: z + 2.2)
            addLight(Vec3(9.15, ch - 0.3, z + 1.1), color: UIColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1), intensity: 320, range: 9, garage: true)
        }
        // showroom spots (only on while the customise screen is open)
        for k in 0..<3 {
            let n = SCNNode()
            let l = SCNLight()
            l.type = SCNLight.LightType.spot
            l.color = UIColor(red: 1.0, green: 0.96, blue: 0.9, alpha: 1)
            l.intensity = 0
            l.spotInnerAngle = 30
            l.spotOuterAngle = 70
            l.attenuationEndDistance = 12
            l.categoryBitMask = 8
            n.light = l
            let a: Float = Float(k) / 3 * Float.tau
            n.simdPosition = Vec3(cs.x + cosf(a) * 3.2, ch - 0.2, cs.y + sinf(a) * 3.2)
            let aim: Vec3 = (Vec3(cs.x, 0.6, cs.y) - n.simdPosition).normalizedSafe
            n.simdOrientation = simd_quatf(from: Vec3(0, 0, -1), to: aim)
            garageNode.addChildNode(n)
            showroomSpots.append(n)
        }
    }
}
