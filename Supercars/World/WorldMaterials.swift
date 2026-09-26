import Foundation
import SceneKit
import UIKit

// MARK: - All shared materials of the world. Geometry is merged per chunk by material identity, and lamps / windows / shop signs
// switch on at night by changing `emission.intensity` of these few shared materials.

@MainActor
final class WorldMaterials {
    // flat "ground layer" materials (drawn without depth writes, in a fixed order, see WRender)
    let ground = SCNMaterial()
    let lawn = SCNMaterial()
    let pave = SCNMaterial()
    let plaza = SCNMaterial()
    let sidewalk = SCNMaterial()
    let curb = SCNMaterial()
    let asphalt = SCNMaterial()
    let paintWhite = SCNMaterial()
    let paintYellow = SCNMaterial()
    let manhole = SCNMaterial()
    let lightPool = SCNMaterial()
    let water = SCNMaterial()
    let dirtPath = SCNMaterial()

    // structures
    var facade: [[SCNMaterial]] = []
    var shop: [SCNMaterial] = []
    let awning = SCNMaterial()
    let roofGravel = SCNMaterial()
    let concreteWall = SCNMaterial()
    let metal = SCNMaterial()
    let beacon = SCNMaterial()
    var roofTiles: [SCNMaterial] = []
    let warehouseWall = SCNMaterial()

    // props
    let props = SCNMaterial()
    let propsDead = SCNMaterial()
    let signal = SCNMaterial()

    private(set) var night: Float = -1
    private var lastBeacon: Bool = false

    init() {}

    // MARK: helpers

    private func setTex(_ m: SCNMaterial, _ img: UIImage, tiled: Bool, aniso: CGFloat) {
        m.diffuse.contents = img
        m.diffuse.wrapS = tiled ? SCNWrapMode.repeat : SCNWrapMode.clamp
        m.diffuse.wrapT = tiled ? SCNWrapMode.repeat : SCNWrapMode.clamp
        m.diffuse.mipFilter = SCNFilterMode.linear
        m.diffuse.minificationFilter = SCNFilterMode.linear
        m.diffuse.magnificationFilter = SCNFilterMode.linear
        m.diffuse.maxAnisotropy = aniso
    }

    private func flat(_ m: SCNMaterial) {
        m.lightingModel = SCNMaterial.LightingModel.lambert
        m.readsFromDepthBuffer = true
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
    }

    private func solid(_ m: SCNMaterial, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        m.lightingModel = SCNMaterial.LightingModel.lambert
        m.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    // MARK: stage 1: ground, roads, decals

    func makeGroundAndRoads() {
        setTex(ground, WTex.ground(), tiled: true, aniso: 4)
        flat(ground)
        setTex(lawn, WTex.lawn(), tiled: true, aniso: 4)
        flat(lawn)
        setTex(pave, WTex.pave(), tiled: true, aniso: 4)
        flat(pave)
        setTex(plaza, WTex.plaza(), tiled: true, aniso: 4)
        flat(plaza)
        setTex(sidewalk, WTex.pavers(), tiled: true, aniso: 8)
        flat(sidewalk)
        setTex(curb, WTex.concrete(seed: 5, tone: 0.60), tiled: true, aniso: 4)
        flat(curb)
        setTex(asphalt, WTex.asphalt(), tiled: true, aniso: 8)
        flat(asphalt)
        solid(paintWhite, 0.90, 0.90, 0.87)
        flat(paintWhite)
        solid(paintYellow, 0.92, 0.72, 0.10)
        flat(paintYellow)
        setTex(manhole, WTex.manhole(), tiled: false, aniso: 2)
        flat(manhole)
        setTex(lightPool, WTex.lightPool(), tiled: false, aniso: 1)
        lightPool.lightingModel = SCNMaterial.LightingModel.constant
        lightPool.readsFromDepthBuffer = true
        lightPool.writesToDepthBuffer = false
        lightPool.blendMode = SCNBlendMode.alpha
        lightPool.transparency = 0
        setTex(water, WTex.water(), tiled: true, aniso: 2)
        water.lightingModel = SCNMaterial.LightingModel.blinn
        water.specular.contents = UIColor(white: 0.7, alpha: 1)
        water.shininess = 0.8
        water.readsFromDepthBuffer = true
        water.writesToDepthBuffer = false
        setTex(dirtPath, WTex.concrete(seed: 9, tone: 0.50), tiled: true, aniso: 2)
        flat(dirtPath)
        dirtPath.diffuse.contents = UIColor(red: 0.45, green: 0.38, blue: 0.28, alpha: 1)
    }

    // MARK: stage 2: facades and building materials

    func makeFacades() {
        facade = []
        for s in 0..<WFacades.styles.count {
            let st = WFacades.styles[s]
            let diff = WFacades.diffuse(style: s)
            var variants: [SCNMaterial] = []
            for v in 0..<2 {
                let m = SCNMaterial()
                setTex(m, diff, tiled: true, aniso: 8)
                m.emission.contents = WFacades.emission(style: s, variant: v)
                m.emission.wrapS = SCNWrapMode.repeat
                m.emission.wrapT = SCNWrapMode.repeat
                m.emission.mipFilter = SCNFilterMode.linear
                m.emission.intensity = 0
                if st.pbr {
                    m.lightingModel = SCNMaterial.LightingModel.physicallyBased
                    m.metalness.contents = NSNumber(value: st.metalness)
                    m.roughness.contents = NSNumber(value: st.roughness)
                } else {
                    m.lightingModel = SCNMaterial.LightingModel.lambert
                }
                variants.append(m)
            }
            facade.append(variants)
        }
        shop = []
        for seed in 0..<2 {
            let m = SCNMaterial()
            setTex(m, WFacades.shopDiffuse(seed: seed), tiled: true, aniso: 8)
            m.lightingModel = SCNMaterial.LightingModel.lambert
            m.emission.contents = WFacades.shopEmission(seed: seed)
            m.emission.wrapS = SCNWrapMode.repeat
            m.emission.wrapT = SCNWrapMode.repeat
            m.emission.intensity = 0
            shop.append(m)
        }
        setTex(awning, WFacades.awning(), tiled: true, aniso: 2)
        awning.lightingModel = SCNMaterial.LightingModel.lambert
        awning.isDoubleSided = true
        setTex(roofGravel, WTex.roofGravel(), tiled: true, aniso: 2)
        roofGravel.lightingModel = SCNMaterial.LightingModel.lambert
        setTex(concreteWall, WTex.concrete(seed: 21, tone: 0.66), tiled: true, aniso: 4)
        concreteWall.lightingModel = SCNMaterial.LightingModel.lambert
        setTex(warehouseWall, WTex.concrete(seed: 31, tone: 0.55), tiled: true, aniso: 4)
        warehouseWall.lightingModel = SCNMaterial.LightingModel.lambert
        solid(metal, 0.62, 0.64, 0.66)
        beacon.lightingModel = SCNMaterial.LightingModel.lambert
        beacon.diffuse.contents = UIColor(red: 0.25, green: 0.02, blue: 0.02, alpha: 1)
        beacon.emission.contents = UIColor(red: 1.0, green: 0.05, blue: 0.03, alpha: 1)
        beacon.emission.intensity = 0
        roofTiles = []
        let colours: [(Float, Float, Float)] = [(0.66, 0.30, 0.20), (0.42, 0.30, 0.22), (0.40, 0.42, 0.45)]
        for c in colours {
            let m = SCNMaterial()
            setTex(m, WTex.roofTile(r: c.0, g: c.1, b: c.2), tiled: true, aniso: 4)
            m.lightingModel = SCNMaterial.LightingModel.lambert
            m.isDoubleSided = true
            roofTiles.append(m)
        }
    }

    // MARK: stage 3: props

    func makeProps() {
        let atlas = WTex.propsAtlas()
        setTex(props, atlas, tiled: false, aniso: 2)
        props.lightingModel = SCNMaterial.LightingModel.lambert
        props.emission.contents = WTex.propsEmission(kind: 0)
        props.emission.intensity = 0
        props.isDoubleSided = true
        setTex(propsDead, atlas, tiled: false, aniso: 2)
        propsDead.lightingModel = SCNMaterial.LightingModel.lambert
        propsDead.isDoubleSided = true
        setTex(signal, atlas, tiled: false, aniso: 2)
        signal.lightingModel = SCNMaterial.LightingModel.lambert
        signal.emission.contents = WTex.propsEmission(kind: 1)
        signal.emission.intensity = 0.9
        signal.isDoubleSided = true
    }

    // MARK: time of day

    func facadeMaterial(style: Int, variant: Int) -> SCNMaterial {
        if facade.isEmpty { return concreteWall }
        let s = ((style % facade.count) + facade.count) % facade.count
        let v = ((variant % 2) + 2) % 2
        return facade[s][v]
    }

    /// n: 0 (day) ... 1 (night)
    func setNight(_ n: Float) {
        if abs(n - night) < 0.02 && night >= 0 { return }
        night = n
        let inten = CGFloat(n)
        for variants in facade {
            for m in variants { m.emission.intensity = inten }
        }
        for m in shop { m.emission.intensity = inten }
        props.emission.intensity = inten
        lightPool.transparency = CGFloat(n * 0.95)
        signal.emission.intensity = CGFloat(0.55 + 0.45 * n)
    }

    func setBeacon(_ on: Bool) {
        if on == lastBeacon { return }
        lastBeacon = on
        beacon.emission.intensity = on ? 1.5 : 0
    }
}
