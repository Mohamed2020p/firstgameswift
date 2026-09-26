import Foundation
import SceneKit
import UIKit

// MARK: - Procedural normal maps (leather grain, soft-touch plastic, carbon weave) for the cockpit.  Built once at load time from the
// tileable noise field: height -> tangent-space normal.  Subtle by design: they only break up the specular highlight like real material.

enum NormalMaps {
    /// tileable grain normal map. `strength` around 0.6 ... 2.0 for leather, `octaves` 3 ... 5
    static func grain(size: Int, seed: UInt64, octaves: Int, strength: Float) -> UIImage {
        let s: Int = max(16, min(size, 512))
        let h: [Float] = ProceduralTextures.noiseField(size: s, seed: seed, octaves: octaves)
        var px: [UInt8] = [UInt8](repeating: 255, count: s * s * 4)
        @inline(__always) func at(_ x: Int, _ y: Int) -> Float {
            let xx: Int = (x + s) % s
            let yy: Int = (y + s) % s
            return h[yy * s + xx]
        }
        for y in 0..<s {
            for x in 0..<s {
                let dx: Float = (at(x - 1, y) - at(x + 1, y)) * strength * 4
                let dy: Float = (at(x, y - 1) - at(x, y + 1)) * strength * 4
                let inv: Float = 1 / sqrtf(dx * dx + dy * dy + 1)
                let nx: Float = dx * inv
                let ny: Float = dy * inv
                let nz: Float = inv
                let o: Int = (y * s + x) * 4
                px[o] = UInt8(max(0, min(255, Int((nx * 0.5 + 0.5) * 255))))
                px[o + 1] = UInt8(max(0, min(255, Int((ny * 0.5 + 0.5) * 255))))
                px[o + 2] = UInt8(max(0, min(255, Int((nz * 0.5 + 0.5) * 255))))
                px[o + 3] = 255
            }
        }
        return WTex.imageFromPixels(px, s, s, hasAlpha: false)
    }

    /// twill carbon weave normal map
    static func carbon(size: Int) -> UIImage {
        let s: Int = max(32, min(size, 256))
        var px: [UInt8] = [UInt8](repeating: 255, count: s * s * 4)
        let cell: Int = max(4, s / 16)
        for y in 0..<s {
            for x in 0..<s {
                let cx: Int = (x / cell + y / cell) % 2
                let fx: Float = Float(x % cell) / Float(cell) - 0.5
                let fy: Float = Float(y % cell) / Float(cell) - 0.5
                // alternating ridges along x / y
                let ridge: Float = cx == 0 ? sinf(fy * Float.pi * 2) : sinf(fx * Float.pi * 2)
                let dx: Float = cx == 0 ? 0 : ridge * 0.35
                let dy: Float = cx == 0 ? ridge * 0.35 : 0
                let inv: Float = 1 / sqrtf(dx * dx + dy * dy + 1)
                let o: Int = (y * s + x) * 4
                px[o] = UInt8(max(0, min(255, Int((dx * inv * 0.5 + 0.5) * 255))))
                px[o + 1] = UInt8(max(0, min(255, Int((dy * inv * 0.5 + 0.5) * 255))))
                px[o + 2] = UInt8(max(0, min(255, Int((inv * 0.5 + 0.5) * 255))))
                px[o + 3] = 255
            }
        }
        return WTex.imageFromPixels(px, s, s, hasAlpha: false)
    }

    /// Realistic finishing of the Porsche cockpit materials (values only touch the parts named by the model):
    /// leather steering rim with grain, satin plastic, twill carbon with a glossy clear-coat look, soft-touch dash, alcantara-like seats.
    @MainActor
    static func refineCockpit(root: SCNNode) {
        let leather: UIImage = grain(size: 128, seed: 7, octaves: 4, strength: 0.9)
        let soft: UIImage = grain(size: 128, seed: 19, octaves: 3, strength: 0.45)
        let weave: UIImage = carbon(size: 128)
        var seen = Set<ObjectIdentifier>()
        root.enumerateHierarchy { (n: SCNNode, _: UnsafeMutablePointer<ObjCBool>) in
            guard let geo = n.geometry else { return }
            for m in geo.materials {
                if seen.contains(ObjectIdentifier(m)) { continue }
                seen.insert(ObjectIdentifier(m))
                let name: String = m.name ?? ""
                switch name {
                case "interior_steer":
                    m.roughness.contents = NSNumber(value: 0.58)
                    m.normal.contents = leather
                    m.normal.wrapS = SCNWrapMode.repeat
                    m.normal.wrapT = SCNWrapMode.repeat
                    m.normal.contentsTransform = SCNMatrix4MakeScale(6, 6, 1)
                    m.normal.intensity = 0.7
                case "interior_steer_plastic":
                    m.roughness.contents = NSNumber(value: 0.38)
                    m.metalness.contents = NSNumber(value: 0.05)
                case "interior_steer_carbon", "interior_carbon":
                    m.roughness.contents = NSNumber(value: 0.24)
                    m.metalness.contents = NSNumber(value: 0.28)
                    m.normal.contents = weave
                    m.normal.wrapS = SCNWrapMode.repeat
                    m.normal.wrapT = SCNWrapMode.repeat
                    m.normal.contentsTransform = SCNMatrix4MakeScale(10, 10, 1)
                    m.normal.intensity = 0.8
                case "interior_dash", "interior_trim":
                    m.roughness.contents = NSNumber(value: 0.62)
                    m.normal.contents = soft
                    m.normal.wrapS = SCNWrapMode.repeat
                    m.normal.wrapT = SCNWrapMode.repeat
                    m.normal.contentsTransform = SCNMatrix4MakeScale(8, 8, 1)
                    m.normal.intensity = 0.35
                case "interior_seat":
                    m.roughness.contents = NSNumber(value: 0.88)
                    m.normal.contents = soft
                    m.normal.wrapS = SCNWrapMode.repeat
                    m.normal.wrapT = SCNWrapMode.repeat
                    m.normal.contentsTransform = SCNMatrix4MakeScale(12, 12, 1)
                    m.normal.intensity = 0.5
                default:
                    break
                }
            }
        }
    }
}
