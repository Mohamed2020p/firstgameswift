import Foundation
import SceneKit
import simd

// MARK: - Own mesh helpers (CPU side merging of static geometry; SceneKit has no instancing)

/// Local -> world transform: rotation about Y by `heading` (node.simdEulerAngles.y convention), uniform scale, translation.
struct WXform {
    var tx: Float = 0
    var ty: Float = 0
    var tz: Float = 0
    var c: Float = 1
    var s: Float = 0
    var scale: Float = 1

    init() {}

    init(x: Float, y: Float, z: Float, heading: Float, scale: Float) {
        tx = x
        ty = y
        tz = z
        c = cosf(heading)
        s = sinf(heading)
        self.scale = scale
    }

    static let identity = WXform()

    @inline(__always) func p(_ v: Vec3) -> Vec3 {
        let x: Float = tx + (v.x * c + v.z * s) * scale
        let y: Float = ty + v.y * scale
        let z: Float = tz + (-v.x * s + v.z * c) * scale
        return Vec3(x, y, z)
    }

    @inline(__always) func n(_ v: Vec3) -> Vec3 {
        let x: Float = v.x * c + v.z * s
        let z: Float = -v.x * s + v.z * c
        return Vec3(x, v.y, z)
    }
}

final class WMesh {
    var pos: [Float] = []
    var nrm: [Float] = []
    var uv: [Float] = []
    var idx: [UInt32] = []

    var vertexCount: Int { return pos.count / 3 }
    var triangleCount: Int { return idx.count / 3 }
    var isEmpty: Bool { return idx.isEmpty }

    @discardableResult
    func vertex(_ p: Vec3, _ n: Vec3, _ u: Float, _ v: Float) -> UInt32 {
        let i = UInt32(pos.count / 3)
        pos.append(p.x); pos.append(p.y); pos.append(p.z)
        nrm.append(n.x); nrm.append(n.y); nrm.append(n.z)
        uv.append(u); uv.append(v)
        return i
    }

    func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        idx.append(a); idx.append(b); idx.append(c)
    }

    /// Quad p0(u0,v0) p1(u1,v0) p2(u1,v1) p3(u0,v1). The winding is fixed automatically so the face looks toward `n`.
    func quad(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ n: Vec3, _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float) {
        let a = vertex(p0, n, u0, v0)
        let b = vertex(p1, n, u1, v0)
        let c = vertex(p2, n, u1, v1)
        let d = vertex(p3, n, u0, v1)
        let cr = simd_cross(p1 - p0, p2 - p0)
        if simd_dot(cr, n) >= 0 {
            tri(a, b, c); tri(a, c, d)
        } else {
            tri(a, c, b); tri(a, d, c)
        }
    }

    /// Flat colour quad (all corners sample the same atlas point).
    func flatQuad(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ n: Vec3, _ u: Float, _ v: Float) {
        quad(p0, p1, p2, p3, n, u, v, u, v)
    }

    /// Horizontal quad in the XZ plane at height y, normal up. World planar UVs: (x, z) / tile.
    func groundQuad(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2, y: Float, tile: Float) {
        let n = Vec3(0, 1, 0)
        let p0 = Vec3(a.x, y, a.y)
        let p1 = Vec3(b.x, y, b.y)
        let p2 = Vec3(c.x, y, c.y)
        let p3 = Vec3(d.x, y, d.y)
        let i0 = vertex(p0, n, a.x / tile, a.y / tile)
        let i1 = vertex(p1, n, b.x / tile, b.y / tile)
        let i2 = vertex(p2, n, c.x / tile, c.y / tile)
        let i3 = vertex(p3, n, d.x / tile, d.y / tile)
        let cr = simd_cross(p1 - p0, p2 - p0)
        if cr.y >= 0 {
            tri(i0, i1, i2); tri(i0, i2, i3)
        } else {
            tri(i0, i2, i1); tri(i0, i3, i2)
        }
    }

    /// Axis aligned rectangle on the ground with planar uv.
    func groundRect(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float, y: Float, tile: Float) {
        groundQuad(Vec2(x0, z0), Vec2(x1, z0), Vec2(x1, z1), Vec2(x0, z1), y: y, tile: tile)
    }

    /// Box with all faces sampling the atlas point (u,v). Optional rotation/translation.
    func box(center: Vec3, size: Vec3, u: Float, v: Float, xf: WXform = WXform.identity) {
        let h = size * 0.5
        let mn = center - h
        let mx = center + h
        let p000 = xf.p(Vec3(mn.x, mn.y, mn.z))
        let p100 = xf.p(Vec3(mx.x, mn.y, mn.z))
        let p010 = xf.p(Vec3(mn.x, mx.y, mn.z))
        let p110 = xf.p(Vec3(mx.x, mx.y, mn.z))
        let p001 = xf.p(Vec3(mn.x, mn.y, mx.z))
        let p101 = xf.p(Vec3(mx.x, mn.y, mx.z))
        let p011 = xf.p(Vec3(mn.x, mx.y, mx.z))
        let p111 = xf.p(Vec3(mx.x, mx.y, mx.z))
        flatQuad(p000, p100, p110, p010, xf.n(Vec3(0, 0, -1)), u, v)
        flatQuad(p101, p001, p011, p111, xf.n(Vec3(0, 0, 1)), u, v)
        flatQuad(p001, p000, p010, p011, xf.n(Vec3(-1, 0, 0)), u, v)
        flatQuad(p100, p101, p111, p110, xf.n(Vec3(1, 0, 0)), u, v)
        flatQuad(p010, p110, p111, p011, xf.n(Vec3(0, 1, 0)), u, v)
        flatQuad(p000, p001, p101, p100, xf.n(Vec3(0, -1, 0)), u, v)
    }

    /// Vertical (optionally tapered) cylinder or cone. base is the centre of the bottom disc.
    func cylinder(base: Vec3, radiusBottom: Float, radiusTop: Float, height: Float, segments: Int, u: Float, v: Float, capTop: Bool, xf: WXform = WXform.identity) {
        let seg = max(3, segments)
        let slope: Float = (radiusBottom - radiusTop) / max(height, 0.001)
        var ring0: [UInt32] = []
        var ring1: [UInt32] = []
        for i in 0...seg {
            let a: Float = Float(i) / Float(seg) * Float.tau
            let cx = cosf(a)
            let sz = sinf(a)
            let nl = Vec3(cx, slope, sz).normalizedSafe
            let pb = xf.p(Vec3(base.x + cx * radiusBottom, base.y, base.z + sz * radiusBottom))
            let pt = xf.p(Vec3(base.x + cx * radiusTop, base.y + height, base.z + sz * radiusTop))
            let n = xf.n(nl)
            ring0.append(vertex(pb, n, u, v))
            ring1.append(vertex(pt, n, u, v))
        }
        for i in 0..<seg {
            let a0 = ring0[i]
            let a1 = ring0[i + 1]
            let b0 = ring1[i]
            let b1 = ring1[i + 1]
            // outward facing: (a0, b0, a1) verified by orientation of increasing angle
            tri(a0, b0, a1)
            tri(a1, b0, b1)
        }
        if capTop && radiusTop > 0.001 {
            let n = xf.n(Vec3(0, 1, 0))
            let centre = vertex(xf.p(Vec3(base.x, base.y + height, base.z)), n, u, v)
            var prev: UInt32 = 0
            for i in 0...seg {
                let a: Float = Float(i) / Float(seg) * Float.tau
                let pt = xf.p(Vec3(base.x + cosf(a) * radiusTop, base.y + height, base.z + sinf(a) * radiusTop))
                let vi = vertex(pt, n, u, v)
                if i > 0 { tri(centre, vi, prev) }
                prev = vi
            }
        }
    }

    /// Low poly sphere (used for tree crowns / bushes).
    func blob(center: Vec3, radius: Vec3, rings: Int, segments: Int, u: Float, v: Float, xf: WXform = WXform.identity) {
        let rn = max(2, rings)
        let sg = max(3, segments)
        var rows: [[UInt32]] = []
        for r in 0...rn {
            let phi: Float = Float(r) / Float(rn) * Float.pi
            let y = cosf(phi)
            let rr = sinf(phi)
            var row: [UInt32] = []
            for s in 0...sg {
                let th: Float = Float(s) / Float(sg) * Float.tau
                let nx = rr * cosf(th)
                let nz = rr * sinf(th)
                let pl = Vec3(center.x + nx * radius.x, center.y + y * radius.y, center.z + nz * radius.z)
                let n = xf.n(Vec3(nx, y, nz).normalizedSafe)
                row.append(vertex(xf.p(pl), n, u, v))
            }
            rows.append(row)
        }
        for r in 0..<rn {
            for s in 0..<sg {
                let a = rows[r][s]
                let b = rows[r][s + 1]
                let c = rows[r + 1][s]
                let d = rows[r + 1][s + 1]
                // outward: rows go from top to bottom, angle increases counter clockwise seen from above
                tri(a, b, c)
                tri(b, d, c)
            }
        }
    }

    func append(_ o: WMesh, _ xf: WXform) {
        let base = UInt32(vertexCount)
        let n = o.vertexCount
        pos.reserveCapacity(pos.count + n * 3)
        nrm.reserveCapacity(nrm.count + n * 3)
        uv.reserveCapacity(uv.count + n * 2)
        var i = 0
        while i < n {
            let p = xf.p(Vec3(o.pos[i * 3], o.pos[i * 3 + 1], o.pos[i * 3 + 2]))
            let nn = xf.n(Vec3(o.nrm[i * 3], o.nrm[i * 3 + 1], o.nrm[i * 3 + 2]))
            pos.append(p.x); pos.append(p.y); pos.append(p.z)
            nrm.append(nn.x); nrm.append(nn.y); nrm.append(nn.z)
            uv.append(o.uv[i * 2]); uv.append(o.uv[i * 2 + 1])
            i += 1
        }
        idx.reserveCapacity(idx.count + o.idx.count)
        for k in o.idx { idx.append(k + base) }
    }
}

/// A set of meshes keyed by material (identity). One SCNGeometry with one element per material comes out.
final class WMeshSet {
    private(set) var materials: [SCNMaterial] = []
    private var meshes: [ObjectIdentifier: WMesh] = [:]

    var isEmpty: Bool {
        for (_, m) in meshes where !m.isEmpty { return false }
        return true
    }

    var triangleCount: Int {
        var t = 0
        for (_, m) in meshes { t += m.triangleCount }
        return t
    }

    func mesh(_ m: SCNMaterial) -> WMesh {
        let key = ObjectIdentifier(m)
        if let e = meshes[key] { return e }
        let w = WMesh()
        meshes[key] = w
        materials.append(m)
        return w
    }

    func existingMesh(_ m: SCNMaterial) -> WMesh? {
        return meshes[ObjectIdentifier(m)]
    }

    func append(_ o: WMeshSet, _ xf: WXform) {
        for m in o.materials {
            if let src = o.meshes[ObjectIdentifier(m)] {
                mesh(m).append(src, xf)
            }
        }
    }

    func makeGeometry() -> SCNGeometry? {
        var totalV = 0
        for m in materials {
            if let w = meshes[ObjectIdentifier(m)], !w.isEmpty { totalV += w.vertexCount }
        }
        if totalV == 0 { return nil }
        var pos: [Float] = []
        var nrm: [Float] = []
        var uv: [Float] = []
        pos.reserveCapacity(totalV * 3)
        nrm.reserveCapacity(totalV * 3)
        uv.reserveCapacity(totalV * 2)
        var elements: [SCNGeometryElement] = []
        var mats: [SCNMaterial] = []
        var base: UInt32 = 0
        for m in materials {
            guard let w = meshes[ObjectIdentifier(m)], !w.isEmpty else { continue }
            pos.append(contentsOf: w.pos)
            nrm.append(contentsOf: w.nrm)
            uv.append(contentsOf: w.uv)
            var shifted: [UInt32] = []
            shifted.reserveCapacity(w.idx.count)
            for i in w.idx { shifted.append(i + base) }
            let data: Data = shifted.withUnsafeBufferPointer { Data(buffer: $0) }
            let el = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: shifted.count / 3, bytesPerIndex: 4)
            elements.append(el)
            mats.append(m)
            base += UInt32(w.vertexCount)
        }
        let posData: Data = pos.withUnsafeBufferPointer { Data(buffer: $0) }
        let nrmData: Data = nrm.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvData: Data = uv.withUnsafeBufferPointer { Data(buffer: $0) }
        let vs = SCNGeometrySource(data: posData, semantic: .vertex, vectorCount: totalV, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let ns = SCNGeometrySource(data: nrmData, semantic: .normal, vectorCount: totalV, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let ts = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: totalV, usesFloatComponents: true,
                                   componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8)
        let geo = SCNGeometry(sources: [vs, ns, ts], elements: elements)
        geo.materials = mats
        return geo
    }
}

// MARK: - Extraction of a loaded GLB node hierarchy into a WMeshSet (so models can be merged per chunk without flattenedClone)

struct WExtracted {
    var set: WMeshSet
    var boundsMin: Vec3
    var boundsMax: Vec3
}

@MainActor
enum WMeshExtractor {
    private static func readFloats(_ s: SCNGeometrySource, comps: Int) -> [Float]? {
        if !s.usesFloatComponents { return nil }
        if s.bytesPerComponent != 4 { return nil }
        if s.componentsPerVector < comps { return nil }
        let n = s.vectorCount
        let stride = s.dataStride
        let off = s.dataOffset
        var out = [Float](repeating: 0, count: n * comps)
        let data = s.data
        let need = off + (n - 1) * stride + comps * 4
        if n == 0 || data.count < need { return nil }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let base = off + i * stride
                for k in 0..<comps {
                    var f: Float = 0
                    withUnsafeMutableBytes(of: &f) { dst in
                        let lo = base + k * 4
                        dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[lo..<(lo + 4)]))
                    }
                    out[i * comps + k] = f
                }
            }
        }
        return out
    }

    private static func readIndices(_ e: SCNGeometryElement) -> [UInt32]? {
        if e.primitiveType != .triangles { return nil }
        let count = e.primitiveCount * 3
        let bpi = e.bytesPerIndex
        if bpi != 1 && bpi != 2 && bpi != 4 { return nil }
        if e.data.count < count * bpi { return nil }
        var out = [UInt32](repeating: 0, count: count)
        e.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                var v: UInt32 = 0
                if bpi == 1 {
                    v = UInt32(raw[i])
                } else if bpi == 2 {
                    v = UInt32(raw[i * 2]) | (UInt32(raw[i * 2 + 1]) << 8)
                } else {
                    v = UInt32(raw[i * 4]) | (UInt32(raw[i * 4 + 1]) << 8) | (UInt32(raw[i * 4 + 2]) << 16) | (UInt32(raw[i * 4 + 3]) << 24)
                }
                out[i] = v
            }
        }
        return out
    }

    static func extract(from root: SCNNode) -> WExtracted? {
        let set = WMeshSet()
        var bmin = Vec3(1e9, 1e9, 1e9)
        var bmax = Vec3(-1e9, -1e9, -1e9)
        let rootInv = simd_inverse(root.simdWorldTransform)
        let fallbackMat = SCNMaterial()
        var failed = false
        var gotAny = false

        func visit(_ node: SCNNode) {
            if let g = node.geometry, !failed {
                let m4 = simd_mul(rootInv, node.simdWorldTransform)
                let vsrc = g.sources(for: .vertex).first
                let nsrc = g.sources(for: .normal).first
                let tsrc = g.sources(for: .texcoord).first
                if let vs = vsrc, let pos = readFloats(vs, comps: 3) {
                    let nrm: [Float]? = (nsrc != nil) ? readFloats(nsrc!, comps: 3) : nil
                    let uvs: [Float]? = (tsrc != nil) ? readFloats(tsrc!, comps: 2) : nil
                    let vc = vs.vectorCount
                    for (ei, el) in g.elements.enumerated() {
                        guard let indices = readIndices(el) else { continue }
                        var mat: SCNMaterial = fallbackMat
                        if !g.materials.isEmpty { mat = g.materials[min(ei, g.materials.count - 1)] }
                        let mesh = set.mesh(mat)
                        let base = UInt32(mesh.vertexCount)
                        // remap: copy all vertices of this geometry once per element (simple and safe)
                        for i in 0..<vc {
                            let p4 = simd_mul(m4, Vec4(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2], 1))
                            var n3 = Vec3(0, 1, 0)
                            if let nn = nrm, nn.count >= (i + 1) * 3 {
                                let n4 = simd_mul(m4, Vec4(nn[i * 3], nn[i * 3 + 1], nn[i * 3 + 2], 0))
                                n3 = Vec3(n4.x, n4.y, n4.z).normalizedSafe
                            }
                            var u: Float = 0
                            var v: Float = 0
                            if let uu = uvs, uu.count >= (i + 1) * 2 { u = uu[i * 2]; v = uu[i * 2 + 1] }
                            mesh.vertex(Vec3(p4.x, p4.y, p4.z), n3, u, v)
                            bmin = simd_min(bmin, Vec3(p4.x, p4.y, p4.z))
                            bmax = simd_max(bmax, Vec3(p4.x, p4.y, p4.z))
                        }
                        for ix in indices { mesh.idx.append(ix + base) }
                        gotAny = true
                    }
                } else {
                    failed = true
                }
            }
            for c in node.childNodes { visit(c) }
        }
        visit(root)
        if failed || !gotAny { return nil }
        return WExtracted(set: set, boundsMin: bmin, boundsMax: bmax)
    }
}
