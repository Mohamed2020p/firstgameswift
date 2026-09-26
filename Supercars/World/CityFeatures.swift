import Foundation
import SceneKit
import UIKit
import simd

// MARK: - WCityFeatures: the designed places on top of the generated city.
//   * Race complex at the start / finish line (starting grid, barriers, sponsor boards, marshal tower, grandstand, flags, direction signs,
//     starting light gantry) - physically on the road, connected to the street grid, selectable on the map.
//   * Civic block with the police station, its car park and parked police trucks.
//   * Taxi stands (shelter + sign) that pedestrians walk to and taxis serve.
//   * Two mini roundabouts.
// Restrained colours only: concrete, graphite, white, slate, muted red.  Everything static is merged per material.

@MainActor
final class WCityFeatures {
    let root = SCNNode()
    private(set) var taxiStops: [PedTaxiStop] = []
    private(set) var policePosition: Vec2 = Vec2(0, 0)
    private(set) var policeApproach: Vec2 = Vec2(0, 0)
    private(set) var paddockPosition: Vec2 = Vec2(0, 0)
    private(set) var roundabouts: [Vec2] = []

    private var groups: [(node: SCNNode, center: Vec2)] = []
    private var lightMats: [SCNMaterial] = []
    private var greenMat: SCNMaterial = SCNMaterial()
    private var lightsOnColour: UIColor = UIColor(red: 1.0, green: 0.12, blue: 0.08, alpha: 1)
    private var visTimer: Float = 0

    init() {
        root.name = "cityFeatures"
    }

    // MARK: materials

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, rough: Float = 0.85, metal: Float = 0) -> SCNMaterial {
        return MaterialFactory.pbr(color: UIColor(red: r, green: g, blue: b, alpha: 1), metalness: metal, roughness: rough)
    }

    /// flat ground layer material (no depth writes; drawn in the world's painter order)
    private func groundMat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = SCNMaterial.LightingModel.lambert
        m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    private func plateMaterial(_ text: String, size: CGSize, bg: UIColor, fg: UIColor, border: UIColor? = nil) -> SCNMaterial {
        let w: Int = Int(size.width)
        let h: Int = Int(size.height)
        let img: UIImage = WTex.render(w, h, opaque: true) { c in
            c.setFillColor(bg.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if let b = border {
                c.setStrokeColor(b.cgColor)
                c.setLineWidth(CGFloat(h) * 0.05)
                c.stroke(CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: CGFloat(h) * 0.08, dy: CGFloat(h) * 0.08))
            }
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let fs: CGFloat = CGFloat(h) * 0.46
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fs, weight: UIFont.Weight.semibold),
                .foregroundColor: fg,
                .paragraphStyle: para,
                .kern: fs * 0.06
            ]
            (text as NSString).draw(in: CGRect(x: 0, y: (CGFloat(h) - fs * 1.2) * 0.5, width: CGFloat(w), height: fs * 1.3), withAttributes: attrs)
        }
        let m = SCNMaterial()
        m.lightingModel = SCNMaterial.LightingModel.lambert
        m.diffuse.contents = img
        m.isDoubleSided = true
        return m
    }

    private func attach(_ set: WMeshSet, to parent: SCNNode, name: String, order: Int? = nil, shadows: Bool = false) {
        guard let g = set.makeGeometry() else { return }
        let n = SCNNode(geometry: g)
        n.name = name
        n.castsShadow = shadows
        if let o = order { n.renderingOrder = o }
        parent.addChildNode(n)
    }

    private func addGroup(_ name: String, center: Vec2) -> SCNNode {
        let n = SCNNode()
        n.name = name
        root.addChildNode(n)
        groups.append((n, center))
        return n
    }

    private func collider(_ world: ColliderWorld, box centre: Vec2, half: Vec2, heading: Float, height: Float, kind: ColliderKind = ColliderKind.prop) {
        let c = Collider.box(id: world.allocateID(), kind: kind, center: centre, halfExtents: half, heading: heading, height: height, mass: 1_000_000)
        world.add(c)
    }

    private func circleCollider(_ world: ColliderWorld, at p: Vec2, radius: Float, height: Float) {
        world.add(Collider.circle(id: world.allocateID(), kind: ColliderKind.prop, center: p, radius: radius, destructible: false, height: height, mass: 1_000_000))
    }

    // MARK: build

    func build(layout: WCityLayout, colliders: ColliderWorld, gate: Spawn, routeWidth: Float, assets: AssetLibrary) {
        buildRaceComplex(gate: gate, routeWidth: routeWidth, colliders: colliders)
        buildPoliceStation(layout: layout, colliders: colliders, assets: assets)
        buildTaxiStands(colliders: colliders)
        buildRoundabouts(colliders: colliders, assets: assets)
    }

    // MARK: race complex

    private func buildRaceComplex(gate g: Spawn, routeWidth: Float, colliders: ColliderWorld) {
        let centre: Vec2 = Vec2(g.position.x, g.position.z)
        let node: SCNNode = addGroup("raceComplex", center: centre)
        let xf = WXform(x: g.position.x, y: 0, z: g.position.z, heading: g.heading, scale: 1)
        func world(_ lx: Float, _ lz: Float) -> Vec2 {
            return centre + headingLeft2(g.heading) * lx + headingForward2(g.heading) * lz
        }
        let concrete: SCNMaterial = solid(0.66, 0.66, 0.64, rough: 0.9)
        let graphite: SCNMaterial = solid(0.13, 0.14, 0.155, rough: 0.6)
        let white: SCNMaterial = solid(0.90, 0.90, 0.88, rough: 0.7)
        let slate: SCNMaterial = solid(0.22, 0.27, 0.33, rough: 0.7)
        let seatLight: SCNMaterial = solid(0.55, 0.58, 0.62, rough: 0.8)
        let red: SCNMaterial = solid(0.55, 0.10, 0.10, rough: 0.7)
        let glass = MaterialFactory.glass(tint: UIColor(red: 0.12, green: 0.18, blue: 0.24, alpha: 1), opacity: 0.55, name: "towerGlass")
        let set = WMeshSet()

        // ---- starting grid (painted slots behind the line)
        let paint: SCNMaterial = groundMat(0.93, 0.93, 0.92)
        let paintSet = WMeshSet()
        let pm = paintSet.mesh(paint)
        for r in 0..<6 {
            let z: Float = -7 - Float(r) * 8
            for side in [Float(-1), Float(1)] {
                let x: Float = side * 3.4
                // a slot is a "U": back line + two short sides
                pm.quad(xf.p(Vec3(x - 1.5, 0.04, z - 2.6)), xf.p(Vec3(x + 1.5, 0.04, z - 2.6)), xf.p(Vec3(x + 1.5, 0.04, z - 2.45)), xf.p(Vec3(x - 1.5, 0.04, z - 2.45)), Vec3(0, 1, 0), 0, 0, 1, 1)
                pm.quad(xf.p(Vec3(x - 1.5, 0.04, z - 2.6)), xf.p(Vec3(x - 1.35, 0.04, z - 2.6)), xf.p(Vec3(x - 1.35, 0.04, z + 0.4)), xf.p(Vec3(x - 1.5, 0.04, z + 0.4)), Vec3(0, 1, 0), 0, 0, 1, 1)
                pm.quad(xf.p(Vec3(x + 1.35, 0.04, z - 2.6)), xf.p(Vec3(x + 1.5, 0.04, z - 2.6)), xf.p(Vec3(x + 1.5, 0.04, z + 0.4)), xf.p(Vec3(x + 1.35, 0.04, z + 0.4)), Vec3(0, 1, 0), 0, 0, 1, 1)
            }
        }
        attach(paintSet, to: node, name: "gridPaint", order: -28)

        // ---- barriers along both sides
        let half: Float = min(9.6, routeWidth * 0.5 + 1.6)
        var seg: Int = 0
        var zb: Float = -66
        while zb < 66 {
            let mat: SCNMaterial = seg % 2 == 0 ? white : graphite
            for side in [Float(-1), Float(1)] {
                set.mesh(mat).box(center: Vec3(side * half, 0.45, zb + 1.5), size: Vec3(0.55, 0.9, 3.0), u: 0.5, v: 0.5, xf: xf)
            }
            zb += 3.0
            seg += 1
        }
        for side in [Float(-1), Float(1)] {
            for k in 0..<11 {
                let z0: Float = -66 + Float(k) * 12
                collider(colliders, box: world(side * half, z0 + 6), half: Vec2(0.32, 6.1), heading: g.heading, height: 0.9, kind: ColliderKind.barrier)
            }
        }
        // tyre stacks at both ends
        for side in [Float(-1), Float(1)] {
            for zEnd in [Float(-68), Float(68)] {
                for level in 0..<3 {
                    set.mesh(graphite).cylinder(base: Vec3(side * (half - 0.2), Float(level) * 0.34, zEnd), radiusBottom: 0.42, radiusTop: 0.42, height: 0.32, segments: 10,
                                                u: 0.5, v: 0.5, capTop: true, xf: xf)
                }
                set.mesh(red).cylinder(base: Vec3(side * (half - 0.2), 1.02, zEnd), radiusBottom: 0.43, radiusTop: 0.43, height: 0.06, segments: 10, u: 0.5, v: 0.5, capTop: true, xf: xf)
            }
        }

        // ---- marshal tower (plaza side, x > 0)
        let tx: Float = 21
        let tz: Float = 14
        set.mesh(concrete).box(center: Vec3(tx, 1.9, tz), size: Vec3(9, 3.8, 11), u: 0.5, v: 0.5, xf: xf)
        set.mesh(graphite).box(center: Vec3(tx, 3.9, tz), size: Vec3(9.4, 0.25, 11.4), u: 0.5, v: 0.5, xf: xf)
        set.mesh(slate).box(center: Vec3(tx, 5.5, tz), size: Vec3(8.4, 3.0, 10.4), u: 0.5, v: 0.5, xf: xf)
        set.mesh(graphite).box(center: Vec3(tx, 7.15, tz), size: Vec3(9.0, 0.3, 11.0), u: 0.5, v: 0.5, xf: xf)
        collider(colliders, box: world(tx, tz), half: Vec2(4.6, 5.7), heading: g.heading, height: 7.4)
        let towerNode = SCNNode()
        towerNode.name = "towerGlass"
        let gset = WMeshSet()
        let gm = gset.mesh(glass)
        // glass band on the side facing the road (local -x) and the front (local -z)
        gm.quad(xf.p(Vec3(tx - 4.25, 4.1, tz - 5.0)), xf.p(Vec3(tx - 4.25, 4.1, tz + 5.0)), xf.p(Vec3(tx - 4.25, 6.9, tz + 5.0)), xf.p(Vec3(tx - 4.25, 6.9, tz - 5.0)),
                xf.n(Vec3(-1, 0, 0)), 0, 0, 1, 1)
        gm.quad(xf.p(Vec3(tx + 4.0, 4.1, tz - 5.25)), xf.p(Vec3(tx - 4.0, 4.1, tz - 5.25)), xf.p(Vec3(tx - 4.0, 6.9, tz - 5.25)), xf.p(Vec3(tx + 4.0, 6.9, tz - 5.25)),
                xf.n(Vec3(0, 0, -1)), 0, 0, 1, 1)
        attach(gset, to: node, name: "towerGlass")
        _ = towerNode
        let sign: SCNMaterial = plateMaterial("RACE CONTROL", size: CGSize(width: 512, height: 96), bg: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1),
                                              fg: UIColor(white: 0.94, alpha: 1), border: UIColor(red: 0.78, green: 0.66, blue: 0.44, alpha: 1))
        let sg = WMeshSet()
        let sm = sg.mesh(sign)
        sm.quad(xf.p(Vec3(tx - 4.3, 3.0, tz - 4.0)), xf.p(Vec3(tx - 4.3, 3.0, tz + 4.0)), xf.p(Vec3(tx - 4.3, 3.75, tz + 4.0)), xf.p(Vec3(tx - 4.3, 3.75, tz - 4.0)),
                xf.n(Vec3(-1, 0, 0)), 0, 0, 1, 1)
        attach(sg, to: node, name: "towerSign")
        paddockPosition = world(tx - 6, tz)

        // ---- grandstand (plaza side, behind the barrier)
        let gx: Float = 17.5
        for row in 0..<6 {
            let h: Float = 0.5 + Float(row) * 0.5
            set.mesh(concrete).box(center: Vec3(gx + Float(row) * 0.95, h * 0.5, -22), size: Vec3(0.95, h, 30), u: 0.5, v: 0.5, xf: xf)
            set.mesh(seatLight).box(center: Vec3(gx + Float(row) * 0.95 - 0.1, h + 0.04, -22), size: Vec3(0.5, 0.08, 29), u: 0.5, v: 0.5, xf: xf)
        }
        collider(colliders, box: world(gx + 2.7, -22), half: Vec2(3.0, 15.2), heading: g.heading, height: 3.0)
        for zp in [Float(-36), Float(-8)] {
            set.mesh(graphite).box(center: Vec3(gx + 5.9, 2.9, zp), size: Vec3(0.25, 5.8, 0.25), u: 0.5, v: 0.5, xf: xf)
        }
        set.mesh(graphite).box(center: Vec3(gx + 4.2, 5.85, -22), size: Vec3(6.6, 0.22, 31), u: 0.5, v: 0.5, xf: xf)

        // ---- flag poles with cloth
        let cloth: SCNNode = SCNNode()
        cloth.name = "flags"
        let checker: UIImage = WTex.render(128, 64, opaque: true) { c in
            for i in 0..<8 {
                for j in 0..<4 {
                    let dark: Bool = (i + j) % 2 == 0
                    c.setFillColor(dark ? WTex.col(0.06, 0.06, 0.06) : WTex.col(0.94, 0.94, 0.94))
                    c.fill(CGRect(x: i * 16, y: j * 16, width: 16, height: 16))
                }
            }
        }
        func clothMaterial(_ contents: Any) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = contents
            m.isDoubleSided = true
            m.lightingModel = SCNMaterial.LightingModel.lambert
            return m
        }
        let clothColours: [SCNMaterial] = [
            clothMaterial(checker),
            clothMaterial(UIColor(red: 0.55, green: 0.10, blue: 0.10, alpha: 1)),
            clothMaterial(UIColor(white: 0.9, alpha: 1))
        ]
        var fi: Int = 0
        for lz in stride(from: Float(-42), through: Float(42), by: 21) {
            for side in [Float(1), Float(-1)] {
                let lx: Float = side * 14.6
                set.mesh(graphite).cylinder(base: Vec3(lx, 0, lz), radiusBottom: 0.09, radiusTop: 0.06, height: 9.5, segments: 6, u: 0.5, v: 0.5, capTop: true, xf: xf)
                let plane = SCNPlane(width: 2.4, height: 1.5)
                plane.materials = [clothColours[fi % clothColours.count]]
                let fn = SCNNode(geometry: plane)
                let wp: Vec2 = world(lx, lz)
                fn.simdPosition = Vec3(wp.x, 8.5, wp.y) + headingForward(g.heading) * 1.2
                fn.simdEulerAngles = Vec3(0, g.heading + Float.pi * 0.5, 0)
                cloth.addChildNode(fn)
                circleCollider(colliders, at: wp, radius: 0.18, height: 9)
                fi += 1
            }
        }
        node.addChildNode(cloth)

        // ---- sponsor boards on the barriers
        let boardA: SCNMaterial = plateMaterial("SUPERCARS  GRAND PRIX", size: CGSize(width: 1024, height: 128), bg: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1),
                                                fg: UIColor(white: 0.95, alpha: 1), border: UIColor(red: 0.78, green: 0.66, blue: 0.44, alpha: 1))
        let boardB: SCNMaterial = plateMaterial("c0derz", size: CGSize(width: 512, height: 128), bg: UIColor(red: 0.80, green: 0.80, blue: 0.78, alpha: 1),
                                                fg: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1))
        let bs = WMeshSet()
        for (k, z) in [Float(-30), Float(30)].enumerated() {
            for side in [Float(-1), Float(1)] {
                let mat: SCNMaterial = (k + (side > 0 ? 1 : 0)) % 2 == 0 ? boardA : boardB
                let len: Float = mat === boardA ? 8.0 : 4.0
                let x: Float = side * (half - 0.29)
                let nrm: Vec3 = xf.n(Vec3(-side, 0, 0))
                let a: Vec3 = xf.p(Vec3(x, 0.15, z - len * 0.5))
                let b: Vec3 = xf.p(Vec3(x, 0.15, z + len * 0.5))
                let c: Vec3 = xf.p(Vec3(x, 0.85, z + len * 0.5))
                let d: Vec3 = xf.p(Vec3(x, 0.85, z - len * 0.5))
                if side > 0 { bs.mesh(mat).quad(a, b, c, d, nrm, 0, 0, 1, 1) } else { bs.mesh(mat).quad(b, a, d, c, nrm, 0, 0, 1, 1) }
            }
        }
        attach(bs, to: node, name: "boards")
        attach(set, to: node, name: "raceStatic", shadows: true)

        // ---- direction signs at the approaches (pointing to the start line)
        let signs: [(Vec2, Float, String)] = [
            (Vec2(-140 + 17, -420 + 13.5), Float.pi * 0.5, "◀  RACE START"),
            (Vec2(-280 - 17, -420 - 13.5), -Float.pi * 0.5, "RACE START  ▶"),
            (Vec2(-140 + 13.5, -420 - 17), Float.pi, "◀  RACE START"),
            (Vec2(-280 - 13.5, -420 + 17), 0, "RACE START  ▶")
        ]
        let signGroup: SCNNode = addGroup("raceSigns", center: centre)
        for s in signs {
            let pole = SCNCylinder(radius: 0.07, height: 3.4)
            pole.materials = [graphite]
            let pn = SCNNode(geometry: pole)
            pn.simdPosition = Vec3(s.0.x, 1.7, s.0.y)
            signGroup.addChildNode(pn)
            let plateMat: SCNMaterial = plateMaterial(s.2, size: CGSize(width: 512, height: 128), bg: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1),
                                                      fg: UIColor(white: 0.95, alpha: 1), border: UIColor(red: 0.78, green: 0.66, blue: 0.44, alpha: 1))
            let plane = SCNPlane(width: 2.6, height: 0.65)
            plane.materials = [plateMat]
            let plate = SCNNode(geometry: plane)
            plate.simdPosition = Vec3(s.0.x, 3.1, s.0.y)
            plate.simdEulerAngles = Vec3(0, s.1, 0)
            signGroup.addChildNode(plate)
            circleCollider(colliders, at: s.0, radius: 0.15, height: 3.4)
        }

        // ---- starting lights under the gate beam (3 red + 1 green)
        let lights: SCNNode = SCNNode()
        lights.name = "startLights"
        lights.simdPosition = g.position
        lights.simdEulerAngles = Vec3(0, g.heading, 0)
        for k in 0..<4 {
            let disc = SCNCylinder(radius: 0.34, height: 0.12)
            let m = SCNMaterial()
            m.lightingModel = SCNMaterial.LightingModel.constant
            m.diffuse.contents = UIColor(red: 0.16, green: 0.04, blue: 0.04, alpha: 1)
            m.emission.contents = k == 3 ? UIColor(red: 0.20, green: 1.0, blue: 0.35, alpha: 1) : lightsOnColour
            m.emission.intensity = 0
            disc.materials = [m]
            let n = SCNNode(geometry: disc)
            n.simdPosition = Vec3(-3.0 + Float(k) * 2.0, 7.25, -0.5)
            n.simdEulerAngles = Vec3(Float.pi * 0.5, 0, 0)
            lights.addChildNode(n)
            if k == 3 { greenMat = m } else { lightMats.append(m) }
        }
        node.addChildNode(lights)
    }

    /// countdown lights: `red` lit red discs (0...3) and the green one
    func setStartLights(red: Int, green: Bool) {
        for (i, m) in lightMats.enumerated() {
            let on: Bool = i < red
            m.emission.intensity = on ? 1.6 : 0
            m.diffuse.contents = on ? UIColor(red: 0.85, green: 0.08, blue: 0.06, alpha: 1) : UIColor(red: 0.16, green: 0.04, blue: 0.04, alpha: 1)
        }
        greenMat.emission.intensity = green ? 1.6 : 0
        greenMat.diffuse.contents = green ? UIColor(red: 0.15, green: 0.75, blue: 0.30, alpha: 1) : UIColor(red: 0.04, green: 0.14, blue: 0.06, alpha: 1)
    }

    // MARK: police station

    private func buildPoliceStation(layout: WCityLayout, colliders: ColliderWorld, assets: AssetLibrary) {
        guard let block = layout.blockAt(i: 2, j: 3) else { return }
        let r: WRect = block.rect
        let cx: Float = (r.x0 + r.x1) * 0.5
        let node: SCNNode = addGroup("policeStation", center: Vec2(cx, (r.z0 + r.z1) * 0.5))
        let concrete: SCNMaterial = solid(0.74, 0.74, 0.72, rough: 0.9)
        let base: SCNMaterial = solid(0.28, 0.29, 0.31, rough: 0.8)
        let roof: SCNMaterial = solid(0.18, 0.19, 0.21, rough: 0.7)
        let glass = MaterialFactory.glass(tint: UIColor(red: 0.10, green: 0.16, blue: 0.22, alpha: 1), opacity: 0.6, name: "policeGlass")
        let lawn: SCNMaterial = solid(0.18, 0.32, 0.16, rough: 1)
        let set = WMeshSet()

        // building along the north side, facing south (-z)
        let bw: Float = 46
        let bd: Float = 16
        let bh: Float = 12
        let bz: Float = r.z1 - 9 - bd * 0.5
        set.mesh(concrete).box(center: Vec3(cx, bh * 0.5, bz), size: Vec3(bw, bh, bd), u: 0.5, v: 0.5)
        set.mesh(base).box(center: Vec3(cx, 0.6, bz), size: Vec3(bw + 0.3, 1.2, bd + 0.3), u: 0.5, v: 0.5)
        set.mesh(roof).box(center: Vec3(cx, bh + 0.25, bz), size: Vec3(bw + 0.8, 0.5, bd + 0.8), u: 0.5, v: 0.5)
        set.mesh(roof).box(center: Vec3(cx, bh + 1.0, bz + 3), size: Vec3(12, 1.4, 6), u: 0.5, v: 0.5)
        collider(colliders, box: Vec2(cx, bz), half: Vec2(bw * 0.5, bd * 0.5), heading: 0, height: bh + 1)
        // glass bands on the front
        let gset = WMeshSet()
        let gm = gset.mesh(glass)
        let fz: Float = bz - bd * 0.5 - 0.03
        for k in 0..<2 {
            let y0: Float = 2.2 + Float(k) * 4.2
            gm.quad(Vec3(cx + bw * 0.5 - 2, y0, fz), Vec3(cx - bw * 0.5 + 2, y0, fz), Vec3(cx - bw * 0.5 + 2, y0 + 2.6, fz), Vec3(cx + bw * 0.5 - 2, y0 + 2.6, fz),
                    Vec3(0, 0, -1), 0, 0, 1, 1)
        }
        attach(gset, to: node, name: "policeGlass")
        // sign
        let sign: SCNMaterial = plateMaterial("POLICE", size: CGSize(width: 512, height: 128), bg: UIColor(red: 0.07, green: 0.10, blue: 0.18, alpha: 1),
                                              fg: UIColor(white: 0.96, alpha: 1), border: UIColor(white: 0.85, alpha: 1))
        let sg = WMeshSet()
        sg.mesh(sign).quad(Vec3(cx + 5.5, 9.6, fz - 0.02), Vec3(cx - 5.5, 9.6, fz - 0.02), Vec3(cx - 5.5, 11.6, fz - 0.02), Vec3(cx + 5.5, 11.6, fz - 0.02), Vec3(0, 0, -1), 0, 0, 1, 1)
        attach(sg, to: node, name: "policeSign")

        // car park south of the building
        let lotMat: SCNMaterial = groundMat(0.16, 0.165, 0.17)
        let lineMat: SCNMaterial = groundMat(0.90, 0.90, 0.88)
        let lotSet = WMeshSet()
        let lot = lotSet.mesh(lotMat)
        let lx0: Float = cx - 50
        let lx1: Float = cx + 50
        let lz0: Float = r.z0 + 3
        let lz1: Float = bz - bd * 0.5 - 6
        lot.groundRect(max(lx0, r.x0 + 2), lz0, min(lx1, r.x1 - 2), lz1, y: 0.035, tile: 8)
        let lines = lotSet.mesh(lineMat)
        var bx: Float = max(lx0, r.x0 + 2) + 4
        while bx < min(lx1, r.x1 - 2) - 3 {
            for rowZ in [lz1 - 6, lz0 + 12] {
                lines.groundRect(bx, rowZ - 2.6, bx + 0.12, rowZ + 2.6, y: 0.04, tile: 1)
            }
            bx += 3.0
        }
        attach(lotSet, to: node, name: "policeLot", order: -35)
        // lawn strip in front of the building + entrance path
        let lawnSet = WMeshSet()
        lawnSet.mesh(lawn).box(center: Vec3(cx, 0.05, lz1 + 3), size: Vec3(bw + 8, 0.1, 6), u: 0.5, v: 0.5)
        attach(lawnSet, to: node, name: "policeLawn")

        // flags + parked trucks
        let pole: SCNMaterial = solid(0.7, 0.7, 0.72, rough: 0.4, metal: 0.8)
        for k in 0..<2 {
            let fx: Float = cx + (k == 0 ? -8.5 : 8.5)
            set.mesh(pole).cylinder(base: Vec3(fx, 0, lz1 + 2.5), radiusBottom: 0.1, radiusTop: 0.06, height: 8, segments: 6, u: 0.5, v: 0.5, capTop: true)
            circleCollider(colliders, at: Vec2(fx, lz1 + 2.5), radius: 0.2, height: 8)
        }
        attach(set, to: node, name: "policeStatic", shadows: true)
        for k in 0..<3 {
            guard let truck = try? assets.model("police") else { break }
            let tx: Float = cx - 12 + Float(k) * 7.5
            let tz: Float = lz1 - 6
            truck.simdPosition = Vec3(tx, 0, tz)
            truck.simdEulerAngles = Vec3(0, Float.pi + 0.0, 0)
            truck.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
                if n.geometry != nil {
                    n.castsShadow = true
                    n.categoryBitMask = 1
                }
            }
            node.addChildNode(truck)
            collider(colliders, box: Vec2(tx, tz), half: Vec2(1.05, 2.6), heading: Float.pi, height: 1.9)
        }
        policePosition = Vec2(cx, lz1 - 2)
        policeApproach = Vec2(cx, r.z0 - 4)
    }

    // MARK: taxi stands

    private func buildTaxiStands(colliders: ColliderWorld) {
        // (street orientation, grid line index, side, coordinate along the street)
        struct Stand {
            var alongX: Bool
            var line: Int
            var side: Float
            var at: Float
            var name: String
        }
        let stands: [Stand] = [
            Stand(alongX: true, line: 0, side: 1, at: -70, name: "Boulevard West"),
            Stand(alongX: true, line: 0, side: -1, at: 70, name: "Boulevard East"),
            Stand(alongX: true, line: -3, side: 1, at: -245, name: "Plaza Stand"),
            Stand(alongX: true, line: 1, side: 1, at: 210, name: "Midtown Stand"),
            Stand(alongX: false, line: 2, side: -1, at: -70, name: "Market Stand"),
            Stand(alongX: true, line: 4, side: -1, at: 350, name: "Civic Stand")
        ]
        let node: SCNNode = addGroup("taxiStands", center: Vec2(0, 0))
        let graphite: SCNMaterial = solid(0.13, 0.14, 0.155, rough: 0.5, metal: 0.3)
        let roofMat: SCNMaterial = solid(0.85, 0.66, 0.16, rough: 0.6)
        let bench: SCNMaterial = solid(0.40, 0.30, 0.20, rough: 0.9)
        let set = WMeshSet()
        for (k, s) in stands.enumerated() {
            var p: Vec2 = Vec2(0, 0)
            var faceRoad: Vec2 = Vec2(0, 0)
            var lx: Vec2 = Vec2(1, 0)
            if s.alongX {
                p = Vec2(s.at, WGrid.line(s.line) + s.side * WGrid.walkOffset(s.line))
                faceRoad = Vec2(0, -s.side)
                lx = Vec2(1, 0)
            } else {
                p = Vec2(WGrid.line(s.line) + s.side * WGrid.walkOffset(s.line), s.at)
                faceRoad = Vec2(-s.side, 0)
                lx = Vec2(0, 1)
            }
            let heading: Float = headingOf(lx)
            let xf = WXform(x: p.x, y: 0, z: p.y, heading: heading, scale: 1)
            // shelter: two posts along the street, a roof and a bench at the back (away from the road)
            let backSign: Float = simd_dot(headingLeft2(heading), faceRoad * -1) >= 0 ? 1 : -1
            for sz in [Float(-1.4), Float(1.4)] {
                set.mesh(graphite).box(center: Vec3(0.75 * backSign, 1.25, sz), size: Vec3(0.1, 2.5, 0.1), u: 0.5, v: 0.5, xf: xf)
            }
            set.mesh(roofMat).box(center: Vec3(0.2 * backSign, 2.55, 0), size: Vec3(2.0, 0.12, 3.2), u: 0.5, v: 0.5, xf: xf)
            set.mesh(bench).box(center: Vec3(0.6 * backSign, 0.45, 0), size: Vec3(0.4, 0.08, 2.2), u: 0.5, v: 0.5, xf: xf)
            // sign post with a taxi plate
            let signPost = SCNCylinder(radius: 0.05, height: 3.0)
            signPost.materials = [graphite]
            let sp = SCNNode(geometry: signPost)
            sp.simdPosition = Vec3(p.x + lx.x * 2.2, 1.5, p.y + lx.y * 2.2)
            node.addChildNode(sp)
            let plateMat: SCNMaterial = plateMaterial("TAXI", size: CGSize(width: 256, height: 96), bg: UIColor(red: 0.85, green: 0.66, blue: 0.16, alpha: 1),
                                                      fg: UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
            let plane = SCNPlane(width: 0.9, height: 0.34)
            plane.materials = [plateMat]
            let plate = SCNNode(geometry: plane)
            plate.simdPosition = Vec3(p.x + lx.x * 2.2, 2.9, p.y + lx.y * 2.2)
            plate.simdEulerAngles = Vec3(0, headingOf(faceRoad), 0)
            node.addChildNode(plate)
            collider(colliders, box: p + lx * 2.2, half: Vec2(0.15, 0.15), heading: 0, height: 3)
            collider(colliders, box: p, half: Vec2(0.3, 0.3), heading: heading, height: 2.5)
            taxiStops.append(PedTaxiStop(position: p + faceRoad * -0.3, facing: headingOf(faceRoad), name: s.name))
            _ = k
        }
        attach(set, to: node, name: "taxiStandsStatic", shadows: true)
    }

    // MARK: mini roundabouts

    private func buildRoundabouts(colliders: ColliderWorld, assets: AssetLibrary) {
        let nodes: [WGridNode] = [WGridNode(i: 3, j: 3), WGridNode(i: -3, j: -3)]
        let curb: SCNMaterial = solid(0.68, 0.68, 0.66, rough: 0.9)
        let soil: SCNMaterial = solid(0.22, 0.30, 0.16, rough: 1)
        let ring: SCNMaterial = groundMat(0.93, 0.93, 0.92)
        for n in nodes {
            let c: Vec2 = n.position
            roundabouts.append(c)
            let g: SCNNode = addGroup("roundabout_\(n.i)_\(n.j)", center: c)
            let set = WMeshSet()
            set.mesh(curb).cylinder(base: Vec3(c.x, 0, c.y), radiusBottom: 3.4, radiusTop: 3.4, height: 0.24, segments: 28, u: 0.5, v: 0.5, capTop: true)
            set.mesh(soil).cylinder(base: Vec3(c.x, 0.24, c.y), radiusBottom: 3.0, radiusTop: 2.6, height: 0.35, segments: 28, u: 0.5, v: 0.5, capTop: true)
            attach(set, to: g, name: "roundaboutIsland", shadows: false)
            let paintSet = WMeshSet()
            let pm = paintSet.mesh(ring)
            let segs: Int = 40
            for i in 0..<segs {
                if i % 2 == 1 { continue }
                let a0: Float = Float(i) / Float(segs) * Float.tau
                let a1: Float = Float(i + 1) / Float(segs) * Float.tau
                let d0 = Vec2(cosf(a0), sinf(a0))
                let d1 = Vec2(cosf(a1), sinf(a1))
                pm.groundQuad(c + d0 * 6.0, c + d1 * 6.0, c + d1 * 6.25, c + d0 * 6.25, y: 0.05, tile: 1)
            }
            attach(paintSet, to: g, name: "roundaboutPaint", order: -28)
            if let tree = try? assets.model("tree_lod1") {
                tree.simdPosition = Vec3(c.x, 0.5, c.y)
                tree.simdScale = Vec3(0.55, 0.55, 0.55)
                g.addChildNode(tree)
            }
            circleCollider(colliders, at: c, radius: 3.4, height: 1)
        }
    }

    // MARK: per frame

    func update(dt: Float, focus: Vec2) {
        visTimer -= dt
        if visTimer > 0 { return }
        visTimer = 0.6
        for g in groups {
            let hidden: Bool = simd_distance(g.center, focus) > 520
            if g.node.isHidden != hidden { g.node.isHidden = hidden }
        }
    }

    // MARK: waypoints

    func registerWaypoints(into registry: WaypointRegistry, spawn: SpawnPoints, layout: WCityLayout) {
        let houseXZ: Vec2 = Vec2(spawn.house.position.x, spawn.house.position.z)
        let carXZ: Vec2 = Vec2(spawn.car.position.x, spawn.car.position.z)
        registry.register(MapWaypoint(id: "home", name: "Home", subtitle: "Your house on Summit Lane", kind: WaypointKind.home, position: houseXZ, routeTarget: carXZ))
        let garageXZ: Vec2 = Vec2(spawn.garageDoor.position.x, spawn.garageDoor.position.z)
        registry.register(MapWaypoint(id: "garage", name: "Garage", subtitle: "Customise and store your cars", kind: WaypointKind.garage, position: garageXZ, routeTarget: carXZ))
        let gate: Vec2 = Vec2(spawn.raceGate.position.x, spawn.raceGate.position.z)
        registry.register(MapWaypoint(id: "raceStart", name: "Race Start", subtitle: "Downtown Grand Prix", kind: WaypointKind.raceStart, position: gate, routeTarget: gate))
        registry.register(MapWaypoint(id: "raceFinish", name: "Race Finish", subtitle: "Paddock and race control", kind: WaypointKind.raceFinish, position: paddockPosition, routeTarget: gate))
        if policePosition != Vec2(0, 0) {
            registry.register(MapWaypoint(id: "police", name: "Police Station", subtitle: "Civic Centre", kind: WaypointKind.policeStation, position: policePosition,
                                          routeTarget: policeApproach))
        }
        for (i, s) in taxiStops.enumerated() {
            registry.register(MapWaypoint(id: "taxi\(i + 1)", name: "Taxi Stand", subtitle: s.name, kind: WaypointKind.taxiStand, position: s.position, routeTarget: s.position))
        }
        // districts: average block centre of each kind
        var sums: [String: (Vec2, Int)] = [:]
        for b in layout.blocks {
            var key: String = ""
            switch b.kind {
            case .downtown: key = "downtown"
            case .midrise: key = "midtown"
            case .residential: key = (b.i >= 1 && b.j >= 1) ? "luxury" : "residential"
            case .industrial: key = "industrial"
            case .park: key = "park"
            case .plaza: key = "plaza"
            case .civic: key = "civic"
            }
            let c: Vec2 = b.rect.center
            let cur: (Vec2, Int) = sums[key] ?? (Vec2(0, 0), 0)
            sums[key] = (cur.0 + c, cur.1 + 1)
        }
        func centre(_ k: String) -> Vec2? {
            guard let s = sums[k], s.1 > 0 else { return nil }
            return s.0 / Float(s.1)
        }
        func addDistrict(_ id: String, _ name: String, _ sub: String, _ kind: WaypointKind, _ key: String, fallback: Vec2? = nil) {
            guard let c = centre(key) ?? fallback else { return }
            let n: WGridNode = WGridNode.nearest(to: c)
            registry.register(MapWaypoint(id: id, name: name, subtitle: sub, kind: kind, position: c, routeTarget: n.position))
        }
        addDistrict("downtown", "Downtown", "Towers, shops and the main boulevard", WaypointKind.downtown, "downtown", fallback: Vec2(0, 0))
        addDistrict("residential", "Residential", "Family houses and quiet streets", WaypointKind.residential, "residential")
        addDistrict("luxury", "Luxury Residential", "Large houses, wide streets", WaypointKind.luxuryResidential, "luxury")
        addDistrict("industrial", "Industrial District", "Warehouses and yards", WaypointKind.industrial, "industrial")
        if let p = layout.parkRects.first {
            let n: WGridNode = WGridNode.nearest(to: p.center)
            registry.register(MapWaypoint(id: "park", name: "City Park", subtitle: "Trees, lawn and the pond", kind: WaypointKind.park, position: p.center, routeTarget: n.position))
        }
        if layout.plazaRect.width > 10 {
            let c: Vec2 = layout.plazaRect.center
            let n: WGridNode = WGridNode.nearest(to: c)
            registry.register(MapWaypoint(id: "plaza", name: "City Plaza", subtitle: "Fountain and events", kind: WaypointKind.plaza, position: c, routeTarget: n.position))
        }
    }
}
