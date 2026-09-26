import Foundation
import SceneKit
import UIKit
import simd

// MARK: - glTF 2.0 binary loader (no third-party code).
//
//   let asset = try GLBAsset.load(url: url, options: GLBLoadOptions())   // parse ONCE (geometry, materials, textures, skins)
//   let node  = asset.instantiate()                                       // NEW node hierarchy each call; geometry + materials shared; skins re-bound
//   let node2 = try GLBLoader.load(url: url, options: GLBLoadOptions())   // one-shot convenience
//
// Conventions (verified against the real input files by tools/check_glb_reader.py):
//  * glTF is right-handed, +Y up, metres; SceneKit is the same -> NO axis flip, node transforms are copied exactly (simdTransform / TRS).
//  * Triangle winding: glTF front faces are counter-clockwise, SceneKit's default is counter-clockwise too -> indices are copied unchanged.
//  * TEXTURE V: glTF texture space has its origin at the TOP-left of the image (v grows downwards). SceneKit (like OpenGL / Collada) uses
//    v = 0 at the BOTTOM of a UIImage-backed material property: e.g. SCNPlane maps (0,0) to its bottom-left corner and shows an upright UIImage.
//    Therefore every UV is converted v' = 1 - v while reading the mesh (options.flipV, default true), and the image itself stays untouched.
//    Tangents keep their handedness: a glTF normal map has +Y (green) pointing "up" in the image, which is the +v' direction after the flip.
//  * Materials: PBR lighting model, per-pixel lighting. The base colour factor (linear) is baked into the texels (exact in linear light),
//    roughness (glTF G channel) and metalness (B channel) are split into two single channel greyscale images, occlusion uses the R channel.
//  * Skins: one SCNSkinner per skinned node INSTANCE (SceneKit's clone() would share the skinner with the source bones); bones are the joint
//    nodes of that instance in the skin's joint order, inverse bind matrices are copied column-major (glTF and SCNMatrix4 memory layouts agree).

struct GLBLoadOptions {
    /// textures larger than this (either side) are down-scaled while decoding
    var maxTextureSize: Int = 2048
    var generateMipmaps: Bool = true
    var anisotropy: Float = 4
    /// nil = default (true: convert glTF's top-left UV origin to SceneKit's bottom-left origin, see the file header)
    var flipV: Bool? = nil
}

// MARK: - Immutable template

struct GLBNodeTemplate {
    var name: String? = nil
    var useMatrix: Bool = false
    var matrix: simd_float4x4 = matrix_identity_float4x4
    var translation: Vec3 = Vec3(0, 0, 0)
    var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var scale: Vec3 = Vec3(1, 1, 1)
    var children: [Int] = []
    var mesh: Int? = nil
    var skin: Int? = nil

    /// exact local matrix (T * R * S for TRS nodes)
    func localMatrix() -> simd_float4x4 {
        if useMatrix { return matrix }
        let q: simd_quatf = rotation
        let x: Float = q.imag.x
        let y: Float = q.imag.y
        let z: Float = q.imag.z
        let w: Float = q.real
        let c0: SIMD4<Float> = SIMD4<Float>(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0)
        let c1: SIMD4<Float> = SIMD4<Float>(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0)
        let c2: SIMD4<Float> = SIMD4<Float>(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0)
        let c3: SIMD4<Float> = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return simd_float4x4(columns: (c0 * scale.x, c1 * scale.y, c2 * scale.z, c3))
    }
}

final class GLBMeshTemplate {
    let geometry: SCNGeometry
    let boneWeights: SCNGeometrySource?
    let boneIndices: SCNGeometrySource?
    let triangleCount: Int

    init(geometry: SCNGeometry, boneWeights: SCNGeometrySource?, boneIndices: SCNGeometrySource?, triangleCount: Int) {
        self.geometry = geometry
        self.boneWeights = boneWeights
        self.boneIndices = boneIndices
        self.triangleCount = triangleCount
    }
}

final class GLBSkinTemplate {
    let name: String?
    let joints: [Int]              // glTF node indices in skin order
    let skeleton: Int              // glTF node index used as skinner.skeleton
    let inverseBind: [NSValue]     // SCNMatrix4 values, one per joint

    init(name: String?, joints: [Int], skeleton: Int, inverseBind: [NSValue]) {
        self.name = name
        self.joints = joints
        self.skeleton = skeleton
        self.inverseBind = inverseBind
    }
}

/// A parsed glTF file. Immutable after `load`, so instantiating (even from several threads) is safe.
final class GLBAsset: @unchecked Sendable {
    let name: String
    let sceneName: String?
    let nodeTemplates: [GLBNodeTemplate]
    let roots: [Int]
    let meshTemplates: [Int: GLBMeshTemplate]
    let skinTemplates: [GLBSkinTemplate]
    let triangleCount: Int

    init(name: String, sceneName: String?, nodeTemplates: [GLBNodeTemplate], roots: [Int], meshTemplates: [Int: GLBMeshTemplate],
         skinTemplates: [GLBSkinTemplate]) {
        self.name = name
        self.sceneName = sceneName
        self.nodeTemplates = nodeTemplates
        self.roots = roots
        self.meshTemplates = meshTemplates
        self.skinTemplates = skinTemplates
        var tris: Int = 0
        for (_, m) in meshTemplates { tris += m.triangleCount }
        self.triangleCount = tris
    }

    static func load(url: URL, options: GLBLoadOptions) throws -> GLBAsset {
        let builder: GLBSceneBuilder = try GLBSceneBuilder(url: url, options: options)
        return try builder.build()
    }

    /// Builds a NEW node hierarchy. Geometry and materials are shared with every other instance; skinned meshes get a fresh SCNSkinner bound
    /// to the joint nodes of THIS instance. Node names are exactly the glTF node names.
    func instantiate() -> SCNNode {
        var made: [SCNNode?] = [SCNNode?](repeating: nil, count: nodeTemplates.count)

        func make(_ index: Int) -> SCNNode? {
            if index < 0 || index >= nodeTemplates.count { return nil }
            if made[index] != nil { return nil }
            let t: GLBNodeTemplate = nodeTemplates[index]
            let n: SCNNode = SCNNode()
            n.name = t.name
            if t.useMatrix {
                n.simdTransform = t.matrix
            } else {
                n.simdPosition = t.translation
                n.simdOrientation = t.rotation
                n.simdScale = t.scale
            }
            made[index] = n
            if let mi = t.mesh, let mt = meshTemplates[mi] {
                n.geometry = mt.geometry
            }
            for c in t.children {
                if let child = make(c) { n.addChildNode(child) }
            }
            return n
        }

        var top: SCNNode? = nil
        if roots.count == 1 {
            top = make(roots[0])
        } else {
            let container: SCNNode = SCNNode()
            container.name = sceneName ?? name
            for r in roots {
                if let n = make(r) { container.addChildNode(n) }
            }
            top = container
        }

        // skins: one skinner per skinned node instance
        for i in 0..<nodeTemplates.count {
            let t: GLBNodeTemplate = nodeTemplates[i]
            guard let node = made[i], let si = t.skin, let mi = t.mesh else { continue }
            if si < 0 || si >= skinTemplates.count { continue }
            guard let mt = meshTemplates[mi], let weights = mt.boneWeights, let indices = mt.boneIndices else { continue }
            let st: GLBSkinTemplate = skinTemplates[si]
            var bones: [SCNNode] = []
            bones.reserveCapacity(st.joints.count)
            for j in st.joints {
                if j >= 0 && j < made.count, let b = made[j] {
                    bones.append(b)
                } else {
                    bones.append(SCNNode())   // joint outside the scene graph: harmless placeholder
                }
            }
            let skinner: SCNSkinner = SCNSkinner(baseGeometry: mt.geometry, bones: bones, boneInverseBindTransforms: st.inverseBind,
                                                 boneWeights: weights, boneIndices: indices)
            var skeletonNode: SCNNode? = nil
            if st.skeleton >= 0 && st.skeleton < made.count { skeletonNode = made[st.skeleton] }
            skinner.skeleton = skeletonNode ?? bones.first
            node.skinner = skinner
        }
        return top ?? SCNNode()
    }
}

enum GLBLoader {
    /// One-shot: parse + instantiate (use `GLBAsset` / `AssetLibrary` when the same model is needed more than once).
    static func load(url: URL, options: GLBLoadOptions = GLBLoadOptions()) throws -> SCNNode {
        let asset: GLBAsset = try GLBAsset.load(url: url, options: options)
        return asset.instantiate()
    }
}

// MARK: - Geometry helpers

enum GLBGeometryMath {
    /// Smooth (area weighted) vertex normals for indexed triangles.
    static func smoothNormals(positions: [Float], indices: [UInt32]) -> [Float] {
        var acc: [Float] = [Float](repeating: 0, count: positions.count)
        let vertexCount: Int = positions.count / 3
        let triCount: Int = indices.count / 3
        for t in 0..<triCount {
            let i0: Int = Int(indices[t * 3])
            let i1: Int = Int(indices[t * 3 + 1])
            let i2: Int = Int(indices[t * 3 + 2])
            if i0 >= vertexCount || i1 >= vertexCount || i2 >= vertexCount { continue }
            let p0: Vec3 = Vec3(positions[i0 * 3], positions[i0 * 3 + 1], positions[i0 * 3 + 2])
            let p1: Vec3 = Vec3(positions[i1 * 3], positions[i1 * 3 + 1], positions[i1 * 3 + 2])
            let p2: Vec3 = Vec3(positions[i2 * 3], positions[i2 * 3 + 1], positions[i2 * 3 + 2])
            let n: Vec3 = simd_cross(p1 - p0, p2 - p0)
            for k in 0..<3 {
                let vi: Int = Int(indices[t * 3 + k])
                acc[vi * 3] += n.x
                acc[vi * 3 + 1] += n.y
                acc[vi * 3 + 2] += n.z
            }
        }
        for v in 0..<vertexCount {
            let n: Vec3 = Vec3(acc[v * 3], acc[v * 3 + 1], acc[v * 3 + 2])
            let l: Float = simd_length(n)
            if l > 1e-12 {
                acc[v * 3] = n.x / l
                acc[v * 3 + 1] = n.y / l
                acc[v * 3 + 2] = n.z / l
            } else {
                acc[v * 3] = 0
                acc[v * 3 + 1] = 1
                acc[v * 3 + 2] = 0
            }
        }
        return acc
    }

    /// Unit-length normals (in place); zero vectors become +Y.
    static func normalize3(_ a: inout [Float]) {
        let n: Int = a.count / 3
        for i in 0..<n {
            let x: Float = a[i * 3]
            let y: Float = a[i * 3 + 1]
            let z: Float = a[i * 3 + 2]
            let l: Float = sqrtf(x * x + y * y + z * z)
            if l > 1e-12 {
                a[i * 3] = x / l
                a[i * 3 + 1] = y / l
                a[i * 3 + 2] = z / l
            } else {
                a[i * 3] = 0
                a[i * 3 + 1] = 1
                a[i * 3 + 2] = 0
            }
        }
    }

    static func floatSource(_ semantic: SCNGeometrySource.Semantic, _ values: [Float], components: Int) -> SCNGeometrySource {
        let data: Data = values.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<Float>) -> Data in
            return Data(buffer: buf)
        }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: values.count / components, usesFloatComponents: true,
                                 componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0, dataStride: components * 4)
    }

    static func indexData(_ indices: [UInt32], wide: Bool) -> Data {
        if wide {
            return indices.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt32>) -> Data in
                return Data(buffer: buf)
            }
        }
        var small: [UInt16] = []
        small.reserveCapacity(indices.count)
        for i in indices { small.append(UInt16(truncatingIfNeeded: i)) }
        return small.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt16>) -> Data in
            return Data(buffer: buf)
        }
    }
}

// MARK: - Builder (file -> GLBAsset)

/// Vertex arrays of one primitive, already converted to tightly packed Float32 / UInt16.
struct GLBPrimitiveVertices {
    var vertexCount: Int = 0
    var positions: [Float] = []
    var normals: [Float] = []          // 3 per vertex (generated when the file has none)
    var uv0: [Float]? = nil
    var uv1: [Float]? = nil
    var colors: [Float]? = nil         // 4 per vertex
    var tangents: [Float]? = nil       // 4 per vertex
    var joints: [UInt16]? = nil        // 4 per vertex
    var weights: [Float]? = nil        // 4 per vertex, normalised
}

final class GLBSceneBuilder {
    private let url: URL
    private let options: GLBLoadOptions
    private let binary: GLBBinaryStore
    private let images: GLBImageStore
    private let flipV: Bool
    private var materialCache: [Int: SCNMaterial] = [:]
    private var defaultMaterial: SCNMaterial? = nil
    private var warned: Set<String> = []

    init(url: URL, options: GLBLoadOptions) throws {
        self.url = url
        self.options = options
        let name: String = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url, options: Data.ReadingOptions.mappedIfSafe)
        } catch {
            throw AssetError.unreadable(name, error.localizedDescription)
        }
        let store: GLBBinaryStore = try GLBBinaryStore(fileData: data, fileName: name, directory: url.deletingLastPathComponent())
        self.binary = store
        self.images = GLBImageStore(binary: store, maxSize: options.maxTextureSize)
        self.flipV = options.flipV ?? true
    }

    private func warnOnce(_ text: String) {
        if warned.contains(text) { return }
        warned.insert(text)
        assetLog("GLB \(binary.fileName): \(text)")
    }

    // MARK: build

    func build() throws -> GLBAsset {
        let root: GLBSchema.Root = binary.root
        let gltfNodes: [GLBSchema.Node] = root.nodes ?? []
        let fileName: String = binary.fileName

        // --- node templates
        var templates: [GLBNodeTemplate] = []
        templates.reserveCapacity(gltfNodes.count)
        for n in gltfNodes {
            var t: GLBNodeTemplate = GLBNodeTemplate()
            t.name = n.name
            t.children = n.children ?? []
            t.mesh = n.mesh
            t.skin = n.skin
            if let m = n.matrix, m.count == 16 {
                let c0: SIMD4<Float> = SIMD4<Float>(m[0], m[1], m[2], m[3])
                let c1: SIMD4<Float> = SIMD4<Float>(m[4], m[5], m[6], m[7])
                let c2: SIMD4<Float> = SIMD4<Float>(m[8], m[9], m[10], m[11])
                let c3: SIMD4<Float> = SIMD4<Float>(m[12], m[13], m[14], m[15])
                t.useMatrix = true
                t.matrix = simd_float4x4(columns: (c0, c1, c2, c3))
            } else {
                if let tr = n.translation, tr.count == 3 { t.translation = Vec3(tr[0], tr[1], tr[2]) }
                if let r = n.rotation, r.count == 4 {
                    let q: simd_quatf = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
                    t.rotation = simd_length(q.vector) > 1e-8 ? q.normalized : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                }
                if let s = n.scale, s.count == 3 { t.scale = Vec3(s[0], s[1], s[2]) }
            }
            templates.append(t)
        }

        // --- scene roots + parent map
        var parent: [Int] = [Int](repeating: -1, count: templates.count)
        for (i, t) in templates.enumerated() {
            for c in t.children where c >= 0 && c < templates.count {
                parent[c] = i
            }
        }
        var roots: [Int] = []
        var sceneName: String? = nil
        let scenes: [GLBSchema.Scene] = root.scenes ?? []
        if !scenes.isEmpty {
            var si: Int = root.scene ?? 0
            if si < 0 || si >= scenes.count { si = 0 }
            roots = (scenes[si].nodes ?? []).filter { $0 >= 0 && $0 < templates.count }
            sceneName = scenes[si].name
        } else {
            for i in 0..<templates.count where parent[i] < 0 { roots.append(i) }
        }
        if roots.isEmpty && templates.isEmpty {
            throw AssetError.malformed(fileName, "the file contains no nodes")
        }

        // --- skins (skeleton root + inverse bind matrices)
        let gltfSkins: [GLBSchema.Skin] = root.skins ?? []
        var skinSkeletons: [Int] = []
        for s in gltfSkins {
            skinSkeletons.append(chooseSkeleton(skin: s, parent: parent, nodeCount: templates.count))
        }

        // --- skinned mesh nodes must live in the frame of their skeleton (SceneKit skins relative to the skeleton / skinner node)
        reparentSkinnedNodes(templates: &templates, roots: &roots, parent: &parent, skinSkeletons: skinSkeletons)

        var skinTemplates: [GLBSkinTemplate] = []
        for (si, s) in gltfSkins.enumerated() {
            let n: Int = s.joints.count
            var ibm: [Float] = []
            if let acc = s.inverseBindMatrices {
                do {
                    ibm = try binary.floats(accessor: acc)
                } catch {
                    warnOnce("skin \(si): unreadable inverse bind matrices (\(error.localizedDescription)); using identity")
                }
                if ibm.count != n * 16 {
                    if !ibm.isEmpty { warnOnce("skin \(si): \(ibm.count / 16) inverse bind matrices for \(n) joints; using identity") }
                    ibm = []
                }
            }
            var values: [NSValue] = []
            values.reserveCapacity(n)
            for j in 0..<n {
                var m: simd_float4x4 = matrix_identity_float4x4
                if !ibm.isEmpty {
                    let b: Int = j * 16
                    let c0: SIMD4<Float> = SIMD4<Float>(ibm[b], ibm[b + 1], ibm[b + 2], ibm[b + 3])
                    let c1: SIMD4<Float> = SIMD4<Float>(ibm[b + 4], ibm[b + 5], ibm[b + 6], ibm[b + 7])
                    let c2: SIMD4<Float> = SIMD4<Float>(ibm[b + 8], ibm[b + 9], ibm[b + 10], ibm[b + 11])
                    let c3: SIMD4<Float> = SIMD4<Float>(ibm[b + 12], ibm[b + 13], ibm[b + 14], ibm[b + 15])
                    m = simd_float4x4(columns: (c0, c1, c2, c3))
                }
                values.append(NSValue(scnMatrix4: SCNMatrix4(m)))
            }
            skinTemplates.append(GLBSkinTemplate(name: s.name, joints: s.joints, skeleton: skinSkeletons[si], inverseBind: values))
        }

        // --- meshes referenced by the scene graph
        var reachable: [Bool] = [Bool](repeating: false, count: templates.count)
        var stack: [Int] = roots
        while let i = stack.popLast() {
            if reachable[i] { continue }
            reachable[i] = true
            for c in templates[i].children where c >= 0 && c < templates.count { stack.append(c) }
        }
        var meshTemplates: [Int: GLBMeshTemplate] = [:]
        var skinnedMeshes: Set<Int> = []
        for i in 0..<templates.count where reachable[i] {
            if let mi = templates[i].mesh, templates[i].skin != nil { skinnedMeshes.insert(mi) }
        }
        for i in 0..<templates.count where reachable[i] {
            guard let mi = templates[i].mesh else { continue }
            if meshTemplates[mi] != nil { continue }
            if let mt = try buildMesh(index: mi, wantsSkin: skinnedMeshes.contains(mi)) {
                meshTemplates[mi] = mt
            }
        }
        images.releaseScratch()

        let asset: GLBAsset = GLBAsset(name: fileName, sceneName: sceneName, nodeTemplates: templates, roots: roots,
                                       meshTemplates: meshTemplates, skinTemplates: skinTemplates)
        assetLog("GLB \(fileName): \(templates.count) nodes, \(meshTemplates.count) meshes, \(asset.triangleCount) triangles, \(materialCache.count) materials, \(images.decodedCount) images (\(images.failedCount) failed), \(skinTemplates.count) skins")
        return asset
    }

    // MARK: skeleton helpers

    private func chain(of node: Int, parent: [Int]) -> [Int] {
        var c: [Int] = []
        var n: Int = node
        var guardCount: Int = 0
        while n >= 0 && guardCount <= parent.count {
            c.append(n)
            n = parent[n]
            guardCount += 1
        }
        c.reverse()
        return c
    }

    private func chooseSkeleton(skin: GLBSchema.Skin, parent: [Int], nodeCount: Int) -> Int {
        if let s = skin.skeleton, s >= 0 && s < nodeCount { return s }
        let joints: [Int] = skin.joints.filter { $0 >= 0 && $0 < nodeCount }
        guard let first = joints.first else { return 0 }
        var common: [Int] = chain(of: first, parent: parent)
        for j in joints.dropFirst() {
            let other: [Int] = chain(of: j, parent: parent)
            var k: Int = 0
            while k < common.count && k < other.count && common[k] == other[k] { k += 1 }
            common = Array(common.prefix(k))
            if common.isEmpty { break }
        }
        if let last = common.last { return last }
        return first
    }

    private func worldMatrix(_ node: Int, templates: [GLBNodeTemplate], parent: [Int]) -> simd_float4x4 {
        var m: simd_float4x4 = templates[node].localMatrix()
        var p: Int = parent[node]
        var guardCount: Int = 0
        while p >= 0 && guardCount <= templates.count {
            m = templates[p].localMatrix() * m
            p = parent[p]
            guardCount += 1
        }
        return m
    }

    private func maxAbsDifference(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        var d: Float = 0
        let ac: [SIMD4<Float>] = [a.columns.0, a.columns.1, a.columns.2, a.columns.3]
        let bc: [SIMD4<Float>] = [b.columns.0, b.columns.1, b.columns.2, b.columns.3]
        for i in 0..<4 {
            let diff: SIMD4<Float> = ac[i] - bc[i]
            d = max(d, max(max(abs(diff.x), abs(diff.y)), max(abs(diff.z), abs(diff.w))))
        }
        return d
    }

    /// SceneKit evaluates a skinner relative to its skeleton / node. If the skinned mesh node sits in a different frame than the skeleton root
    /// (typical for Blender / FBX exports) it is moved next to the skeleton root with the skeleton's local transform, so both interpretations
    /// (node-space or skeleton-space skinning) produce the glTF result. Names are untouched; nothing happens when the frames already agree.
    private func reparentSkinnedNodes(templates: inout [GLBNodeTemplate], roots: inout [Int], parent: inout [Int], skinSkeletons: [Int]) {
        for i in 0..<templates.count {
            guard let si = templates[i].skin, templates[i].mesh != nil else { continue }
            if si < 0 || si >= skinSkeletons.count { continue }
            let sk: Int = skinSkeletons[si]
            if sk == i || sk < 0 || sk >= templates.count { continue }
            let newParent: Int = parent[sk]
            if newParent < 0 { continue }
            if chain(of: newParent, parent: parent).contains(i) { continue }   // the skeleton lives below the mesh node
            let wm: simd_float4x4 = worldMatrix(i, templates: templates, parent: parent)
            let ws: simd_float4x4 = worldMatrix(sk, templates: templates, parent: parent)
            let scaleRef: Float = max(1, maxAbsDifference(ws, matrix_identity_float4x4))
            if maxAbsDifference(wm, ws) <= 1e-4 * scaleRef { continue }
            let oldParent: Int = parent[i]
            if oldParent >= 0 {
                templates[oldParent].children.removeAll(where: { $0 == i })
            } else {
                roots.removeAll(where: { $0 == i })
            }
            templates[newParent].children.append(i)
            parent[i] = newParent
            templates[i].useMatrix = true
            templates[i].matrix = templates[sk].localMatrix()
            warnOnce("skinned node '\(templates[i].name ?? "?")' moved next to skeleton root '\(templates[sk].name ?? "?")'")
        }
    }

    // MARK: materials

    private func textureSource(_ textureIndex: Int) -> Int? {
        let textures: [GLBSchema.Texture] = binary.root.textures ?? []
        if textureIndex < 0 || textureIndex >= textures.count { return nil }
        return textures[textureIndex].source
    }

    private func linearColor(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> Any {
        let components: [CGFloat] = [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
        if let space = CGColorSpace(name: CGColorSpace.linearSRGB), let c = CGColor(colorSpace: space, components: components) {
            return c
        }
        return UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    private func wrapMode(_ value: Int?) -> SCNWrapMode {
        switch value ?? 10497 {
        case 33071: return SCNWrapMode.clamp
        case 33648: return SCNWrapMode.mirror
        default: return SCNWrapMode.repeat
        }
    }

    private func configureTexture(_ prop: SCNMaterialProperty, texture textureIndex: Int, texCoord: Int?) {
        let textures: [GLBSchema.Texture] = binary.root.textures ?? []
        var sampler: GLBSchema.Sampler? = nil
        if textureIndex >= 0 && textureIndex < textures.count, let si = textures[textureIndex].sampler {
            let samplers: [GLBSchema.Sampler] = binary.root.samplers ?? []
            if si >= 0 && si < samplers.count { sampler = samplers[si] }
        }
        prop.wrapS = wrapMode(sampler?.wrapS)
        prop.wrapT = wrapMode(sampler?.wrapT)
        let mag: Int = sampler?.magFilter ?? 9729
        prop.magnificationFilter = (mag == 9728) ? SCNFilterMode.nearest : SCNFilterMode.linear
        let minF: Int = sampler?.minFilter ?? 9987
        prop.minificationFilter = (minF == 9728 || minF == 9984 || minF == 9986) ? SCNFilterMode.nearest : SCNFilterMode.linear
        prop.mipFilter = options.generateMipmaps ? SCNFilterMode.linear : SCNFilterMode.none
        prop.maxAnisotropy = CGFloat(max(1, options.anisotropy))
        var channel: Int = texCoord ?? 0
        if channel > 1 {
            warnOnce("texCoord \(channel) is not supported (using TEXCOORD_0)")
            channel = 0
        }
        prop.mappingChannel = channel
    }

    private func materialUsesSecondUV(_ index: Int) -> Bool {
        let mats: [GLBSchema.Material] = binary.root.materials ?? []
        if index < 0 || index >= mats.count { return false }
        let m: GLBSchema.Material = mats[index]
        if (m.pbrMetallicRoughness?.baseColorTexture?.texCoord ?? 0) == 1 { return true }
        if (m.pbrMetallicRoughness?.metallicRoughnessTexture?.texCoord ?? 0) == 1 { return true }
        if (m.normalTexture?.texCoord ?? 0) == 1 { return true }
        if (m.occlusionTexture?.texCoord ?? 0) == 1 { return true }
        if (m.emissiveTexture?.texCoord ?? 0) == 1 { return true }
        return false
    }

    private func material(at index: Int?) -> SCNMaterial {
        let mats: [GLBSchema.Material] = binary.root.materials ?? []
        guard let idx = index, idx >= 0, idx < mats.count else {
            if let d = defaultMaterial { return d }
            let d: SCNMaterial = SCNMaterial()
            d.name = "default"
            d.lightingModel = SCNMaterial.LightingModel.physicallyBased
            d.diffuse.contents = UIColor(white: 0.8, alpha: 1)
            d.metalness.contents = NSNumber(value: 0.0)
            d.roughness.contents = NSNumber(value: 0.8)
            d.isDoubleSided = true
            defaultMaterial = d
            return d
        }
        if let cached = materialCache[idx] { return cached }
        let built: SCNMaterial = buildMaterial(mats[idx], index: idx)
        materialCache[idx] = built
        return built
    }

    private func buildMaterial(_ gm: GLBSchema.Material, index: Int) -> SCNMaterial {
        let m: SCNMaterial = SCNMaterial()
        m.name = gm.name ?? "material_\(index)"
        m.lightingModel = SCNMaterial.LightingModel.physicallyBased
        m.isLitPerPixel = true
        m.isDoubleSided = gm.doubleSided ?? false
        let mode: String = gm.alphaMode ?? "OPAQUE"
        let pbr: GLBSchema.PBR? = gm.pbrMetallicRoughness

        // base colour
        var factor: [Float] = pbr?.baseColorFactor ?? [1, 1, 1, 1]
        while factor.count < 4 { factor.append(1) }
        var diffuseDone: Bool = false
        if let ti = pbr?.baseColorTexture, let src = textureSource(ti.index) {
            if let img = images.colorImage(image: src, tint: (factor[0], factor[1], factor[2]), dropAlpha: mode == "OPAQUE") {
                m.diffuse.contents = img
                configureTexture(m.diffuse, texture: ti.index, texCoord: ti.texCoord)
                diffuseDone = true
            } else {
                warnOnce("material '\(m.name ?? "?")': base colour texture could not be decoded")
            }
        }
        if !diffuseDone {
            m.diffuse.contents = linearColor(factor[0], factor[1], factor[2], 1)
        }
        if mode == "BLEND" && factor[3] < 0.999 {
            m.transparency = CGFloat(max(0, factor[3]))
        }

        // metallic / roughness
        let mf: Float = pbr?.metallicFactor ?? 1
        let rf: Float = pbr?.roughnessFactor ?? 1
        var mrDone: Bool = false
        if let ti = pbr?.metallicRoughnessTexture, let src = textureSource(ti.index) {
            let metal: UIImage? = images.grayImage(image: src, channel: 2, scale: mf)
            let rough: UIImage? = images.grayImage(image: src, channel: 1, scale: rf)
            if let mi = metal, let ri = rough {
                m.metalness.contents = mi
                m.roughness.contents = ri
                configureTexture(m.metalness, texture: ti.index, texCoord: ti.texCoord)
                configureTexture(m.roughness, texture: ti.index, texCoord: ti.texCoord)
                mrDone = true
            }
        }
        if !mrDone {
            m.metalness.contents = NSNumber(value: mf)
            m.roughness.contents = NSNumber(value: rf)
        }

        // normal map
        if let nt = gm.normalTexture, let src = textureSource(nt.index) {
            if let img = images.colorImage(image: src, tint: (1, 1, 1), dropAlpha: true) {
                m.normal.contents = img
                configureTexture(m.normal, texture: nt.index, texCoord: nt.texCoord)
                let scale: Float = nt.scale ?? 1
                if abs(scale - 1) > 0.001 { m.normal.intensity = CGFloat(scale) }
            }
        }

        // ambient occlusion (R channel)
        if let ot = gm.occlusionTexture, let src = textureSource(ot.index) {
            if let img = images.grayImage(image: src, channel: 0, scale: 1) {
                m.ambientOcclusion.contents = img
                configureTexture(m.ambientOcclusion, texture: ot.index, texCoord: ot.texCoord)
                let strength: Float = ot.strength ?? 1
                if abs(strength - 1) > 0.001 { m.ambientOcclusion.intensity = CGFloat(strength) }
            }
        }

        // emission
        var ef: [Float] = gm.emissiveFactor ?? [0, 0, 0]
        while ef.count < 3 { ef.append(0) }
        let strength: Float = gm.extensions?.KHR_materials_emissive_strength?.emissiveStrength ?? 1
        let emissiveMax: Float = max(ef[0], max(ef[1], ef[2]))
        if let et = gm.emissiveTexture, let src = textureSource(et.index) {
            if emissiveMax > 0.0001 {
                if let img = images.colorImage(image: src, tint: (ef[0], ef[1], ef[2]), dropAlpha: true) {
                    m.emission.contents = img
                    configureTexture(m.emission, texture: et.index, texCoord: et.texCoord)
                    m.emission.intensity = CGFloat(strength)
                }
            }
        } else if emissiveMax > 0.0001 {
            m.emission.contents = linearColor(ef[0], ef[1], ef[2], 1)
            m.emission.intensity = CGFloat(strength)
        }

        // alpha modes
        if mode == "BLEND" {
            m.blendMode = SCNBlendMode.alpha
            m.writesToDepthBuffer = false
            m.readsFromDepthBuffer = true
        } else if mode == "MASK" {
            // cut-out: fragments below the cutoff are discarded, the rest are drawn like opaque geometry (depth writes stay on)
            let cutoff: Float = gm.alphaCutoff ?? 0.5
            let code: String = String(format: "if (_output.color.a < %.4f) { discard_fragment(); }", cutoff)
            m.shaderModifiers = [SCNShaderModifierEntryPoint.fragment: code]
            m.writesToDepthBuffer = true
        }
        return m
    }

    // MARK: meshes

    private func readPrimitive(_ prim: GLBSchema.Primitive, indices: [UInt32], wantsSkin: Bool, wantsUV1: Bool) throws -> GLBPrimitiveVertices? {
        guard let posAcc = prim.attributes["POSITION"] else { return nil }
        var v: GLBPrimitiveVertices = GLBPrimitiveVertices()
        v.positions = try binary.floats(accessor: posAcc)
        if try binary.accessorType(posAcc) != "VEC3" { return nil }
        v.vertexCount = v.positions.count / 3

        if let na = prim.attributes["NORMAL"], try binary.accessorType(na) == "VEC3" {
            var n: [Float] = try binary.floats(accessor: na)
            if n.count == v.positions.count {
                GLBGeometryMath.normalize3(&n)
                v.normals = n
            }
        }
        if v.normals.isEmpty {
            v.normals = GLBGeometryMath.smoothNormals(positions: v.positions, indices: indices)
            warnOnce("mesh without NORMAL: generated smooth normals")
        }
        if let ta = prim.attributes["TEXCOORD_0"], try binary.accessorType(ta) == "VEC2" {
            var uv: [Float] = try binary.floats(accessor: ta)
            if uv.count == v.vertexCount * 2 {
                if flipV { for i in 0..<v.vertexCount { uv[i * 2 + 1] = 1 - uv[i * 2 + 1] } }
                v.uv0 = uv
            }
        }
        if wantsUV1, let ta = prim.attributes["TEXCOORD_1"], try binary.accessorType(ta) == "VEC2" {
            var uv: [Float] = try binary.floats(accessor: ta)
            if uv.count == v.vertexCount * 2 {
                if flipV { for i in 0..<v.vertexCount { uv[i * 2 + 1] = 1 - uv[i * 2 + 1] } }
                v.uv1 = uv
            }
        }
        if let ca = prim.attributes["COLOR_0"] {
            let type: String = try binary.accessorType(ca)
            let raw: [Float] = try binary.floats(accessor: ca)
            if type == "VEC4" && raw.count == v.vertexCount * 4 {
                v.colors = raw
            } else if type == "VEC3" && raw.count == v.vertexCount * 3 {
                var c: [Float] = [Float](repeating: 1, count: v.vertexCount * 4)
                for i in 0..<v.vertexCount {
                    c[i * 4] = raw[i * 3]
                    c[i * 4 + 1] = raw[i * 3 + 1]
                    c[i * 4 + 2] = raw[i * 3 + 2]
                }
                v.colors = c
            }
        }
        if let ta = prim.attributes["TANGENT"], try binary.accessorType(ta) == "VEC4" {
            let t: [Float] = try binary.floats(accessor: ta)
            if t.count == v.vertexCount * 4 { v.tangents = t }
        }
        if wantsSkin, let ja = prim.attributes["JOINTS_0"], let wa = prim.attributes["WEIGHTS_0"] {
            if try binary.accessorType(ja) == "VEC4", try binary.accessorType(wa) == "VEC4" {
                let j: [UInt32] = try binary.uints(accessor: ja)
                var w: [Float] = try binary.floats(accessor: wa)
                if j.count == v.vertexCount * 4 && w.count == v.vertexCount * 4 {
                    var j16: [UInt16] = [UInt16](repeating: 0, count: j.count)
                    for i in 0..<v.vertexCount {
                        var sum: Float = 0
                        for k in 0..<4 { sum += max(0, w[i * 4 + k]) }
                        if sum > 1e-8 {
                            for k in 0..<4 { w[i * 4 + k] = max(0, w[i * 4 + k]) / sum }
                        } else {
                            w[i * 4] = 1
                            w[i * 4 + 1] = 0
                            w[i * 4 + 2] = 0
                            w[i * 4 + 3] = 0
                        }
                        for k in 0..<4 {
                            let idx: Int = i * 4 + k
                            j16[idx] = w[idx] > 0 ? UInt16(truncatingIfNeeded: min(j[idx], 65535)) : 0
                        }
                    }
                    v.joints = j16
                    v.weights = w
                }
            }
        }
        return v
    }

    /// triangle index list (already in glTF winding) for the primitive; nil for points / lines
    private func triangleIndices(_ prim: GLBSchema.Primitive, vertexCount: Int) throws -> [UInt32]? {
        var idx: [UInt32] = []
        if let ia = prim.indices {
            idx = try binary.uints(accessor: ia)
        } else {
            idx = [UInt32](repeating: 0, count: vertexCount)
            for i in 0..<vertexCount { idx[i] = UInt32(i) }
        }
        let mode: Int = prim.mode ?? 4
        var tris: [UInt32] = []
        switch mode {
        case 4:
            let n: Int = (idx.count / 3) * 3
            tris = Array(idx.prefix(n))
        case 5:
            if idx.count >= 3 {
                tris.reserveCapacity((idx.count - 2) * 3)
                for i in 0..<(idx.count - 2) {
                    if i % 2 == 0 {
                        tris.append(idx[i]); tris.append(idx[i + 1]); tris.append(idx[i + 2])
                    } else {
                        tris.append(idx[i + 1]); tris.append(idx[i]); tris.append(idx[i + 2])
                    }
                }
            }
        case 6:
            if idx.count >= 3 {
                tris.reserveCapacity((idx.count - 2) * 3)
                for i in 1..<(idx.count - 1) {
                    tris.append(idx[0]); tris.append(idx[i]); tris.append(idx[i + 1])
                }
            }
        default:
            return nil
        }
        // drop triangles that reference missing vertices
        var clean: Bool = true
        for i in tris where Int(i) >= vertexCount { clean = false; break }
        if clean { return tris }
        var out: [UInt32] = []
        out.reserveCapacity(tris.count)
        var t: Int = 0
        while t + 2 < tris.count {
            let a: UInt32 = tris[t]
            let b: UInt32 = tris[t + 1]
            let c: UInt32 = tris[t + 2]
            if Int(a) < vertexCount && Int(b) < vertexCount && Int(c) < vertexCount {
                out.append(a); out.append(b); out.append(c)
            }
            t += 3
        }
        warnOnce("primitive references vertices that do not exist (triangles dropped)")
        return out
    }

    private func buildMesh(index: Int, wantsSkin: Bool) throws -> GLBMeshTemplate? {
        let meshes: [GLBSchema.Mesh] = binary.root.meshes ?? []
        if index < 0 || index >= meshes.count { return nil }
        let mesh: GLBSchema.Mesh = meshes[index]

        var wantsUV1: Bool = false
        for p in mesh.primitives where p.attributes["TEXCOORD_1"] != nil {
            if materialUsesSecondUV(p.material ?? -1) { wantsUV1 = true }
        }

        // Pass 1: read every triangle primitive, sharing vertex arrays between primitives that use the same accessors
        struct Pending {
            var vertices: Int
            var base: Int
            var indices: [UInt32]
            var material: SCNMaterial
        }
        var pending: [Pending] = []
        var pool: [GLBPrimitiveVertices] = []            // one entry per distinct vertex set
        var poolBase: [Int] = []
        var poolKeys: [String: Int] = [:]
        var totalVertices: Int = 0
        var anyUV0: Bool = false
        var anyUV1: Bool = false
        var anyColor: Bool = false
        var anyTangent: Bool = false
        var anySkin: Bool = false

        for prim in mesh.primitives {
            guard let posAcc = prim.attributes["POSITION"] else { continue }
            let vcount: Int = try binary.accessorCount(posAcc)
            guard let tris = try triangleIndices(prim, vertexCount: vcount), !tris.isEmpty else { continue }
            var key: String = ""
            for name in prim.attributes.keys.sorted() {
                key += "\(name)=\(prim.attributes[name] ?? -1);"
            }
            var slot: Int
            if let existing = poolKeys[key] {
                slot = existing
            } else {
                guard let verts = try readPrimitive(prim, indices: tris, wantsSkin: wantsSkin, wantsUV1: wantsUV1) else { continue }
                slot = pool.count
                pool.append(verts)
                poolBase.append(totalVertices)
                totalVertices += verts.vertexCount
                poolKeys[key] = slot
                if verts.uv0 != nil { anyUV0 = true }
                if verts.uv1 != nil { anyUV1 = true }
                if verts.colors != nil { anyColor = true }
                if verts.tangents != nil { anyTangent = true }
                if verts.joints != nil { anySkin = true }
            }
            pending.append(Pending(vertices: pool[slot].vertexCount, base: poolBase[slot], indices: tris, material: material(at: prim.material)))
        }
        if pending.isEmpty { return nil }

        // Pass 2: concatenate the vertex sets (padding attributes that some primitives lack)
        var positions: [Float] = []
        var normals: [Float] = []
        var uv0: [Float] = []
        var uv1: [Float] = []
        var colors: [Float] = []
        var tangents: [Float] = []
        var joints: [UInt16] = []
        var weights: [Float] = []
        positions.reserveCapacity(totalVertices * 3)
        normals.reserveCapacity(totalVertices * 3)
        for v in pool {
            let n: Int = v.vertexCount
            positions.append(contentsOf: v.positions)
            normals.append(contentsOf: v.normals)
            if anyUV0 { uv0.append(contentsOf: v.uv0 ?? [Float](repeating: 0, count: n * 2)) }
            if anyUV1 { uv1.append(contentsOf: v.uv1 ?? [Float](repeating: 0, count: n * 2)) }
            if anyColor { colors.append(contentsOf: v.colors ?? [Float](repeating: 1, count: n * 4)) }
            if anyTangent {
                if let t = v.tangents {
                    tangents.append(contentsOf: t)
                } else {
                    for _ in 0..<n { tangents.append(1); tangents.append(0); tangents.append(0); tangents.append(1) }
                }
            }
            if anySkin {
                if let j = v.joints, let w = v.weights {
                    joints.append(contentsOf: j)
                    weights.append(contentsOf: w)
                } else {
                    for _ in 0..<n {
                        joints.append(0); joints.append(0); joints.append(0); joints.append(0)
                        weights.append(1); weights.append(0); weights.append(0); weights.append(0)
                    }
                }
            }
        }

        var sources: [SCNGeometrySource] = []
        sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.vertex, positions, components: 3))
        sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.normal, normals, components: 3))
        if anyUV0 || anyUV1 {
            let zero: [Float] = [Float](repeating: 0, count: totalVertices * 2)
            sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.texcoord, anyUV0 ? uv0 : zero, components: 2))
            if anyUV1 { sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.texcoord, uv1, components: 2)) }
        }
        if anyColor { sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.color, colors, components: 4)) }
        if anyTangent { sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.tangent, tangents, components: 4)) }

        let wide: Bool = totalVertices > 65535
        var elements: [SCNGeometryElement] = []
        var mats: [SCNMaterial] = []
        var triangleCount: Int = 0
        for p in pending {
            var idx: [UInt32] = p.indices
            if p.base != 0 {
                let b: UInt32 = UInt32(p.base)
                for i in 0..<idx.count { idx[i] += b }
            }
            let count: Int = idx.count / 3
            triangleCount += count
            let data: Data = GLBGeometryMath.indexData(idx, wide: wide)
            elements.append(SCNGeometryElement(data: data, primitiveType: SCNGeometryPrimitiveType.triangles, primitiveCount: count,
                                               bytesPerIndex: wide ? 4 : 2))
            mats.append(p.material)
        }
        let geometry: SCNGeometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = mats
        geometry.name = mesh.name

        var boneWeights: SCNGeometrySource? = nil
        var boneIndices: SCNGeometrySource? = nil
        if wantsSkin && anySkin {
            let jData: Data = joints.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<UInt16>) -> Data in
                return Data(buffer: buf)
            }
            boneIndices = SCNGeometrySource(data: jData, semantic: SCNGeometrySource.Semantic.boneIndices, vectorCount: totalVertices,
                                            usesFloatComponents: false, componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
            boneWeights = GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.boneWeights, weights, components: 4)
        } else if wantsSkin {
            warnOnce("mesh '\(mesh.name ?? "?")' is used with a skin but has no JOINTS_0 / WEIGHTS_0")
        }
        return GLBMeshTemplate(geometry: geometry, boneWeights: boneWeights, boneIndices: boneIndices, triangleCount: triangleCount)
    }
}
