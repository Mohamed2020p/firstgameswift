import Foundation
import SceneKit
import simd
import UIKit

// MARK: - car_meta.json (every field optional: the pipeline may not have produced it yet)

struct VehicleMeta: Decodable {
    var length: Float?
    var width: Float?
    var height: Float?
    var wheelbase: Float?
    var trackFront: Float?
    var trackRear: Float?
    var wheelRadiusFront: Float?
    var wheelRadiusRear: Float?
    var frontAxleZ: Float?
    var rearAxleZ: Float?
    var cgZ: Float?
    var driverEye: [Float]?
    var driverHip: [Float]?
    var steeringHub: [Float]?
    var steeringAxis: [Float]?
    var steeringRadius: Float?
    var gripLeft: [Float]?
    var gripRight: [Float]?
    var doorDriver: [Float]?
    var pedalThrottle: [Float]?
    var pedalBrake: [Float]?
    var exhausts: [[Float]]?
    var headlights: [[Float]]?
    var taillights: [[Float]]?
    var wingNodes: [String]?

    static func vec(_ a: [Float]?, _ fallback: Vec3) -> Vec3 {
        guard let arr = a, arr.count >= 3 else { return fallback }
        return Vec3(arr[0], arr[1], arr[2])
    }

    static func vecList(_ a: [[Float]]?, _ fallback: [Vec3]) -> [Vec3] {
        guard let list = a, !list.isEmpty else { return fallback }
        var out: [Vec3] = []
        for arr in list where arr.count >= 3 { out.append(Vec3(arr[0], arr[1], arr[2])) }
        return out.isEmpty ? fallback : out
    }
}

// MARK: - node lookup

enum VehicleParts {
    /// exact name first, then case-insensitive
    static func find(_ root: SCNNode, _ name: String) -> SCNNode? {
        if let n = root.childNode(withName: name, recursively: true) { return n }
        let lower: String = name.lowercased()
        var found: SCNNode? = nil
        root.enumerateHierarchy { (n: SCNNode, stop: UnsafeMutablePointer<ObjCBool>) in
            if let nm = n.name, nm.lowercased() == lower {
                found = n
                stop.pointee = true
            }
        }
        return found
    }

    static func isAncestor(_ ancestor: SCNNode, of node: SCNNode) -> Bool {
        var p: SCNNode? = node
        while let q = p {
            if q === ancestor { return true }
            p = q.parent
        }
        return false
    }
}

// MARK: - paint / materials

@MainActor
final class CarCustomizer {
    private static let managed: [String] = ["carpaint", "glass", "rim", "caliper", "taillight", "headlight"]

    private var byName: [String: [SCNMaterial]] = [:]
    private var liveryDiffuse: Any? = nil
    private var liveryMetal: Any? = nil
    private var liveryRough: Any? = nil
    private var tintValue: Float = 0.75
    private var insideView: Bool = false
    private var lightsInitialised: Bool = false
    private var lastBrake: Bool = false
    private var lastNight: Bool = false
    private var lastHeadlights: Bool = false

    /// Clones every material that will be re-coloured so several cars (player, garage, AI) never share them.
    init(root: SCNNode) {
        root.enumerateHierarchy { (n: SCNNode, stop: UnsafeMutablePointer<ObjCBool>) in
            guard let g = n.geometry else { return }
            var needs: Bool = false
            for m in g.materials {
                if let nm = m.name, CarCustomizer.isManaged(nm) { needs = true }
            }
            if !needs { return }
            guard let gc = g.copy() as? SCNGeometry else { return }
            var mats: [SCNMaterial] = []
            for m in g.materials {
                if let nm = m.name, CarCustomizer.isManaged(nm), let mc = m.copy() as? SCNMaterial {
                    mc.name = nm
                    mats.append(mc)
                    self.register(nm, mc)
                } else {
                    mats.append(m)
                }
            }
            gc.materials = mats
            n.geometry = gc
        }
        if let first = materials("carpaint").first {
            liveryDiffuse = first.diffuse.contents
            liveryMetal = first.metalness.contents
            liveryRough = first.roughness.contents
        }
    }

    private static func isManaged(_ name: String) -> Bool {
        for p in managed where name.hasPrefix(p) { return true }
        return false
    }

    private func register(_ name: String, _ m: SCNMaterial) {
        var key: String = name
        for p in CarCustomizer.managed where name.hasPrefix(p) { key = p }
        var list: [SCNMaterial] = byName[key] ?? []
        list.append(m)
        byName[key] = list
    }

    func materials(_ key: String) -> [SCNMaterial] {
        return byName[key] ?? []
    }

    // MARK: config

    func apply(_ cfg: CarConfig) {
        applyPaint(hex: cfg.paint, finish: cfg.finish, livery: cfg.livery)
        let rimColor: UIColor = UIColor(hexString: cfg.rims)
        for m in materials("rim") {
            m.diffuse.contents = rimColor
            m.metalness.contents = NSNumber(value: 0.85)
            m.roughness.contents = NSNumber(value: 0.28)
        }
        let calColor: UIColor = UIColor(hexString: cfg.caliper)
        for m in materials("caliper") {
            m.diffuse.contents = calColor
            m.metalness.contents = NSNumber(value: 0.3)
            m.roughness.contents = NSNumber(value: 0.4)
        }
        tintValue = cfg.tint
        applyGlass()
    }

    func applyPaint(hex: String, finish: PaintFinish, livery: Bool) {
        let useLivery: Bool = livery && liveryDiffuse != nil
        let color: UIColor = UIColor(hexString: hex)
        let pbr: (metalness: Float, roughness: Float) = finish.pbr
        for m in materials("carpaint") {
            if useLivery {
                m.diffuse.contents = liveryDiffuse
                m.metalness.contents = liveryMetal ?? NSNumber(value: 0.3)
                m.roughness.contents = liveryRough ?? NSNumber(value: 0.35)
            } else {
                m.diffuse.contents = color
                m.metalness.contents = NSNumber(value: pbr.metalness)
                m.roughness.contents = NSNumber(value: pbr.roughness)
            }
        }
    }

    func setInsideView(_ inside: Bool) {
        if insideView == inside { return }
        insideView = inside
        applyGlass()
    }

    private func applyGlass() {
        let eff: Float = insideView ? min(tintValue, 0.4) * 0.6 : tintValue
        let opacity: CGFloat = CGFloat(0.10 + 0.75 * clampf(eff, 0, 1))
        for m in materials("glass") {
            m.diffuse.contents = UIColor(white: 0.03, alpha: 1)
            m.transparency = opacity
            m.blendMode = .alpha
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
        }
    }

    // MARK: lights

    private func initLights() {
        if lightsInitialised { return }
        lightsInitialised = true
        for m in materials("taillight") {
            m.emission.contents = UIColor(red: 1.0, green: 0.03, blue: 0.02, alpha: 1)
            m.emission.intensity = 0.08
        }
        for m in materials("headlight") {
            m.emission.contents = UIColor(red: 1.0, green: 0.95, blue: 0.78, alpha: 1)
            m.emission.intensity = 0
        }
    }

    func setBrakeLights(_ braking: Bool, night: Bool) {
        initLights()
        if braking == lastBrake && night == lastNight { return }
        lastBrake = braking
        lastNight = night
        let level: CGFloat = braking ? 1.8 : (night ? 0.5 : 0.08)
        for m in materials("taillight") { m.emission.intensity = level }
    }

    func setHeadlights(_ on: Bool) {
        initLights()
        if on == lastHeadlights { return }
        lastHeadlights = on
        for m in materials("headlight") { m.emission.intensity = on ? 2.2 : 0 }
    }
}

// MARK: - wheel / body rig shared by the player car and the AI cars

struct CarPart {
    let node: SCNNode
    let rest: simd_quatf
}

@MainActor
final class CarVisualRig {
    let root: SCNNode
    private(set) var body: SCNNode? = nil
    private(set) var interior: SCNNode? = nil
    private(set) var steeringWheel: SCNNode? = nil
    private(set) var glass: SCNNode? = nil
    private(set) var wingGT3: SCNNode? = nil
    private(set) var wingBig: SCNNode? = nil
    private(set) var pivot: SCNNode? = nil
    private var pivotBase: Vec3 = Vec3(0, 0.35, 0)
    private var steerParts: [CarPart] = []
    private var frontWheels: [CarPart] = []
    private var rearWheels: [CarPart] = []
    private var cockpitHidden: [SCNNode] = []
    private(set) var hasSteerPivot: Bool = false

    init(root: SCNNode, wingNames: [String]) {
        self.root = root
        body = VehicleParts.find(root, "body")
        interior = VehicleParts.find(root, "interior")
        steeringWheel = VehicleParts.find(root, "steering_wheel")
        glass = VehicleParts.find(root, "glass")
        var gtName: String = "wing_gt3"
        var bigName: String = "wing_big"
        if wingNames.count >= 2 {
            gtName = wingNames[0]
            bigName = wingNames[1]
        }
        wingGT3 = VehicleParts.find(root, gtName)
        wingBig = VehicleParts.find(root, bigName)

        for nm in ["steer_FL", "steer_FR"] {
            if let n = VehicleParts.find(root, nm) { steerParts.append(CarPart(node: n, rest: n.simdOrientation)) }
        }
        hasSteerPivot = !steerParts.isEmpty
        for nm in ["wheel_FL", "wheel_FR"] {
            if let n = VehicleParts.find(root, nm) { frontWheels.append(CarPart(node: n, rest: n.simdOrientation)) }
        }
        for nm in ["wheel_RL", "wheel_RR"] {
            if let n = VehicleParts.find(root, nm) { rearWheels.append(CarPart(node: n, rest: n.simdOrientation)) }
        }
        buildPivot()
        collectCockpitHidden()
    }

    var hasWheels: Bool { return !frontWheels.isEmpty || !rearWheels.isEmpty }

    private func buildPivot() {
        guard let b = body, let parent = b.parent else { return }
        var wheelish: [SCNNode] = []
        for p in steerParts { wheelish.append(p.node) }
        for p in frontWheels { wheelish.append(p.node) }
        for p in rearWheels { wheelish.append(p.node) }
        for nm in ["brake_FL", "brake_FR", "brake_RL", "brake_RR"] {
            if let n = VehicleParts.find(root, nm) { wheelish.append(n) }
        }
        // body must not contain wheels, otherwise tilting it would tilt them too
        for w in wheelish where VehicleParts.isAncestor(b, of: w) { return }
        let pv: SCNNode = SCNNode()
        pv.name = "bodyPivot"
        pv.simdPosition = pivotBase
        parent.addChildNode(pv)
        let kids: [SCNNode] = Array(parent.childNodes)
        for child in kids {
            if child === pv { continue }
            var skip: Bool = false
            for w in wheelish where VehicleParts.isAncestor(child, of: w) || VehicleParts.isAncestor(w, of: child) {
                skip = true
            }
            if skip { continue }
            let t: simd_float4x4 = child.simdWorldTransform
            pv.addChildNode(child)
            child.simdWorldTransform = t
        }
        pivot = pv
    }

    private func collectCockpitHidden() {
        guard let b = body else { return }
        let keys: [String] = ["roof", "pillar", "windowframe", "window_frame", "a_pillar"]
        b.enumerateHierarchy { (n: SCNNode, stop: UnsafeMutablePointer<ObjCBool>) in
            if n === b { return }
            guard let nm = n.name?.lowercased() else { return }
            for k in keys where nm.contains(k) {
                self.cockpitHidden.append(n)
                return
            }
        }
    }

    func setCockpitMode(_ inside: Bool) {
        for n in cockpitHidden { n.isHidden = inside }
        interior?.isHidden = false
    }

    func setWing(_ level: Int) {
        wingGT3?.isHidden = level != 1
        wingBig?.isHidden = level != 2
    }

    /// wheel spin / steering (radians).  steer > 0 = left.
    func setWheels(steer: Float, spinFront: Float, spinRear: Float) {
        let qSteer: simd_quatf = simd_quatf(angle: steer, axis: Vec3(0, 1, 0))
        let qSpinF: simd_quatf = simd_quatf(angle: spinFront, axis: Vec3(1, 0, 0))
        let qSpinR: simd_quatf = simd_quatf(angle: spinRear, axis: Vec3(1, 0, 0))
        for p in steerParts { p.node.simdOrientation = p.rest * qSteer }
        for p in frontWheels {
            if hasSteerPivot {
                p.node.simdOrientation = p.rest * qSpinF
            } else {
                p.node.simdOrientation = qSteer * p.rest * qSpinF
            }
        }
        for p in rearWheels { p.node.simdOrientation = p.rest * qSpinR }
    }

    /// pitchX: rotation about the car's X axis (positive = nose down), rollZ: about Z (positive = left side up)
    func setBody(pitchX: Float, rollZ: Float, heave: Float) {
        guard let pv = pivot else { return }
        let qx: simd_quatf = simd_quatf(angle: pitchX, axis: Vec3(1, 0, 0))
        let qz: simd_quatf = simd_quatf(angle: rollZ, axis: Vec3(0, 0, 1))
        pv.simdOrientation = qx * qz
        pv.simdPosition = pivotBase + Vec3(0, heave, 0)
    }

    /// Adds an anchor node that moves with the body; `localPoint` is expressed in `space` (the car wrapper node).
    func makeAnchor(_ localPoint: Vec3, space: SCNNode, name: String) -> SCNNode {
        let a: SCNNode = SCNNode()
        a.name = name
        let host: SCNNode = pivot ?? root
        host.addChildNode(a)
        a.simdPosition = host.simdConvertPosition(localPoint, from: space)
        return a
    }
}

// MARK: - fallback model (used when car_player.glb / car_ai.glb are missing)

enum VehicleModelFactory {
    @MainActor
    static func placeholderCar(color: UIColor) -> SCNNode {
        let root: SCNNode = SCNNode()
        root.name = "car"
        let paint: SCNMaterial = SCNMaterial()
        paint.name = "carpaint"
        paint.lightingModel = .physicallyBased
        paint.diffuse.contents = color
        paint.metalness.contents = NSNumber(value: 0.4)
        paint.roughness.contents = NSNumber(value: 0.3)

        let bodyGeo: SCNBox = SCNBox(width: 2.0, height: 0.55, length: 4.6, chamferRadius: 0.15)
        bodyGeo.materials = [paint]
        let body: SCNNode = SCNNode(geometry: bodyGeo)
        body.name = "body"
        body.simdPosition = Vec3(0, 0.55, 0)
        root.addChildNode(body)

        let glassMat: SCNMaterial = SCNMaterial()
        glassMat.name = "glass"
        glassMat.diffuse.contents = UIColor(white: 0.05, alpha: 1)
        glassMat.transparency = 0.6
        let glassGeo: SCNBox = SCNBox(width: 1.6, height: 0.45, length: 1.9, chamferRadius: 0.12)
        glassGeo.materials = [glassMat]
        let glass: SCNNode = SCNNode(geometry: glassGeo)
        glass.name = "glass"
        glass.simdPosition = Vec3(0, 1.0, -0.25)
        root.addChildNode(glass)

        let interior: SCNNode = SCNNode()
        interior.name = "interior"
        root.addChildNode(interior)

        let tyreMat: SCNMaterial = SCNMaterial()
        tyreMat.name = "tyre"
        tyreMat.diffuse.contents = UIColor(white: 0.06, alpha: 1)
        let specs: [(String, Float, Float, Bool)] = [
            ("FL", 0.84, 1.258, true), ("FR", -0.84, 1.258, true),
            ("RL", 0.82, -1.258, false), ("RR", -0.82, -1.258, false)
        ]
        for s in specs {
            let cyl: SCNCylinder = SCNCylinder(radius: 0.34, height: 0.28)
            cyl.materials = [tyreMat]
            let cylNode: SCNNode = SCNNode(geometry: cyl)
            cylNode.simdEulerAngles = Vec3(0, 0, Float.pi / 2)
            let wheel: SCNNode = SCNNode()
            wheel.name = "wheel_" + s.0
            wheel.addChildNode(cylNode)
            if s.3 {
                let steer: SCNNode = SCNNode()
                steer.name = "steer_" + s.0
                steer.simdPosition = Vec3(s.1, 0.34, s.2)
                steer.addChildNode(wheel)
                root.addChildNode(steer)
            } else {
                wheel.simdPosition = Vec3(s.1, 0.35, s.2)
                root.addChildNode(wheel)
            }
        }

        let sw: SCNNode = SCNNode()
        sw.name = "steering_wheel"
        sw.simdPosition = Vec3(0.36, 0.83, 0.62)
        let torus: SCNTorus = SCNTorus(ringRadius: 0.17, pipeRadius: 0.015)
        let torusNode: SCNNode = SCNNode(geometry: torus)
        torusNode.simdEulerAngles = Vec3(Float.pi / 2, 0, 0)
        sw.addChildNode(torusNode)
        root.addChildNode(sw)

        let tail: SCNMaterial = SCNMaterial()
        tail.name = "taillight"
        tail.diffuse.contents = UIColor.red
        let head: SCNMaterial = SCNMaterial()
        head.name = "headlight"
        head.diffuse.contents = UIColor.white
        let tailGeo: SCNBox = SCNBox(width: 1.5, height: 0.1, length: 0.05, chamferRadius: 0)
        tailGeo.materials = [tail]
        let tailNode: SCNNode = SCNNode(geometry: tailGeo)
        tailNode.simdPosition = Vec3(0, 0.75, -2.3)
        root.addChildNode(tailNode)
        let headGeo: SCNBox = SCNBox(width: 1.5, height: 0.1, length: 0.05, chamferRadius: 0)
        headGeo.materials = [head]
        let headNode: SCNNode = SCNNode(geometry: headGeo)
        headNode.simdPosition = Vec3(0, 0.7, 2.3)
        root.addChildNode(headNode)
        return root
    }
}
