import Foundation
import SceneKit
import simd
import UIKit
import QuartzCore

// MARK: - Skid marks (one dynamic mesh built from a ring buffer of quads), tyre smoke, sparks, exhaust flames, damage smoke.

@MainActor
final class VehicleSkidMarks {
    private let node: SCNNode = SCNNode()
    private let material: SCNMaterial = SCNMaterial()
    private let capacity: Int = 220
    private var verts: [SCNVector3] = []
    private var indices: [Int32] = []
    private var cursor: Int = 0
    private var last: [Vec3?] = [nil, nil, nil, nil]
    private var dirty: Bool = false
    private var timer: Float = 0

    init(parent: SCNNode) {
        node.name = "skidMarks"
        node.castsShadow = false
        node.renderingOrder = 5
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(white: 0.02, alpha: 1)
        material.transparency = 0.55
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        verts = [SCNVector3](repeating: SCNVector3(0, 0, 0), count: capacity * 4)
        for k in 0..<capacity {
            let b: Int32 = Int32(k * 4)
            indices.append(contentsOf: [b, b + 1, b + 2, b + 2, b + 1, b + 3])
        }
        parent.addChildNode(node)
        rebuild()
    }

    func clear() {
        for i in 0..<verts.count { verts[i] = SCNVector3(0, 0, 0) }
        for i in 0..<last.count { last[i] = nil }
        dirty = true
    }

    func endWheel(_ wheel: Int) {
        if wheel >= 0 && wheel < last.count { last[wheel] = nil }
    }

    func addPoint(wheel: Int, position p: Vec3, width: Float) {
        if wheel < 0 || wheel >= last.count { return }
        guard let q = last[wheel] else {
            last[wheel] = p
            return
        }
        let dx: Float = p.x - q.x
        let dz: Float = p.z - q.z
        let len: Float = sqrtf(dx * dx + dz * dz)
        if len < 0.45 { return }
        if len > 6 {
            last[wheel] = p
            return
        }
        let sx: Float = -dz / len * width * 0.5
        let sz: Float = dx / len * width * 0.5
        let base: Int = cursor * 4
        verts[base] = SCNVector3(q.x - sx, q.y, q.z - sz)
        verts[base + 1] = SCNVector3(q.x + sx, q.y, q.z + sz)
        verts[base + 2] = SCNVector3(p.x - sx, p.y, p.z - sz)
        verts[base + 3] = SCNVector3(p.x + sx, p.y, p.z + sz)
        cursor = (cursor + 1) % capacity
        last[wheel] = p
        dirty = true
    }

    func update(dt: Float) {
        timer += dt
        if dirty && timer > 0.12 {
            timer = 0
            dirty = false
            rebuild()
        }
    }

    private func rebuild() {
        let src: SCNGeometrySource = SCNGeometrySource(vertices: verts)
        let normals: [SCNVector3] = [SCNVector3](repeating: SCNVector3(0, 1, 0), count: verts.count)
        let nsrc: SCNGeometrySource = SCNGeometrySource(normals: normals)
        let elem: SCNGeometryElement = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let g: SCNGeometry = SCNGeometry(sources: [src, nsrc], elements: [elem])
        g.materials = [material]
        node.geometry = g
    }
}

enum VehicleParticles {
    static let softDot: UIImage = makeSoftDot()

    private static func makeSoftDot() -> UIImage {
        let size: CGSize = CGSize(width: 32, height: 32)
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { (ctx: UIGraphicsImageRendererContext) in
            let cg: CGContext = ctx.cgContext
            let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
            let colors: [CGColor] = [
                UIColor(white: 1, alpha: 1).cgColor,
                UIColor(white: 1, alpha: 0.0).cgColor
            ]
            let locs: [CGFloat] = [0, 1]
            if let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs) {
                let c: CGPoint = CGPoint(x: 16, y: 16)
                cg.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: 16, options: [])
            }
        }
    }

    private static func fade(_ peak: Double) -> SCNParticlePropertyController {
        let anim: CAKeyframeAnimation = CAKeyframeAnimation()
        anim.values = [NSNumber(value: 0.0), NSNumber(value: peak), NSNumber(value: 0.0)]
        anim.keyTimes = [NSNumber(value: 0.0), NSNumber(value: 0.2), NSNumber(value: 1.0)]
        anim.duration = 1.0
        return SCNParticlePropertyController(animation: anim)
    }

    static func smoke(color: UIColor, size: CGFloat, life: CGFloat) -> SCNParticleSystem {
        let s: SCNParticleSystem = SCNParticleSystem()
        s.birthRate = 0
        s.loops = true
        s.particleImage = softDot
        s.particleLifeSpan = life
        s.particleLifeSpanVariation = life * 0.3
        s.particleSize = size
        s.particleSizeVariation = size * 0.4
        s.particleVelocity = 1.4
        s.particleVelocityVariation = 0.8
        s.spreadingAngle = 40
        s.particleColor = color
        s.blendMode = .alpha
        s.isLocal = false
        s.acceleration = SCNVector3(0, 0.7, 0)
        s.propertyControllers = [SCNParticleSystem.ParticleProperty.opacity: fade(0.55)]
        return s
    }

    static func flame(size: CGFloat) -> SCNParticleSystem {
        let s: SCNParticleSystem = SCNParticleSystem()
        s.birthRate = 0
        s.loops = true
        s.particleImage = softDot
        s.particleLifeSpan = 0.16
        s.particleLifeSpanVariation = 0.05
        s.particleSize = size
        s.particleSizeVariation = size * 0.4
        s.particleVelocity = 6
        s.particleVelocityVariation = 2
        s.spreadingAngle = 12
        s.emittingDirection = SCNVector3(0, 0, -1)
        s.particleColor = UIColor(red: 1.0, green: 0.55, blue: 0.12, alpha: 1)
        s.blendMode = .additive
        s.isLocal = false
        s.propertyControllers = [SCNParticleSystem.ParticleProperty.opacity: fade(1.0)]
        return s
    }

    static func sparks() -> SCNParticleSystem {
        let s: SCNParticleSystem = SCNParticleSystem()
        s.birthRate = 700
        s.emissionDuration = 0.14
        s.loops = false
        s.particleImage = softDot
        s.particleLifeSpan = 0.55
        s.particleLifeSpanVariation = 0.25
        s.particleSize = 0.06
        s.particleSizeVariation = 0.03
        s.particleVelocity = 7
        s.particleVelocityVariation = 4
        s.spreadingAngle = 75
        s.particleColor = UIColor(red: 1.0, green: 0.78, blue: 0.3, alpha: 1)
        s.blendMode = .additive
        s.isAffectedByGravity = true
        s.isLocal = false
        s.orientationMode = .billboardVelocityAligned
        s.stretchFactor = 0.1
        s.propertyControllers = [SCNParticleSystem.ParticleProperty.opacity: fade(1.0)]
        return s
    }
}

@MainActor
final class VehicleEffects {
    private unowned let ctx: GameContext
    private let carNode: SCNNode
    let skid: VehicleSkidMarks
    private var tyreSmoke: [SCNParticleSystem] = []
    private var smokeNodes: [SCNNode] = []
    private var flameSystems: [SCNParticleSystem] = []
    private var damageSmoke: SCNParticleSystem? = nil
    private var flameTimer: Float = 0
    private var sparkBudget: Int = 0
    private var sparkClock: Float = 0
    private(set) var particlesOn: Bool = true

    init(ctx: GameContext, car: SCNNode, rearWheels: [Vec3], exhausts: [Vec3], hood: Vec3, exhaustSize: Float) {
        self.ctx = ctx
        self.carNode = car
        self.skid = VehicleSkidMarks(parent: ctx.scene.rootNode)
        for p in rearWheels {
            let n: SCNNode = SCNNode()
            n.simdPosition = Vec3(p.x, 0.08, p.z)
            let s: SCNParticleSystem = VehicleParticles.smoke(color: UIColor(white: 0.88, alpha: 0.6), size: 0.55, life: 1.3)
            n.addParticleSystem(s)
            car.addChildNode(n)
            tyreSmoke.append(s)
            smokeNodes.append(n)
        }
        for p in exhausts {
            let n: SCNNode = SCNNode()
            n.simdPosition = p
            let s: SCNParticleSystem = VehicleParticles.flame(size: CGFloat(exhaustSize))
            n.addParticleSystem(s)
            car.addChildNode(n)
            flameSystems.append(s)
        }
        let hn: SCNNode = SCNNode()
        hn.simdPosition = hood
        let ds: SCNParticleSystem = VehicleParticles.smoke(color: UIColor(white: 0.18, alpha: 0.7), size: 0.5, life: 1.8)
        hn.addParticleSystem(ds)
        car.addChildNode(hn)
        damageSmoke = ds
        particlesOn = ctx.settings.settings.graphics.particles
    }

    func setParticlesEnabled(_ on: Bool) {
        particlesOn = on
        if !on {
            for s in tyreSmoke { s.birthRate = 0 }
            for s in flameSystems { s.birthRate = 0 }
            damageSmoke?.birthRate = 0
        }
    }

    /// amounts 0...1 per rear wheel (smoke); front wheels only leave skid marks
    func setTyreSmoke(_ amount: Float) {
        if !particlesOn { return }
        let rate: CGFloat = CGFloat(clampf(amount, 0, 1) * 55)
        for s in tyreSmoke { s.birthRate = rate }
    }

    func setDamageSmoke(_ damage: Float) {
        guard let s = damageSmoke else { return }
        if !particlesOn || damage < 0.6 {
            s.birthRate = 0
            return
        }
        s.birthRate = CGFloat((damage - 0.55) * 60)
    }

    func exhaustBurst() {
        if !particlesOn { return }
        flameTimer = 0.09
        for s in flameSystems { s.birthRate = 1400 }
    }

    func burstSparks(at p: Vec3) {
        if !particlesOn { return }
        if sparkClock < 0.12 { return }
        sparkClock = 0
        let n: SCNNode = SCNNode()
        n.simdPosition = p
        n.addParticleSystem(VehicleParticles.sparks())
        ctx.scene.rootNode.addChildNode(n)
        let wait: SCNAction = SCNAction.wait(duration: 1.6)
        let remove: SCNAction = SCNAction.removeFromParentNode()
        n.runAction(SCNAction.sequence([wait, remove]))
    }

    func update(dt: Float) {
        sparkClock += dt
        skid.update(dt: dt)
        if flameTimer > 0 {
            flameTimer -= dt
            if flameTimer <= 0 {
                for s in flameSystems { s.birthRate = 0 }
            }
        }
    }
}
