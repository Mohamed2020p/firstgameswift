import Foundation
import SceneKit
import simd

// MARK: - Road / sidewalk / marking geometry for one chunk.
// Layers are drawn in a fixed order without depth writes (painter's algorithm), so no z-fighting is possible:
//   fill (lawns, lots, plaza) -> flat (sidewalks, curbs, medians, paths) -> asphalt -> paint (markings) -> decals

struct WChunkLayers {
    var fill = WMeshSet()
    var flat = WMeshSet()
    var asphalt = WMeshSet()
    var paint = WMeshSet()
    var decals = WMeshSet()
}

private struct WLineSpec {
    var offset: Float
    var width: Float
    var dashed: Bool
    var yellow: Bool
}

@MainActor
final class WRoadBuilder {
    private let layout: WCityLayout
    private let mats: WorldMaterials

    init(layout: WCityLayout, mats: WorldMaterials) {
        self.layout = layout
        self.mats = mats
    }

    // MARK: helpers

    /// t range of segment a->b inside the rect (Liang-Barsky); nil if outside
    private func clipRange(_ a: Vec2, _ b: Vec2, _ r: WRect) -> (Float, Float)? {
        var t0: Float = 0
        var t1: Float = 1
        let d = b - a
        let p: [Float] = [-d.x, d.x, -d.y, d.y]
        let q: [Float] = [a.x - r.x0, r.x1 - a.x, a.y - r.z0, r.z1 - a.y]
        for i in 0..<4 {
            if abs(p[i]) < 1e-6 {
                if q[i] < 0 { return nil }
            } else {
                let t = q[i] / p[i]
                if p[i] < 0 {
                    if t > t1 { return nil }
                    if t > t0 { t0 = t }
                } else {
                    if t < t0 { return nil }
                    if t < t1 { t1 = t }
                }
            }
        }
        return (t0, t1)
    }

    private struct Piece {
        var road: WRoad
        var seg: Int
        var a0: Vec2
        var a1: Vec2
        var n0: Vec2
        var n1: Vec2
        var s0: Float
        var s1: Float
    }

    private func pieces(in rect: WRect, maxLen: Float) -> [Piece] {
        var out: [Piece] = []
        let refs = layout.index.segments(in: rect.expanded(2))
        for packed in refs {
            let ri = packed >> 20
            let si = packed & 0xFFFFF
            let r = layout.index.roads[ri]
            let a = r.segA(si)
            let b = r.segB(si)
            let len = simd_length(b - a)
            if len < 0.01 { continue }
            let n = max(1, Int(ceilf(len / maxLen)))
            let grown = rect.expanded(len / Float(n) + 1)
            guard let range = clipRange(a, b, grown) else { continue }
            let jLo = max(0, Int(floorf(range.0 * Float(n))))
            let jHi = min(n - 1, Int(ceilf(range.1 * Float(n))))
            if jHi < jLo { continue }
            let na = r.normalA(si)
            let nb = r.normalB(si)
            for j in jLo...jHi {
                let t0: Float = Float(j) / Float(n)
                let t1: Float = Float(j + 1) / Float(n)
                let mid = a + (b - a) * ((t0 + t1) * 0.5)
                if !rect.contains(mid) { continue }
                let n0 = (na + (nb - na) * t0).normalizedSafe
                let n1 = (na + (nb - na) * t1).normalizedSafe
                out.append(Piece(road: r, seg: si, a0: a + (b - a) * t0, a1: a + (b - a) * t1, n0: n0, n1: n1,
                                 s0: r.cum[si] + t0 * len, s1: r.cum[si] + t1 * len))
            }
        }
        return out
    }

    private func strip(_ m: WMesh, _ p: Piece, _ dA: Float, _ dB: Float, y: Float, tile: Float) {
        let c0 = p.a0 + p.n0 * dA
        let c1 = p.a1 + p.n1 * dA
        let c2 = p.a1 + p.n1 * dB
        let c3 = p.a0 + p.n0 * dB
        m.groundQuad(c0, c1, c2, c3, y: y, tile: tile)
    }

    private func wall(_ m: WMesh, _ p: Piece, _ d: Float, _ y0: Float, _ y1: Float, facing: Float, tile: Float) {
        let q0 = p.a0 + p.n0 * d
        let q1 = p.a1 + p.n1 * d
        let nrm = (p.n0 + p.n1).normalizedSafe * facing
        let n3 = Vec3(nrm.x, 0, nrm.y)
        m.quad(Vec3(q0.x, y0, q0.y), Vec3(q1.x, y0, q1.y), Vec3(q1.x, y1, q1.y), Vec3(q0.x, y1, q0.y), n3,
               p.s0 / tile, y0 / tile, p.s1 / tile, y1 / tile)
    }

    private func lineSpecs(_ cls: WRoadClass) -> [WLineSpec] {
        switch cls {
        case .street, .connector:
            return [WLineSpec(offset: 0.18, width: 0.13, dashed: false, yellow: true),
                    WLineSpec(offset: -0.18, width: 0.13, dashed: false, yellow: true),
                    WLineSpec(offset: 5.4, width: 0.15, dashed: false, yellow: false),
                    WLineSpec(offset: -5.4, width: 0.15, dashed: false, yellow: false)]
        case .avenue, .ring:
            return [WLineSpec(offset: 0.18, width: 0.13, dashed: false, yellow: true),
                    WLineSpec(offset: -0.18, width: 0.13, dashed: false, yellow: true),
                    WLineSpec(offset: 3.7, width: 0.12, dashed: true, yellow: false),
                    WLineSpec(offset: -3.7, width: 0.12, dashed: true, yellow: false),
                    WLineSpec(offset: 7.4, width: 0.15, dashed: false, yellow: false),
                    WLineSpec(offset: -7.4, width: 0.15, dashed: false, yellow: false)]
        case .boulevard:
            return [WLineSpec(offset: 3.5, width: 0.13, dashed: false, yellow: true),
                    WLineSpec(offset: -3.5, width: 0.13, dashed: false, yellow: true),
                    WLineSpec(offset: 6.7, width: 0.12, dashed: true, yellow: false),
                    WLineSpec(offset: -6.7, width: 0.12, dashed: true, yellow: false),
                    WLineSpec(offset: 10.4, width: 0.15, dashed: false, yellow: false),
                    WLineSpec(offset: -10.4, width: 0.15, dashed: false, yellow: false)]
        case .suburb:
            return [WLineSpec(offset: 0, width: 0.12, dashed: true, yellow: false)]
        }
    }

    private func emitSeg(_ m: WMesh, _ road: WRoad, _ pA: Vec2, _ pB: Vec2, _ nA: Vec2, _ nB: Vec2, _ width: Float, _ depth: Int) {
        let mid = (pA + pB) * 0.5
        let bA = layout.index.insideAsphalt(pA, excluding: road.id, margin: 0.4)
        let bB = layout.index.insideAsphalt(pB, excluding: road.id, margin: 0.4)
        let bM = layout.index.insideAsphalt(mid, excluding: road.id, margin: 0.4)
        if bA && bB && bM { return }
        let len = simd_length(pB - pA)
        if (!bA && !bB && !bM) || depth >= 4 || len < 0.8 {
            if bM && (bA || bB) { return }
            if bM { return }
            let hw = width * 0.5
            let c0 = pA + nA * hw
            let c1 = pB + nB * hw
            let c2 = pB - nB * hw
            let c3 = pA - nA * hw
            m.groundQuad(c0, c1, c2, c3, y: 0.02, tile: 1)
            return
        }
        let nM = (nA + nB).normalizedSafe
        emitSeg(m, road, pA, mid, nA, nM, width, depth + 1)
        emitSeg(m, road, mid, pB, nM, nB, width, depth + 1)
    }

    private func emitLine(_ m: WMesh, _ p: Piece, _ spec: WLineSpec, _ lateralScale: Float) {
        let off = spec.offset * lateralScale
        let len = p.s1 - p.s0
        if len < 0.01 { return }
        if !spec.dashed {
            emitSeg(m, p.road, p.a0 + p.n0 * off, p.a1 + p.n1 * off, p.n0, p.n1, spec.width, 0)
            return
        }
        let period: Float = 9
        let on: Float = 3.2
        var ds = floorf(p.s0 / period) * period
        while ds < p.s1 {
            let lo = max(ds, p.s0)
            let hi = min(ds + on, p.s1)
            if hi - lo > 0.05 {
                let u0 = (lo - p.s0) / len
                let u1 = (hi - p.s0) / len
                let pa = p.a0 + (p.a1 - p.a0) * u0 + (p.n0 + (p.n1 - p.n0) * u0).normalizedSafe * off
                let pb = p.a0 + (p.a1 - p.a0) * u1 + (p.n0 + (p.n1 - p.n0) * u1).normalizedSafe * off
                emitSeg(m, p.road, pa, pb, p.n0, p.n1, spec.width, 1)
            }
            ds += period
        }
    }

    // MARK: main entry

    func build(rect: WRect, lamps: [Vec2], layers: inout WChunkLayers) {
        let ps = pieces(in: rect, maxLen: 18)
        let asphaltM = layers.asphalt.mesh(mats.asphalt)
        let sidewalkM = layers.flat.mesh(mats.sidewalk)
        let curbM = layers.flat.mesh(mats.curb)
        let whiteM = layers.paint.mesh(mats.paintWhite)
        let yellowM = layers.paint.mesh(mats.paintYellow)
        let lawnFill = layers.fill.mesh(mats.lawn)
        let medianM = layers.flat.mesh(mats.lawn)
        let manholeM = layers.decals.mesh(mats.manhole)

        for p in ps {
            let r = p.road
            let h = r.halfWidth
            let sw = r.sidewalk
            let m = r.medianHalf
            // asphalt
            if m > 0 {
                strip(asphaltM, p, m, h, y: 0, tile: 10)
                strip(asphaltM, p, -h, -m, y: 0, tile: 10)
            } else {
                strip(asphaltM, p, -h, h, y: 0, tile: 10)
            }
            // sidewalks, curbs
            let ch = WC.curbH
            for side in [Float(1), Float(-1)] {
                let d0 = h * side
                let d1 = (h + 0.25) * side
                let d2 = (h + sw) * side
                strip(curbM, p, d0, d1, y: ch, tile: 2)
                strip(sidewalkM, p, d1, d2, y: ch, tile: 3.2)
                wall(curbM, p, d0, 0, ch, facing: -side, tile: 2)
                wall(curbM, p, d2, 0, ch, facing: side, tile: 2)
                if m > 0 {
                    let dm = m * side
                    let dmIn = (m - 0.25) * side
                    strip(curbM, p, dm, dmIn, y: ch, tile: 2)
                    wall(curbM, p, dm, 0, ch, facing: side, tile: 2)
                }
                if r.cls == WRoadClass.suburb {
                    let v0 = (h + sw) * side
                    let v1 = (h + sw + 14) * side
                    strip(lawnFill, p, v0, v1, y: 0.005, tile: 8)
                }
            }
            if m > 0 {
                strip(medianM, p, -(m - 0.25), m - 0.25, y: ch, tile: 8)
            }
            // markings
            let specs = lineSpecs(r.cls)
            for sp in specs {
                emitLine(sp.yellow ? yellowM : whiteM, p, sp, 1)
            }
            // manholes
            let hh = wHash01(r.id, Int(p.s0 / 9), 31)
            if hh < 0.05 {
                let lateral: Float = (hh < 0.025 ? 1 : -1) * 2.6
                let c = (p.a0 + p.a1) * 0.5 + p.n0 * lateral
                let dir = (p.a1 - p.a0).normalizedSafe
                let perp = dir.leftPerp
                let hs: Float = 0.5
                manholeM.groundQuad(c - dir * hs - perp * hs, c + dir * hs - perp * hs, c + dir * hs + perp * hs, c - dir * hs + perp * hs, y: 0.03, tile: 1)
                // groundQuad uses planar uv (x/tile); overwrite with local uv below
                fixLastQuadUV(manholeM)
            }
        }

        // crosswalks + stop lines at grid intersections
        let n = WC.roadN
        let aMin = Int(ceilf(rect.x0 / WC.pitch))
        let aMax = Int(ceilf(rect.x1 / WC.pitch)) - 1
        let bMin = Int(ceilf(rect.z0 / WC.pitch))
        let bMax = Int(ceilf(rect.z1 / WC.pitch)) - 1
        if aMin <= aMax && bMin <= bMax {
            for a in aMin...aMax {
                for b in bMin...bMax {
                    if abs(a) > n || abs(b) > n { continue }
                    if a >= 9 && b >= 1 && b <= 5 { continue }          // no intersection where the suburb keeps the grid out
                    crosswalks(a, b, whiteM)
                }
            }
        }

        // light pools under lamps
        if !lamps.isEmpty {
            let poolM = layers.decals.mesh(mats.lightPool)
            for lp in lamps where rect.contains(lp) {
                let hs: Float = 6.5
                let c = lp
                let i0 = poolM.vertex(Vec3(c.x - hs, 0.04, c.y - hs), Vec3(0, 1, 0), 0, 0)
                let i1 = poolM.vertex(Vec3(c.x + hs, 0.04, c.y - hs), Vec3(0, 1, 0), 1, 0)
                let i2 = poolM.vertex(Vec3(c.x + hs, 0.04, c.y + hs), Vec3(0, 1, 0), 1, 1)
                let i3 = poolM.vertex(Vec3(c.x - hs, 0.04, c.y + hs), Vec3(0, 1, 0), 0, 1)
                poolM.tri(i0, i2, i1)
                poolM.tri(i0, i3, i2)
            }
        }
    }

    /// the manhole quad was appended with planar uvs; rewrite its 4 uvs to 0..1
    private func fixLastQuadUV(_ m: WMesh) {
        let n = m.uv.count
        if n < 8 { return }
        m.uv[n - 8] = 0; m.uv[n - 7] = 0
        m.uv[n - 6] = 1; m.uv[n - 5] = 0
        m.uv[n - 4] = 1; m.uv[n - 3] = 1
        m.uv[n - 2] = 0; m.uv[n - 1] = 1
    }

    private func crosswalks(_ a: Int, _ b: Int, _ paint: WMesh) {
        let n = WC.roadN
        let centre = Vec2(Float(a) * WC.pitch, Float(b) * WC.pitch)
        // the streets z = 140 ... 700 end at x = 1120 (only the two hill entrances at z = 280 / 700 continue as suburb roads)
        let eastExists: Bool = !(a == 8 && b >= 1 && b <= 5 && b != 2 && b != 5)
        let arms: [(Vec2, Bool, Int)] = [(Vec2(1, 0), a < n && eastExists, b), (Vec2(-1, 0), a > -n, b), (Vec2(0, 1), b < n, a), (Vec2(0, -1), b > -n, a)]
        for arm in arms {
            if !arm.1 { continue }
            let u = arm.0
            let armRoadK = arm.2                // index of the road this arm belongs to
            let crossK = (u.x != 0) ? a : b      // index of the crossing road
            let hArm = WRoad.dimensions(WCityLayout.gridClass(armRoadK)).half
            let mArm = WRoad.dimensions(WCityLayout.gridClass(armRoadK)).median
            let hc = WRoad.dimensions(WCityLayout.gridClass(crossK)).half
            let lat = u.leftPerp
            let along0 = hc + 1.0
            // zebra bars
            var l: Float = -hArm + 1.2
            while l < hArm - 1.0 {
                if abs(l) > mArm + 0.4 {
                    let c0 = centre + u * along0 + lat * l
                    let c1 = centre + u * (along0 + 3.2) + lat * l
                    let w: Float = 0.25
                    paint.groundQuad(c0 - lat * w, c1 - lat * w, c1 + lat * w, c0 + lat * w, y: 0.02, tile: 1)
                }
                l += 1.05
            }
            // stop line on the incoming (right hand traffic) half
            let f = u * -1
            let rv = Vec2(-f.y, f.x)
            let inner: Float = mArm > 0 ? mArm + 0.3 : 0.3
            let outer = hArm - 2.6
            if outer > inner + 1 {
                let s0 = centre + u * (along0 + 4.2) + rv * inner
                let s1 = centre + u * (along0 + 4.2) + rv * outer
                let w2: Float = 0.25
                paint.groundQuad(s0 - u * w2, s1 - u * w2, s1 + u * w2, s0 + u * w2, y: 0.02, tile: 1)
            }
        }
    }
}
