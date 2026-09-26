import Foundation
import SceneKit
import simd

// MARK: - MeshBuilder: procedural SCNGeometry generators (roads, walls, towers, props).
//
// Conventions: Y up, metres, counter-clockwise front faces. Texture coordinates use the SceneKit convention (v = 0 at the BOTTOM of a UIImage,
// i.e. an image drawn with ProceduralTextures appears upright on a wall whose v grows upwards). Whenever a generator takes `tileMeters`
// the UVs are in WORLD SCALE: one texture repeat covers `tileMeters` metres (use wrapS/wrapT = .repeat on the material). With tileMeters = 0
// every face simply maps 0...1.

/// Growable vertex/index buffers with helpers that orient triangles to face a given normal (no winding mistakes possible).
struct MeshBuffers {
    var positions: [Vec3] = []
    var normals: [Vec3] = []
    var uvs: [Vec2] = []
    var indices: [UInt32] = []

    var vertexCount: Int { return positions.count }
    var triangleCount: Int { return indices.count / 3 }

    @discardableResult
    mutating func addVertex(_ p: Vec3, normal n: Vec3, uv: Vec2) -> UInt32 {
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    /// triangle whose front face looks along `facing` (indices are swapped when necessary)
    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, facing: Vec3) {
        let pa: Vec3 = positions[Int(a)]
        let pb: Vec3 = positions[Int(b)]
        let pc: Vec3 = positions[Int(c)]
        let n: Vec3 = simd_cross(pb - pa, pc - pa)
        if simd_dot(n, facing) >= 0 {
            indices.append(a); indices.append(b); indices.append(c)
        } else {
            indices.append(a); indices.append(c); indices.append(b)
        }
    }

    /// planar quad p0 p1 p2 p3 (in loop order) with one normal; uv0...uv3 per corner
    mutating func addQuad(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, normal: Vec3, uv0: Vec2, uv1: Vec2, uv2: Vec2, uv3: Vec2) {
        let i0: UInt32 = addVertex(p0, normal: normal, uv: uv0)
        let i1: UInt32 = addVertex(p1, normal: normal, uv: uv1)
        let i2: UInt32 = addVertex(p2, normal: normal, uv: uv2)
        let i3: UInt32 = addVertex(p3, normal: normal, uv: uv3)
        addTriangle(i0, i1, i2, facing: normal)
        addTriangle(i0, i2, i3, facing: normal)
    }

    func geometry() -> SCNGeometry {
        return MeshBuilder.makeGeometry(positions: positions, normals: normals, uvs: uvs, indices: indices)
    }
}

enum MeshBuilder {
    enum Pivot {
        case center
        case bottom
    }

    // MARK: raw arrays -> SCNGeometry

    private static func pack3(_ a: [Vec3]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(a.count * 3)
        for v in a {
            out.append(v.x); out.append(v.y); out.append(v.z)
        }
        return out
    }

    private static func pack2(_ a: [Vec2]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(a.count * 2)
        for v in a {
            out.append(v.x); out.append(v.y)
        }
        return out
    }

    /// Geometry with one triangle element per index list. `normals` may be empty (smooth normals are generated), `uvs` may be empty (no texcoords).
    static func makeGeometry(positions: [Vec3], normals: [Vec3], uvs: [Vec2], elements: [[UInt32]]) -> SCNGeometry {
        let flatPositions: [Float] = pack3(positions)
        var sources: [SCNGeometrySource] = []
        sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.vertex, flatPositions, components: 3))
        if normals.count == positions.count {
            sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.normal, pack3(normals), components: 3))
        } else {
            var all: [UInt32] = []
            for e in elements { all.append(contentsOf: e) }
            let generated: [Float] = GLBGeometryMath.smoothNormals(positions: flatPositions, indices: all)
            sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.normal, generated, components: 3))
        }
        if uvs.count == positions.count {
            sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.texcoord, pack2(uvs), components: 2))
        }
        let wide: Bool = positions.count > 65535
        var els: [SCNGeometryElement] = []
        for e in elements {
            let data: Data = GLBGeometryMath.indexData(e, wide: wide)
            els.append(SCNGeometryElement(data: data, primitiveType: SCNGeometryPrimitiveType.triangles, primitiveCount: e.count / 3,
                                          bytesPerIndex: wide ? 4 : 2))
        }
        return SCNGeometry(sources: sources, elements: els)
    }

    static func makeGeometry(positions: [Vec3], normals: [Vec3], uvs: [Vec2], indices: [UInt32]) -> SCNGeometry {
        return makeGeometry(positions: positions, normals: normals, uvs: uvs, elements: [indices])
    }

    // MARK: box

    /// Axis aligned box `size` = (width x, height y, depth z). `pivot` .bottom puts the origin at the centre of the bottom face.
    static func box(size: Vec3, pivot: Pivot = .center, tileMeters: Float = 0) -> SCNGeometry {
        let hx: Float = size.x * 0.5
        let hy: Float = size.y * 0.5
        let hz: Float = size.z * 0.5
        let oy: Float = pivot == .bottom ? hy : 0
        var b: MeshBuffers = MeshBuffers()

        func face(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ n: Vec3, _ uExt: Float, _ vExt: Float) {
            var us: Float = 1
            var vs: Float = 1
            if tileMeters > 0 {
                us = uExt / tileMeters
                vs = vExt / tileMeters
            }
            let o: Vec3 = Vec3(0, oy, 0)
            b.addQuad(p0 + o, p1 + o, p2 + o, p3 + o, normal: n, uv0: Vec2(0, 0), uv1: Vec2(us, 0), uv2: Vec2(us, vs), uv3: Vec2(0, vs))
        }
        face(Vec3(-hx, -hy, hz), Vec3(hx, -hy, hz), Vec3(hx, hy, hz), Vec3(-hx, hy, hz), Vec3(0, 0, 1), size.x, size.y)
        face(Vec3(hx, -hy, -hz), Vec3(-hx, -hy, -hz), Vec3(-hx, hy, -hz), Vec3(hx, hy, -hz), Vec3(0, 0, -1), size.x, size.y)
        face(Vec3(hx, -hy, hz), Vec3(hx, -hy, -hz), Vec3(hx, hy, -hz), Vec3(hx, hy, hz), Vec3(1, 0, 0), size.z, size.y)
        face(Vec3(-hx, -hy, -hz), Vec3(-hx, -hy, hz), Vec3(-hx, hy, hz), Vec3(-hx, hy, -hz), Vec3(-1, 0, 0), size.z, size.y)
        face(Vec3(-hx, hy, hz), Vec3(hx, hy, hz), Vec3(hx, hy, -hz), Vec3(-hx, hy, -hz), Vec3(0, 1, 0), size.x, size.z)
        face(Vec3(-hx, -hy, -hz), Vec3(hx, -hy, -hz), Vec3(hx, -hy, hz), Vec3(-hx, -hy, hz), Vec3(0, -1, 0), size.x, size.z)
        return b.geometry()
    }

    // MARK: plane / grid

    /// Horizontal grid facing +Y, centred on the origin at height `y`. UV is world scaled when tileMeters > 0 (u along x, v along -z so an upright
    /// image reads correctly when seen from above with +z towards the viewer).
    static func grid(width: Float, depth: Float, segmentsX: Int = 1, segmentsZ: Int = 1, y: Float = 0, tileMeters: Float = 0) -> SCNGeometry {
        let sx: Int = max(1, segmentsX)
        let sz: Int = max(1, segmentsZ)
        var b: MeshBuffers = MeshBuffers()
        let normal: Vec3 = Vec3(0, 1, 0)
        for iz in 0...sz {
            let fz: Float = Float(iz) / Float(sz)
            for ix in 0...sx {
                let fx: Float = Float(ix) / Float(sx)
                let p: Vec3 = Vec3((fx - 0.5) * width, y, (0.5 - fz) * depth)
                var uv: Vec2 = Vec2(fx, fz)
                if tileMeters > 0 { uv = Vec2(fx * width / tileMeters, fz * depth / tileMeters) }
                b.addVertex(p, normal: normal, uv: uv)
            }
        }
        for iz in 0..<sz {
            for ix in 0..<sx {
                let i0: UInt32 = UInt32(iz * (sx + 1) + ix)
                let i1: UInt32 = i0 + 1
                let i2: UInt32 = i0 + UInt32(sx + 1)
                let i3: UInt32 = i2 + 1
                b.addTriangle(i0, i1, i3, facing: normal)
                b.addTriangle(i0, i3, i2, facing: normal)
            }
        }
        return b.geometry()
    }

    static func plane(width: Float, depth: Float, y: Float = 0, tileMeters: Float = 0) -> SCNGeometry {
        return grid(width: width, depth: depth, segmentsX: 1, segmentsZ: 1, y: y, tileMeters: tileMeters)
    }

    // MARK: cylinder

    /// Upright cylinder with the origin at the centre of its bottom face. Side u = arc length / tileMeters, v = height / tileMeters.
    static func cylinder(radius: Float, height: Float, segments: Int = 16, caps: Bool = true, tileMeters: Float = 0, pivot: Pivot = .bottom) -> SCNGeometry {
        let seg: Int = max(3, segments)
        let y0: Float = pivot == .bottom ? 0 : -height * 0.5
        let y1: Float = y0 + height
        var b: MeshBuffers = MeshBuffers()
        let circumference: Float = Float.tau * radius
        for i in 0...seg {
            let f: Float = Float(i) / Float(seg)
            let a: Float = f * Float.tau
            let c: Float = cosf(a)
            let s: Float = sinf(a)
            let n: Vec3 = Vec3(c, 0, s)
            var u: Float = f
            var vTop: Float = 1
            if tileMeters > 0 {
                u = f * circumference / tileMeters
                vTop = height / tileMeters
            }
            b.addVertex(Vec3(c * radius, y0, s * radius), normal: n, uv: Vec2(u, 0))
            b.addVertex(Vec3(c * radius, y1, s * radius), normal: n, uv: Vec2(u, vTop))
        }
        for i in 0..<seg {
            let a0: UInt32 = UInt32(i * 2)
            let a1: UInt32 = a0 + 1
            let b0: UInt32 = a0 + 2
            let b1: UInt32 = a0 + 3
            let mid: Float = (Float(i) + 0.5) / Float(seg) * Float.tau
            let facing: Vec3 = Vec3(cosf(mid), 0, sinf(mid))
            b.addTriangle(a0, b0, b1, facing: facing)
            b.addTriangle(a0, b1, a1, facing: facing)
        }
        if caps {
            for (y, ny) in [(y1, Float(1)), (y0, Float(-1))] {
                let n: Vec3 = Vec3(0, ny, 0)
                let centre: UInt32 = b.addVertex(Vec3(0, y, 0), normal: n, uv: Vec2(0.5, 0.5))
                var ring: [UInt32] = []
                for i in 0..<seg {
                    let a: Float = Float(i) / Float(seg) * Float.tau
                    let c: Float = cosf(a)
                    let s: Float = sinf(a)
                    var uv: Vec2 = Vec2(0.5 + 0.5 * c, 0.5 + 0.5 * s)
                    if tileMeters > 0 { uv = Vec2(c * radius / tileMeters, s * radius / tileMeters) }
                    ring.append(b.addVertex(Vec3(c * radius, y, s * radius), normal: n, uv: uv))
                }
                for i in 0..<seg {
                    b.addTriangle(centre, ring[i], ring[(i + 1) % seg], facing: n)
                }
            }
        }
        return b.geometry()
    }

    // MARK: strips (roads, sidewalks, ribbons)

    /// Strip between two polylines of equal length. u runs from 0 (left polyline) to `acrossTiling` (right polyline); v = distance along the
    /// strip / alongMeters. Every vertex normal is `up`.
    static func quadStrip(left: [Vec3], right: [Vec3], up: Vec3 = Vec3(0, 1, 0), acrossTiling: Float = 1, alongMeters: Float = 1) -> SCNGeometry {
        var b: MeshBuffers = MeshBuffers()
        let n: Int = min(left.count, right.count)
        if n < 2 { return b.geometry() }
        var dist: Float = 0
        for i in 0..<n {
            if i > 0 {
                let mid0: Vec3 = (left[i - 1] + right[i - 1]) * 0.5
                let mid1: Vec3 = (left[i] + right[i]) * 0.5
                dist += simd_length(mid1 - mid0)
            }
            let v: Float = alongMeters > 0 ? dist / alongMeters : dist
            b.addVertex(left[i], normal: up, uv: Vec2(0, v))
            b.addVertex(right[i], normal: up, uv: Vec2(acrossTiling, v))
        }
        for i in 0..<(n - 1) {
            let l0: UInt32 = UInt32(i * 2)
            let r0: UInt32 = l0 + 1
            let l1: UInt32 = l0 + 2
            let r1: UInt32 = l0 + 3
            b.addTriangle(l0, r0, r1, facing: up)
            b.addTriangle(l0, r1, l1, facing: up)
        }
        return b.geometry()
    }

    /// Ribbon of constant `width` along a centre line (mitred joints). "Left" is cross(up, direction) = the heading-left of Core/Math.swift.
    static func ribbon(centerline: [Vec3], width: Float, up: Vec3 = Vec3(0, 1, 0), acrossTiling: Float = 1, alongMeters: Float = 1, closed: Bool = false) -> SCNGeometry {
        let count: Int = centerline.count
        if count < 2 { return MeshBuffers().geometry() }
        var pts: [Vec3] = centerline
        if closed, let first = centerline.first { pts.append(first) }
        let n: Int = pts.count
        var left: [Vec3] = []
        var right: [Vec3] = []
        let half: Float = width * 0.5
        for i in 0..<n {
            var dirA: Vec3 = Vec3(0, 0, 0)
            var dirB: Vec3 = Vec3(0, 0, 0)
            if i > 0 { dirA = (pts[i] - pts[i - 1]).normalizedSafe }
            if i < n - 1 { dirB = (pts[i + 1] - pts[i]).normalizedSafe }
            var dir: Vec3 = dirA + dirB
            if closed && (i == 0 || i == n - 1) {
                let a: Vec3 = (pts[n - 1] - pts[n - 2]).normalizedSafe
                let bdir: Vec3 = (pts[1] - pts[0]).normalizedSafe
                dir = a + bdir
            }
            dir = dir.normalizedSafe
            if simd_length(dir) < 0.5 { dir = (dirA + dirB).normalizedSafe }
            if simd_length(dir) < 0.5 { dir = Vec3(0, 0, 1) }
            let side: Vec3 = simd_cross(up, dir).normalizedSafe
            let ref: Vec3 = simd_length(dirB) > 0 ? dirB : dirA
            let refSide: Vec3 = simd_cross(up, ref).normalizedSafe
            let cosHalf: Float = max(0.5, simd_dot(side, refSide))
            let offset: Vec3 = side * (half / cosHalf)
            left.append(pts[i] + offset)
            right.append(pts[i] - offset)
        }
        return quadStrip(left: left, right: right, up: up, acrossTiling: acrossTiling, alongMeters: alongMeters)
    }

    // MARK: extruded polygon

    static func polygonArea(_ pts: [Vec2]) -> Float {
        var a: Float = 0
        let n: Int = pts.count
        for i in 0..<n {
            let p: Vec2 = pts[i]
            let q: Vec2 = pts[(i + 1) % n]
            a += p.x * q.y - q.x * p.y
        }
        return a * 0.5
    }

    /// Ear clipping triangulation of a simple polygon (x, z). Returns indices into `pts` (any winding is accepted).
    static func triangulate(_ pts: [Vec2]) -> [UInt32] {
        let n: Int = pts.count
        if n < 3 { return [] }
        var order: [Int] = Array(0..<n)
        if polygonArea(pts) < 0 { order.reverse() }
        var out: [UInt32] = []
        out.reserveCapacity((n - 2) * 3)

        func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Float {
            return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func inside(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
            let d1: Float = orient(a, b, p)
            let d2: Float = orient(b, c, p)
            let d3: Float = orient(c, a, p)
            return d1 >= 0 && d2 >= 0 && d3 >= 0
        }

        var guardCount: Int = 0
        while order.count > 3 && guardCount < n * n {
            guardCount += 1
            var clipped: Bool = false
            let m: Int = order.count
            for i in 0..<m {
                let ia: Int = order[(i + m - 1) % m]
                let ib: Int = order[i]
                let ic: Int = order[(i + 1) % m]
                let a: Vec2 = pts[ia]
                let b: Vec2 = pts[ib]
                let c: Vec2 = pts[ic]
                if orient(a, b, c) <= 1e-9 { continue }
                var ear: Bool = true
                for k in 0..<m {
                    let ik: Int = order[k]
                    if ik == ia || ik == ib || ik == ic { continue }
                    if inside(pts[ik], a, b, c) { ear = false; break }
                }
                if !ear { continue }
                out.append(UInt32(ia)); out.append(UInt32(ib)); out.append(UInt32(ic))
                order.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if order.count == 3 {
            out.append(UInt32(order[0])); out.append(UInt32(order[1])); out.append(UInt32(order[2]))
        } else if order.count > 3 {
            for i in 1..<(order.count - 1) {
                out.append(UInt32(order[0])); out.append(UInt32(order[i])); out.append(UInt32(order[i + 1]))
            }
        }
        return out
    }

    /// Prism over a footprint given as (x, z) points (any winding). Elements: [0] = walls, [1] = roof cap (only when `roof`).
    /// Assign `geometry.materials = [wallMaterial, roofMaterial]`. Wall UV: u = metres along the wall / tileMeters, v = height above baseY / tileMeters.
    static func extrudedPolygon(footprint: [Vec2], height: Float, baseY: Float = 0, tileMeters: Float = 0, roof: Bool = true, roofTileMeters: Float = 0) -> SCNGeometry {
        var pts: [Vec2] = footprint
        if pts.count >= 2, let f = pts.first, let l = pts.last, simd_length(f - l) < 1e-5 { pts.removeLast() }
        if polygonArea(pts) < 0 { pts.reverse() }
        var b: MeshBuffers = MeshBuffers()
        let n: Int = pts.count
        if n < 3 { return b.geometry() }
        var wallIndices: [UInt32] = []
        let y0: Float = baseY
        let y1: Float = baseY + height
        var run: Float = 0
        for i in 0..<n {
            let p: Vec2 = pts[i]
            let q: Vec2 = pts[(i + 1) % n]
            let d: Vec2 = q - p
            let len: Float = simd_length(d)
            if len < 1e-6 { continue }
            let normal: Vec3 = Vec3(d.y / len, 0, -d.x / len)
            var u0: Float = run
            var u1: Float = run + len
            var vTop: Float = height
            if tileMeters > 0 {
                u0 /= tileMeters
                u1 /= tileMeters
                vTop = height / tileMeters
            } else {
                u0 = 0
                u1 = 1
                vTop = 1
            }
            run += len
            let a0: UInt32 = b.addVertex(Vec3(p.x, y0, p.y), normal: normal, uv: Vec2(u0, 0))
            let a1: UInt32 = b.addVertex(Vec3(q.x, y0, q.y), normal: normal, uv: Vec2(u1, 0))
            let a2: UInt32 = b.addVertex(Vec3(q.x, y1, q.y), normal: normal, uv: Vec2(u1, vTop))
            let a3: UInt32 = b.addVertex(Vec3(p.x, y1, p.y), normal: normal, uv: Vec2(u0, vTop))
            let before: Int = b.indices.count
            b.addTriangle(a0, a1, a2, facing: normal)
            b.addTriangle(a0, a2, a3, facing: normal)
            wallIndices.append(contentsOf: b.indices[before...])
            b.indices.removeSubrange(before...)
        }
        var elements: [[UInt32]] = [wallIndices]
        if roof {
            let up: Vec3 = Vec3(0, 1, 0)
            var ringBase: [UInt32] = []
            for p in pts {
                var uv: Vec2 = Vec2(p.x, p.y)
                if roofTileMeters > 0 { uv = Vec2(p.x / roofTileMeters, p.y / roofTileMeters) }
                ringBase.append(b.addVertex(Vec3(p.x, y1, p.y), normal: up, uv: uv))
            }
            let tris: [UInt32] = triangulate(pts)
            var roofIndices: [UInt32] = []
            var t: Int = 0
            while t + 2 < tris.count {
                let a: UInt32 = ringBase[Int(tris[t])]
                let bb: UInt32 = ringBase[Int(tris[t + 1])]
                let c: UInt32 = ringBase[Int(tris[t + 2])]
                let before: Int = b.indices.count
                b.addTriangle(a, bb, c, facing: up)
                roofIndices.append(contentsOf: b.indices[before...])
                b.indices.removeSubrange(before...)
                t += 3
            }
            elements.append(roofIndices)
        }
        return makeGeometry(positions: b.positions, normals: b.normals, uvs: b.uvs, elements: elements)
    }

    // MARK: merging

    /// Float components of a geometry source (nil when it is not tightly readable float data).
    static func readFloats(_ s: SCNGeometrySource) -> [Float]? {
        if !s.usesFloatComponents || s.bytesPerComponent != 4 { return nil }
        let comps: Int = s.componentsPerVector
        let n: Int = s.vectorCount
        if n == 0 || comps == 0 { return [] }
        let needed: Int = s.dataOffset + (n - 1) * s.dataStride + comps * 4
        if needed > s.data.count { return nil }
        var out: [Float] = [Float](repeating: 0, count: n * comps)
        s.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            for i in 0..<n {
                for c in 0..<comps {
                    var f: Float = 0
                    memcpy(&f, base + s.dataOffset + i * s.dataStride + c * 4, 4)
                    out[i * comps + c] = f
                }
            }
        }
        return out
    }

    /// Triangle indices of an element (nil for non-triangle primitives).
    static func readIndices(_ e: SCNGeometryElement) -> [UInt32]? {
        if e.primitiveType != SCNGeometryPrimitiveType.triangles { return nil }
        let count: Int = e.primitiveCount * 3
        let bpi: Int = e.bytesPerIndex
        if bpi != 1 && bpi != 2 && bpi != 4 { return nil }
        if count * bpi > e.data.count { return nil }
        var out: [UInt32] = [UInt32](repeating: 0, count: count)
        e.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                if bpi == 1 {
                    out[i] = UInt32(base.load(fromByteOffset: i, as: UInt8.self))
                } else if bpi == 2 {
                    var v: UInt16 = 0
                    memcpy(&v, base + i * 2, 2)
                    out[i] = UInt32(v)
                } else {
                    var v: UInt32 = 0
                    memcpy(&v, base + i * 4, 4)
                    out[i] = v
                }
            }
        }
        return out
    }

    private static func transformPoint(_ m: simd_float4x4, _ p: Vec3) -> Vec3 {
        let r: SIMD4<Float> = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return Vec3(r.x, r.y, r.z)
    }

    /// Merges placed geometries into one (positions transformed, normals via the inverse transpose, elements grouped per material object).
    /// Only triangle elements and float vertex/normal/first-texcoord sources are merged. Returns nil when nothing could be merged.
    static func mergedGeometry(_ items: [(geometry: SCNGeometry, transform: simd_float4x4)]) -> SCNGeometry? {
        var positions: [Float] = []
        var normals: [Float] = []
        var uvs: [Float] = []
        var anyUV: Bool = false
        var groupOrder: [ObjectIdentifier] = []
        var groupMaterial: [ObjectIdentifier: SCNMaterial] = [:]
        var groupIndices: [ObjectIdentifier: [UInt32]] = [:]
        var vertexBase: Int = 0

        for item in items {
            let g: SCNGeometry = item.geometry
            guard let vs = g.sources(for: SCNGeometrySource.Semantic.vertex).first, let pos = readFloats(vs), vs.componentsPerVector >= 3 else { continue }
            let count: Int = vs.vectorCount
            let pc: Int = vs.componentsPerVector
            let m: simd_float4x4 = item.transform
            let m3: simd_float3x3 = simd_float3x3(columns: (Vec3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                                             Vec3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                                             Vec3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
            let det: Float = simd_determinant(m3)
            let normalMatrix: simd_float3x3 = abs(det) > 1e-12 ? simd_transpose(simd_inverse(m3)) : m3

            var nrm: [Float]? = nil
            if let ns = g.sources(for: SCNGeometrySource.Semantic.normal).first, ns.componentsPerVector >= 3, ns.vectorCount == count {
                nrm = readFloats(ns)
            }
            var tex: [Float]? = nil
            var tc: Int = 2
            if let ts = g.sources(for: SCNGeometrySource.Semantic.texcoord).first, ts.vectorCount == count {
                tex = readFloats(ts)
                tc = ts.componentsPerVector
            }
            // element index lists (validated) before touching the output arrays
            var lists: [(SCNMaterial?, [UInt32])] = []
            for (ei, e) in g.elements.enumerated() {
                guard let idx = readIndices(e) else { continue }
                var mat: SCNMaterial? = nil
                if !g.materials.isEmpty { mat = g.materials[min(ei, g.materials.count - 1)] }
                lists.append((mat, idx))
            }
            if lists.isEmpty { continue }

            var flatForNormals: [UInt32] = []
            for l in lists { flatForNormals.append(contentsOf: l.1) }
            var srcNormals: [Float] = []
            var nComps: Int = 3
            if let nn = nrm, let ns = g.sources(for: SCNGeometrySource.Semantic.normal).first, nn.count >= count * ns.componentsPerVector {
                srcNormals = nn
                nComps = ns.componentsPerVector
            } else {
                var flatPos: [Float] = [Float](repeating: 0, count: count * 3)
                for i in 0..<count {
                    flatPos[i * 3] = pos[i * pc]
                    flatPos[i * 3 + 1] = pos[i * pc + 1]
                    flatPos[i * 3 + 2] = pos[i * pc + 2]
                }
                srcNormals = GLBGeometryMath.smoothNormals(positions: flatPos, indices: flatForNormals)
            }

            for i in 0..<count {
                let p: Vec3 = transformPoint(m, Vec3(pos[i * pc], pos[i * pc + 1], pos[i * pc + 2]))
                positions.append(p.x); positions.append(p.y); positions.append(p.z)
                let nv: Vec3 = Vec3(srcNormals[i * nComps], srcNormals[i * nComps + 1], srcNormals[i * nComps + 2])
                let tn: Vec3 = (normalMatrix * nv).normalizedSafe
                normals.append(tn.x); normals.append(tn.y); normals.append(tn.z)
                if let t = tex, t.count >= (i + 1) * tc, tc >= 2 {
                    uvs.append(t[i * tc]); uvs.append(t[i * tc + 1])
                    anyUV = true
                } else {
                    uvs.append(0); uvs.append(0)
                }
            }
            for l in lists {
                let mat: SCNMaterial = l.0 ?? SCNMaterial()
                let key: ObjectIdentifier = ObjectIdentifier(mat)
                if groupMaterial[key] == nil {
                    groupMaterial[key] = mat
                    groupOrder.append(key)
                    groupIndices[key] = []
                }
                let offset: UInt32 = UInt32(vertexBase)
                var arr: [UInt32] = groupIndices[key] ?? []
                arr.reserveCapacity(arr.count + l.1.count)
                for v in l.1 { arr.append(v + offset) }
                groupIndices[key] = arr
            }
            vertexBase += count
        }
        if vertexBase == 0 || groupOrder.isEmpty { return nil }

        var sources: [SCNGeometrySource] = []
        sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.vertex, positions, components: 3))
        sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.normal, normals, components: 3))
        if anyUV { sources.append(GLBGeometryMath.floatSource(SCNGeometrySource.Semantic.texcoord, uvs, components: 2)) }
        let wide: Bool = vertexBase > 65535
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        for key in groupOrder {
            guard let idx = groupIndices[key], let mat = groupMaterial[key], !idx.isEmpty else { continue }
            let data: Data = GLBGeometryMath.indexData(idx, wide: wide)
            elements.append(SCNGeometryElement(data: data, primitiveType: SCNGeometryPrimitiveType.triangles, primitiveCount: idx.count / 3,
                                               bytesPerIndex: wide ? 4 : 2))
            materials.append(mat)
        }
        let merged: SCNGeometry = SCNGeometry(sources: sources, elements: elements)
        merged.materials = materials
        return merged
    }

    static func mergedGeometry(of geometries: [SCNGeometry]) -> SCNGeometry? {
        var items: [(geometry: SCNGeometry, transform: simd_float4x4)] = []
        for g in geometries { items.append((geometry: g, transform: matrix_identity_float4x4)) }
        return mergedGeometry(items)
    }
}
