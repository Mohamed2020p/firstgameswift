import Foundation
import SceneKit
import UIKit
import simd

// MARK: - Day / night sky: gradient dome, stars, clouds, sun + moon discs, the sun directional light (cascaded shadows),
// ambient light, fog colour and the image based lighting environment. Everything sits inside the fog start distance so the
// dome is never fogged out.

@MainActor
final class WSky {
    static let domeRadius: Float = 430

    /// follows the camera; parent of dome / stars / clouds / sun / moon
    let root = SCNNode()
    /// the directional light that casts the sun / moon shadows
    let sunLight = SCNNode()
    let ambientNode = SCNNode()

    private let sunL = SCNLight()
    private let ambL = SCNLight()
    private let domeNode = SCNNode()
    private let starNode = SCNNode()
    private let cloudNode = SCNNode()
    private let sunDisc = SCNNode()
    private let moonDisc = SCNNode()
    private let domeMat = SCNMaterial()
    private let starMat = SCNMaterial()
    private let cloudMat = SCNMaterial()
    private let sunMat = SCNMaterial()
    private let moonMat = SCNMaterial()
    private unowned let scene: SCNScene

    private var lastSkyT: Float = -100
    private var lastEnvT: Float = -100
    private var cloudSpin: Float = 0

    /// 0 (day) ... 1 (night); the world uses it for lamps and window lights
    private(set) var night: Float = 0
    private(set) var sunElevation: Float = 0.5
    private(set) var horizonColor = Vec3(0.62, 0.78, 0.95)
    private(set) var toSun = Vec3(0, 1, 0)

    init(scene: SCNScene) {
        self.scene = scene
        root.name = "sky"
        buildDomes()
        buildDiscs()
        buildLights()
    }

    // MARK: construction

    private static func makeDomeGeometry(radius: Float, phiMin: Float, material: SCNMaterial) -> SCNGeometry {
        let set = WMeshSet()
        let m = set.mesh(material)
        let rings = 20
        let segs = 48
        let phiMax: Float = Float.pi * 0.5
        var rows: [[UInt32]] = []
        for r in 0...rings {
            let v: Float = Float(r) / Float(rings)
            let phi: Float = phiMin + v * (phiMax - phiMin)
            var row: [UInt32] = []
            for s in 0...segs {
                let u: Float = Float(s) / Float(segs)
                let th: Float = u * Float.tau
                let p = Vec3(cosf(phi) * cosf(th), sinf(phi), cosf(phi) * sinf(th)) * radius
                row.append(m.vertex(p, Vec3(0, -1, 0), u, v))
            }
            rows.append(row)
        }
        for r in 0..<rings {
            for s in 0..<segs {
                let a = rows[r][s]
                let b = rows[r][s + 1]
                let c = rows[r + 1][s]
                let d = rows[r + 1][s + 1]
                m.tri(a, b, c)
                m.tri(b, d, c)
            }
        }
        if let g = set.makeGeometry() { return g }
        return SCNSphere(radius: CGFloat(radius))
    }

    private func configureSkyMaterial(_ m: SCNMaterial, blend: SCNBlendMode) {
        m.lightingModel = SCNMaterial.LightingModel.constant
        m.isDoubleSided = true
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        m.blendMode = blend
        m.diffuse.wrapS = SCNWrapMode.clamp
        m.diffuse.wrapT = SCNWrapMode.clamp
        m.diffuse.minificationFilter = SCNFilterMode.linear
        m.diffuse.magnificationFilter = SCNFilterMode.linear
    }

    private func buildDomes() {
        let phiMin: Float = -0.15
        configureSkyMaterial(domeMat, blend: SCNBlendMode.alpha)
        domeMat.diffuse.contents = WSky.gradientImage(zenith: Vec3(0.18, 0.42, 0.85), horizon: Vec3(0.62, 0.78, 0.95))
        domeNode.geometry = WSky.makeDomeGeometry(radius: WSky.domeRadius, phiMin: phiMin, material: domeMat)
        domeNode.renderingOrder = -100
        domeNode.castsShadow = false
        root.addChildNode(domeNode)

        configureSkyMaterial(starMat, blend: SCNBlendMode.add)
        starMat.diffuse.contents = WSky.starImage()
        starNode.geometry = WSky.makeDomeGeometry(radius: WSky.domeRadius - 4, phiMin: phiMin, material: starMat)
        starNode.renderingOrder = -99
        starNode.castsShadow = false
        starNode.opacity = 0
        root.addChildNode(starNode)

        configureSkyMaterial(cloudMat, blend: SCNBlendMode.alpha)
        cloudMat.diffuse.contents = WSky.cloudImage()
        cloudMat.diffuse.wrapS = SCNWrapMode.repeat
        cloudNode.geometry = WSky.makeDomeGeometry(radius: WSky.domeRadius - 8, phiMin: phiMin, material: cloudMat)
        cloudNode.renderingOrder = -98
        cloudNode.castsShadow = false
        root.addChildNode(cloudNode)
    }

    private func buildDiscs() {
        configureSkyMaterial(sunMat, blend: SCNBlendMode.add)
        sunMat.diffuse.contents = WSky.discImage(core: Vec3(1.0, 0.96, 0.85), glow: Vec3(1.0, 0.75, 0.45), coreFraction: 0.16)
        let sunPlane = SCNPlane(width: 120, height: 120)
        sunPlane.materials = [sunMat]
        sunDisc.geometry = sunPlane
        sunDisc.renderingOrder = -97
        sunDisc.castsShadow = false
        root.addChildNode(sunDisc)

        configureSkyMaterial(moonMat, blend: SCNBlendMode.add)
        moonMat.diffuse.contents = WSky.discImage(core: Vec3(0.92, 0.95, 1.0), glow: Vec3(0.45, 0.55, 0.85), coreFraction: 0.30)
        let moonPlane = SCNPlane(width: 60, height: 60)
        moonPlane.materials = [moonMat]
        moonDisc.geometry = moonPlane
        moonDisc.renderingOrder = -97
        moonDisc.castsShadow = false
        root.addChildNode(moonDisc)
    }

    private func buildLights() {
        sunL.type = SCNLight.LightType.directional
        sunL.color = UIColor.white
        sunL.intensity = 1400
        sunL.castsShadow = true
        sunL.shadowColor = UIColor(white: 0, alpha: 0.55)
        sunL.shadowMapSize = CGSize(width: 2048, height: 2048)
        sunL.shadowSampleCount = 8
        sunL.shadowRadius = 2.5
        sunL.shadowBias = 0.5
        sunL.automaticallyAdjustsShadowProjection = true
        sunL.maximumShadowDistance = 260
        sunL.shadowCascadeCount = 3
        sunL.shadowCascadeSplittingFactor = 0.6
        sunL.categoryBitMask = 0xFFFF & ~8
        sunLight.light = sunL
        sunLight.name = "sun"

        ambL.type = SCNLight.LightType.ambient
        ambL.color = UIColor(white: 1, alpha: 1)
        ambL.intensity = 400
        ambL.categoryBitMask = 0xFFFF & ~8
        ambientNode.light = ambL
        ambientNode.name = "ambient"
    }

    /// call once after creation: attaches every node to the scene
    func attach() {
        scene.rootNode.addChildNode(root)
        scene.rootNode.addChildNode(sunLight)
        scene.rootNode.addChildNode(ambientNode)
        scene.fogColor = UIColor(red: 0.62, green: 0.78, blue: 0.95, alpha: 1)
        scene.fogStartDistance = 480
        scene.fogEndDistance = 1000
        scene.fogDensityExponent = 1.4
    }

    // MARK: graphics settings

    func applyGraphics(_ g: GraphicsSettings) {
        if g.shadows == ShadowQuality.off {
            sunL.castsShadow = false
        } else {
            sunL.castsShadow = true
            let size: CGFloat = CGFloat(g.shadows.mapSize)
            sunL.shadowMapSize = CGSize(width: size, height: size)
            sunL.shadowSampleCount = g.shadows == ShadowQuality.low ? 4 : 8
            sunL.maximumShadowDistance = CGFloat(g.shadows == ShadowQuality.high ? 320 : (g.shadows == ShadowQuality.medium ? 240 : 160))
            sunL.shadowCascadeCount = g.shadows == ShadowQuality.low ? 2 : 3
        }
        let end: Float = max(700, 1000 * g.drawDistance)
        scene.fogEndDistance = CGFloat(end)
        scene.fogStartDistance = 480
    }

    // MARK: per frame

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { return smoothstep(a, b, x) }

    /// t in hours 0...24. focus = point the sun shadow should follow. camera = dome centre.
    func update(t: Float, focus: Vec3, camera: Vec3, dt: Float) {
        let a: Float = (t - 6) / 12 * Float.pi
        let dir = Vec3(cosf(a), sinf(a), 0.35).normalizedSafe
        toSun = dir
        let e: Float = dir.y
        sunElevation = e

        let day: Float = WSky.smooth(0.05, 0.45, e)
        let nightF: Float = 1 - WSky.smooth(-0.20, 0.02, e)
        let twi: Float = max(0, 1 - day - nightF)
        night = 1 - WSky.smooth(-0.04, 0.20, e)

        let zenith: Vec3 = Vec3(0.18, 0.42, 0.85) * day + Vec3(0.02, 0.03, 0.09) * nightF + Vec3(0.22, 0.30, 0.55) * twi
        let horizon: Vec3 = Vec3(0.66, 0.80, 0.96) * day + Vec3(0.05, 0.07, 0.14) * nightF + Vec3(1.0, 0.56, 0.32) * twi
        horizonColor = horizon

        if abs(t - lastSkyT) > 0.04 || lastSkyT < -50 {
            lastSkyT = t
            domeMat.diffuse.contents = WSky.gradientImage(zenith: zenith, horizon: horizon)
            let cloudTint: Vec3 = Vec3(1.0, 1.0, 1.0) * day + Vec3(0.10, 0.12, 0.20) * nightF + Vec3(1.0, 0.65, 0.55) * twi
            cloudMat.multiply.contents = UIColor(red: CGFloat(cloudTint.x), green: CGFloat(cloudTint.y), blue: CGFloat(cloudTint.z), alpha: 1)
            starNode.opacity = CGFloat(clampf((nightF - 0.15) * 1.3, 0, 1))
        }
        if abs(t - lastEnvT) > 0.25 || lastEnvT < -50 {
            lastEnvT = t
            scene.lightingEnvironment.contents = WSky.environmentImage(zenith: zenith, horizon: horizon, ground: horizon * 0.35 + Vec3(0.04, 0.04, 0.04))
            scene.lightingEnvironment.intensity = CGFloat(0.25 + 0.95 * day + 0.25 * twi)
        }

        scene.fogColor = UIColor(red: CGFloat(horizon.x), green: CGFloat(horizon.y), blue: CGFloat(horizon.z), alpha: 1)

        // dome follows the camera
        root.simdPosition = camera
        cloudSpin += dt * 0.004
        cloudNode.simdEulerAngles = Vec3(0, cloudSpin, 0)
        starNode.simdEulerAngles = Vec3(0, t * 0.05, 0)

        // sun / moon discs
        let moonDir = Vec3(-dir.x, -dir.y, -dir.z)
        sunDisc.simdPosition = dir * (WSky.domeRadius - 12)
        sunDisc.simdOrientation = simd_quatf(from: Vec3(0, 0, 1), to: dir * -1)
        sunDisc.isHidden = e < -0.08
        moonDisc.simdPosition = moonDir * (WSky.domeRadius - 12)
        moonDisc.simdOrientation = simd_quatf(from: Vec3(0, 0, 1), to: moonDir * -1)
        moonDisc.isHidden = moonDir.y < -0.08
        let sunGlow: Float = clampf(0.4 + 0.6 * WSky.smooth(-0.05, 0.3, e), 0, 1)
        sunDisc.opacity = CGFloat(sunGlow)

        // light: sun by day, moon by night (same node so there is only one shadow caster)
        let sunI: Float = 1500 * WSky.smooth(0.0, 0.28, e)
        let moonI: Float = 330 * WSky.smooth(0.0, 0.28, moonDir.y)
        let useSun: Bool = sunI >= moonI
        let toLight: Vec3 = useSun ? dir : moonDir
        sunLight.simdPosition = focus + toLight * 140
        sunLight.simdLook(at: focus, up: Vec3(0, 1, 0), localFront: Vec3(0, 0, -1))
        if useSun {
            let warm: Float = WSky.smooth(0.0, 0.45, e)
            let c: Vec3 = Vec3(1.0, 0.55, 0.28) * (1 - warm) + Vec3(1.0, 0.96, 0.88) * warm
            sunL.color = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            sunL.intensity = CGFloat(sunI)
        } else {
            sunL.color = UIColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 1)
            sunL.intensity = CGFloat(moonI)
        }

        // ambient: sky coloured
        let amb: Vec3 = (zenith * 0.5 + horizon * 0.5)
        let ambI: Float = 95 + 330 * day + 170 * twi
        ambL.color = UIColor(red: CGFloat(min(1, amb.x * 1.15 + 0.10)), green: CGFloat(min(1, amb.y * 1.15 + 0.10)),
                             blue: CGFloat(min(1, amb.z * 1.15 + 0.14)), alpha: 1)
        ambL.intensity = CGFloat(ambI)
    }

    // MARK: procedural images

    static func gradientImage(zenith: Vec3, horizon: Vec3) -> UIImage {
        let w = 4
        let h = 256
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let phiMin: Float = -0.15
        let phiMax: Float = Float.pi * 0.5
        for y in 0..<h {
            let v: Float = 1 - (Float(y) + 0.5) / Float(h)
            let phi: Float = phiMin + v * (phiMax - phiMin)
            var c: Vec3
            if phi < 0 {
                c = horizon * (0.72 + 0.28 * (1 + phi / 0.15))
            } else {
                let t: Float = powf(clampf(phi / phiMax, 0, 1), 0.55)
                c = horizon + (zenith - horizon) * t
            }
            for x in 0..<w {
                let o = (y * w + x) * 4
                px[o] = WTex.byte(c.x)
                px[o + 1] = WTex.byte(c.y)
                px[o + 2] = WTex.byte(c.z)
                px[o + 3] = 255
            }
        }
        return WTex.imageFromPixels(px, w, h, hasAlpha: false)
    }

    static func environmentImage(zenith: Vec3, horizon: Vec3, ground: Vec3) -> UIImage {
        let w = 32
        let h = 16
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let t: Float = 1 - (Float(y) + 0.5) / Float(h)      // 1 top ... 0 bottom
            var c: Vec3
            if t >= 0.5 {
                let k: Float = (t - 0.5) * 2
                c = horizon + (zenith - horizon) * powf(k, 0.6)
            } else {
                let k: Float = t * 2
                c = ground + (horizon - ground) * powf(k, 2.0)
            }
            for x in 0..<w {
                let o = (y * w + x) * 4
                px[o] = WTex.byte(c.x)
                px[o + 1] = WTex.byte(c.y)
                px[o + 2] = WTex.byte(c.z)
                px[o + 3] = 255
            }
        }
        return WTex.imageFromPixels(px, w, h, hasAlpha: false)
    }

    static func starImage() -> UIImage {
        let w = 1024
        let h = 512
        return WTex.render(w, h, opaque: false) { c in
            c.clear(CGRect(x: 0, y: 0, width: w, height: h))
            var rng = SeededRNG(seed: 99)
            let phiMin: Float = -0.15
            let phiMax: Float = Float.pi * 0.5
            for _ in 0..<900 {
                let u: Float = rng.float()
                let s: Float = rng.float(0.02, 1.0)
                let phi: Float = asinf(s)
                let v: Float = (phi - phiMin) / (phiMax - phiMin)
                let x = CGFloat(u * Float(w))
                let y = CGFloat((1 - v) * Float(h))
                let br: Float = rng.float(0.35, 1.0)
                let big: Bool = rng.chance(0.12)
                let size: CGFloat = big ? 3.2 : 1.8
                c.setFillColor(UIColor(red: CGFloat(br), green: CGFloat(br), blue: CGFloat(min(1, br + 0.1)), alpha: 1).cgColor)
                c.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size * 0.7))
            }
        }
    }

    static func cloudImage() -> UIImage {
        let w = 512
        let h = 128
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let v: Float = 1 - (Float(y) + 0.5) / Float(h)       // 1 = high in the sky
            for x in 0..<w {
                let u: Float = Float(x) / Float(w)
                let n: Float = WTex.fbm(u, Float(y) / Float(h) * 0.5, 8, 5, 401)
                var a: Float = smoothstep(0.50, 0.72, n)
                a *= smoothstep(0.02, 0.28, v)
                a *= 0.85
                let o = (y * w + x) * 4
                let shade: Float = 0.86 + 0.14 * n
                px[o] = WTex.byte(shade * a)
                px[o + 1] = WTex.byte(shade * a)
                px[o + 2] = WTex.byte(shade * a)
                px[o + 3] = WTex.byte(a)
            }
        }
        return WTex.imageFromPixels(px, w, h, hasAlpha: true)
    }

    static func discImage(core: Vec3, glow: Vec3, coreFraction: CGFloat) -> UIImage {
        return WTex.render(128, 128, opaque: false) { c in
            c.clear(CGRect(x: 0, y: 0, width: 128, height: 128))
            WTex.radial(c, center: CGPoint(x: 64, y: 64), radius: 64, stops: [
                (0, WTex.col(core.x, core.y, core.z, 1)),
                (coreFraction, WTex.col(core.x, core.y, core.z, 1)),
                (coreFraction + 0.04, WTex.col(glow.x, glow.y, glow.z, 0.55)),
                (0.55, WTex.col(glow.x, glow.y, glow.z, 0.14)),
                (1, WTex.col(glow.x, glow.y, glow.z, 0))
            ])
        }
    }
}
