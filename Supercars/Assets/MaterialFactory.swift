import Foundation
import SceneKit
import UIKit

// MARK: - MaterialFactory: small helpers for PBR materials built from colours / procedural textures.

enum MaterialFactory {
    /// Configures a material property for a repeating, mip-mapped, anisotropic texture (the settings procedural textures should use).
    static func setTexture(_ prop: SCNMaterialProperty, _ image: UIImage, repeating: Bool = true) {
        prop.contents = image
        prop.wrapS = repeating ? SCNWrapMode.repeat : SCNWrapMode.clamp
        prop.wrapT = repeating ? SCNWrapMode.repeat : SCNWrapMode.clamp
        prop.minificationFilter = SCNFilterMode.linear
        prop.magnificationFilter = SCNFilterMode.linear
        prop.mipFilter = SCNFilterMode.linear
        prop.maxAnisotropy = 4
    }

    static func pbr(color: UIColor, metalness: Float = 0, roughness: Float = 0.6, name: String? = nil) -> SCNMaterial {
        let m: SCNMaterial = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.physicallyBased
        m.isLitPerPixel = true
        m.diffuse.contents = color
        m.metalness.contents = NSNumber(value: metalness)
        m.roughness.contents = NSNumber(value: roughness)
        return m
    }

    static func textured(_ image: UIImage, metalness: Float = 0, roughness: Float = 0.7, doubleSided: Bool = false, name: String? = nil) -> SCNMaterial {
        let m: SCNMaterial = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.physicallyBased
        m.isLitPerPixel = true
        setTexture(m.diffuse, image)
        m.metalness.contents = NSNumber(value: metalness)
        m.roughness.contents = NSNumber(value: roughness)
        m.isDoubleSided = doubleSided
        return m
    }

    /// Diffuse texture + a matching emissive texture (e.g. lit windows at night). `emissionIntensity` scales the glow (HDR bloom picks it up).
    static func texturedEmissive(_ image: UIImage, emission: UIImage, emissionIntensity: Float = 1, metalness: Float = 0.1, roughness: Float = 0.4,
                                 name: String? = nil) -> SCNMaterial {
        let m: SCNMaterial = textured(image, metalness: metalness, roughness: roughness, name: name)
        setTexture(m.emission, emission)
        m.emission.intensity = CGFloat(emissionIntensity)
        return m
    }

    static func emissive(color: UIColor, intensity: Float = 1, name: String? = nil) -> SCNMaterial {
        let m: SCNMaterial = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.emission.intensity = CGFloat(intensity)
        return m
    }

    /// Transparent tinted glass (no depth writes).
    static func glass(tint: UIColor, opacity: Float = 0.35, name: String? = nil) -> SCNMaterial {
        let m: SCNMaterial = SCNMaterial()
        m.name = name
        m.lightingModel = SCNMaterial.LightingModel.physicallyBased
        m.isLitPerPixel = true
        m.diffuse.contents = tint
        m.metalness.contents = NSNumber(value: 0.0)
        m.roughness.contents = NSNumber(value: 0.05)
        m.transparency = CGFloat(opacity)
        m.blendMode = SCNBlendMode.alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }
}
