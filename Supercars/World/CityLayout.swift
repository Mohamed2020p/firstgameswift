import Foundation
import simd

// MARK: - Deterministic city layout: road network, blocks, lots (building placements), race routes, spawn points

enum WBlockKind { case downtown, midrise, residential, park, plaza, industrial, civic }

struct WBlock {
    var i: Int
    var j: Int
    var rect: WRect
    var kind: WBlockKind
}

enum WLotKind { case glb, tower, lowrise, house, warehouse }

struct WBuildingInfo {
    var name: String
    var width: Float
    var height: Float
    var depth: Float
    var hasShops: Bool
}

struct WLot {
    var kind: WLotKind
    var center: Vec2
    var heading: Float
    var width: Float
    var depth: Float
    var height: Float
    var model: Int
    var scale: Float
    var style: Int
    var variant: Int
    var mask: Int          // tower exposure: 1 = +z, 2 = -z, 4 = +x, 8 = -x
    var seed: Int
    var colliderID: Int
}

struct WPlot {
    var center: Vec2
    var heading: Float
    func toWorld(_ lx: Float, _ lz: Float) -> Vec2 {
        return center + headingLeft2(heading) * lx + headingForward2(heading) * lz
    }
    func toLocal(_ p: Vec2) -> Vec2 {
        let d = p - center
        return Vec2(simd_dot(d, headingLeft2(heading)), simd_dot(d, headingForward2(heading)))
    }
}

final class WCityLayout {
    let index = WRoadIndex()
    var roads: [WRoad] = []
    var blocks: [WBlock] = []
    var lots: [WLot] = []
    var infos: [WBuildingInfo] = []
    var lotsByChunk: [Int: [Int]] = [:]
    var routes: [RaceRoute] = []
    var spawn: SpawnPoints
    var plot = WPlot(center: Vec2(0, 0), heading: 0)
    var gate = Spawn(position: Vec3(0, 0, 0), heading: 0)
    var parkRects: [WRect] = []
    var plazaRect = WRect(x0: 0, z0: 0, x1: 0, z1: 0)
    var blockLookup: [Int: Int] = [:]      // (i+20)*64 + (j+20) -> index into blocks
    var suburbRoadIDs: [Int] = []
    var ringID: Int = -1
    var rng = SeededRNG(seed: 20240611)

    init() {
        let z = Spawn(position: Vec3(0, 0, 0), heading: 0)
        spawn = SpawnPoints(houseDoor: z, car: z, player: z, garageDoor: z, raceGate: z, house: z)
    }

    static func gridCorridor(_ k: Int) -> Float {
        if k == 0 { return 17 }
        if k % 3 == 0 { return 14 }
        return 12
    }

    static func gridClass(_ k: Int) -> WRoadClass {
        if k == 0 { return WRoadClass.boulevard }
        if k % 3 == 0 { return WRoadClass.avenue }
        return WRoadClass.street
    }

    private func addRoad(_ cls: WRoadClass, _ name: String, _ pts: [Vec2], closed: Bool, grid: Bool) -> WRoad {
        let r = WRoad(id: roads.count, cls: cls, name: name, points: pts, closed: closed, isGrid: grid)
        roads.append(r)
        index.add(r)
        return r
    }

    func blockAt(i: Int, j: Int) -> WBlock? {
        if let bi = blockLookup[(i + 20) * 64 + (j + 20)] { return blocks[bi] }
        return nil
    }

    // MARK: generate

    func generate(infos buildingInfos: [WBuildingInfo]) {
        infos = buildingInfos
        makeRoads()
        makeBlocks()
        makeLots()
        makeSuburb()
        makeRoutes()
        bucketLots()
    }

    // MARK: roads

    private func makeRoads() {
        // the streets run through the whole endless-world tile (lines -11 ... 11); only the hillside suburb keeps the grid out:
        // east of x = 1120 the streets z = 140 ... 700 stop, and the two north-south lines x = 1260 / 1400 skip the suburb's z range
        let n = WC.roadN
        let ext: Float = Float(n) * WC.pitch
        let suburb: WRect = WGrid.suburbRect
        for k in -n...n {
            let cls = WCityLayout.gridClass(k)
            let c = Float(k) * WC.pitch
            var xEnd: Float = ext
            if c > suburb.z0 - 30 && c < suburb.z1 + 30 { xEnd = WC.pitch * Float(WC.gridN) }
            _ = addRoad(cls, "Street X\(k)", [Vec2(-ext, c), Vec2(xEnd, c)], closed: false, grid: true)
            if c > suburb.x0 + 60 && c < suburb.x1 - 30 {
                // a north-south line that would cross the suburb: two pieces
                _ = addRoad(cls, "Street Z\(k)a", [Vec2(c, -ext), Vec2(c, suburb.z0 - 20)], closed: false, grid: true)
                _ = addRoad(cls, "Street Z\(k)b", [Vec2(c, suburb.z1 + 20), Vec2(c, ext)], closed: false, grid: true)
            } else {
                _ = addRoad(cls, "Street Z\(k)", [Vec2(c, -ext), Vec2(c, ext)], closed: false, grid: true)
            }
        }
        // curved ring road around downtown
        var ringPts: [Vec2] = []
        let count = 260
        for i in 0..<count {
            let th: Float = Float(i) / Float(count) * Float.tau
            let r: Float = 610 + 30 * sinf(3 * th + 0.4) + 14 * sinf(5 * th + 1.3)
            ringPts.append(Vec2(cosf(th) * r, sinf(th) * r))
        }
        let ring = addRoad(WRoadClass.ring, "Ring Road", ringPts, closed: true, grid: false)
        ringID = ring.id
        // hairpin connector of the race circuit (semicircle r = 70 between b = 1 and b = 2 east of a = 6)
        var hp: [Vec2] = []
        let steps = 28
        for i in 0...steps {
            let a: Float = -Float.pi * 0.5 + Float(i) / Float(steps) * Float.pi
            hp.append(Vec2(840 + 70 * cosf(a), 210 + 70 * sinf(a)))
        }
        _ = addRoad(WRoadClass.connector, "Hairpin", hp, closed: false, grid: false)
        // hillside suburb
        let hill: [Vec2] = [Vec2(1120, 280), Vec2(1190, 270), Vec2(1270, 300), Vec2(1335, 360), Vec2(1370, 440),
                            Vec2(1365, 530), Vec2(1320, 610), Vec2(1250, 665), Vec2(1180, 690), Vec2(1120, 700)]
        let hillR = addRoad(WRoadClass.suburb, "Hillcrest Drive", WSpline.catmull(hill, step: 7, closed: false), closed: false, grid: false)
        let summit: [Vec2] = [Vec2(1370, 440), Vec2(1420, 420), Vec2(1450, 370), Vec2(1455, 300), Vec2(1440, 240), Vec2(1410, 190)]
        let summitR = addRoad(WRoadClass.suburb, "Summit Lane", WSpline.catmull(summit, step: 7, closed: false), closed: false, grid: false)
        // cul-de-sac bulb
        let endInfo = summitR.sample(at: summitR.length)
        let bulbCenter = endInfo.p + endInfo.dir * 10
        var bulb: [Vec2] = []
        for i in 0..<16 {
            let a: Float = Float(i) / 16 * Float.tau
            bulb.append(bulbCenter + Vec2(cosf(a), sinf(a)) * 11)
        }
        let bulbR = addRoad(WRoadClass.suburb, "Summit Circle", bulb, closed: true, grid: false)
        suburbRoadIDs = [hillR.id, summitR.id, bulbR.id]
        roads = index.roads
    }

    // MARK: blocks

    private func makeBlocks() {
        let n = WC.gridN
        for i in -n..<n {
            for j in -n..<n {
                let x0 = Float(i) * WC.pitch + WCityLayout.gridCorridor(i)
                let x1 = Float(i + 1) * WC.pitch - WCityLayout.gridCorridor(i + 1)
                let z0 = Float(j) * WC.pitch + WCityLayout.gridCorridor(j)
                let z1 = Float(j + 1) * WC.pitch - WCityLayout.gridCorridor(j + 1)
                let rect = WRect(x0: x0, z0: z0, x1: x1, z1: z1)
                let c = rect.center
                var kind = WBlockKind.residential
                let ad = max(abs(c.x), abs(c.y))
                let dist = simd_length(c)
                if ad <= 420 { kind = WBlockKind.downtown }
                else if dist < 800 { kind = WBlockKind.midrise }
                if i == -2 && j == 1 { kind = WBlockKind.park }
                if i == 5 && j == -5 { kind = WBlockKind.park }
                if i == -2 && j == -4 { kind = WBlockKind.plaza }
                if i == 2 && j == 3 { kind = WBlockKind.civic }         // police station + public parking
                if i <= -6 && j <= -6 { kind = WBlockKind.industrial }
                blocks.append(WBlock(i: i, j: j, rect: rect, kind: kind))
                blockLookup[(i + 20) * 64 + (j + 20)] = blocks.count - 1
                if kind == WBlockKind.park { parkRects.append(rect) }
                if kind == WBlockKind.plaza { plazaRect = rect }
            }
        }
    }

    // MARK: lots

    private func footprintFree(_ center: Vec2, _ along: Vec2, _ outward: Vec2, _ w: Float, _ d: Float, extra: Float) -> Bool {
        let hw = w * 0.5
        let hd = d * 0.5
        let offsets: [(Float, Float)] = [(0, 0), (hw, hd), (-hw, hd), (hw, -hd), (-hw, -hd), (hw, 0), (-hw, 0), (0, hd), (0, -hd)]
        for o in offsets {
            let p = center + along * o.0 + outward * o.1
            if index.insideCurvedCorridor(p, extra: extra) { return false }
        }
        return true
    }

    private func pickInfo(maxWidth: Float, maxHeight: Float) -> Int {
        if infos.isEmpty { return -1 }
        var cands: [Int] = []
        for (i, inf) in infos.enumerated() where inf.width * 0.9 <= maxWidth && inf.height <= maxHeight {
            cands.append(i)
        }
        if cands.isEmpty { return -1 }
        return cands[rng.int(0, cands.count - 1)]
    }

    private func newLot(_ kind: WLotKind, _ c: Vec2, _ heading: Float, _ w: Float, _ d: Float, _ h: Float) -> WLot {
        return WLot(kind: kind, center: c, heading: heading, width: w, depth: d, height: h, model: -1, scale: 1, style: 0, variant: 0,
                    mask: 0, seed: rng.int(0, 1_000_000), colliderID: -1)
    }

    /// mode 0 glb / lowrise mix, 1 houses, 2 warehouses. Returns the depth used (incl. setback).
    private func fillRow(start: Vec2, along: Vec2, outward: Vec2, length: Float, setback: Float, mode: Int, maxHeight: Float) -> Float {
        var s: Float = rng.float(0, 3)
        var maxDepth: Float = 0
        var guardCount = 0
        let heading = headingOf(outward)
        while s < length - 8 && guardCount < 60 {
            guardCount += 1
            let remaining = length - s
            var lot = newLot(WLotKind.glb, Vec2(0, 0), heading, 10, 10, 10)
            var gap: Float = 0
            if mode == 0 {
                let roll = rng.float()
                if roll < 0.28 || infos.isEmpty {
                    let w = rng.float(22, 38)
                    if w > remaining { break }
                    let d = rng.float(20, 28)
                    lot = newLot(WLotKind.lowrise, Vec2(0, 0), heading, w, d, rng.float(14, min(maxHeight + 8, 48)))
                    lot.style = 3 + rng.int(0, 3)
                    lot.variant = rng.int(0, 1)
                    gap = rng.chance(0.25) ? rng.float(3, 7) : 0
                } else {
                    let mi = pickInfo(maxWidth: remaining, maxHeight: maxHeight)
                    if mi < 0 { break }
                    let inf = infos[mi]
                    let sc = rng.float(0.94, 1.1)
                    lot = newLot(WLotKind.glb, Vec2(0, 0), heading, inf.width * sc, inf.depth * sc, inf.height * sc)
                    lot.model = mi
                    lot.scale = sc
                    gap = rng.chance(0.2) ? rng.float(3, 8) : 0.5
                }
            } else if mode == 1 {
                let w = rng.float(11, 15)
                if w > remaining { break }
                lot = newLot(WLotKind.house, Vec2(0, 0), heading, w, rng.float(10, 12.5), rng.float(6.2, 9.0))
                lot.style = rng.int(0, 2)
                lot.variant = rng.int(0, 2)
                gap = rng.float(7, 14)
            } else {
                let w = rng.float(28, 46)
                if w > remaining { break }
                lot = newLot(WLotKind.warehouse, Vec2(0, 0), heading, w, rng.float(26, 40), rng.float(8, 14))
                lot.style = rng.int(0, 2)
                gap = rng.float(4, 10)
            }
            let front = start + along * (s + lot.width * 0.5) - outward * setback
            let c = front - outward * (lot.depth * 0.5)
            if footprintFree(c, along, outward, lot.width, lot.depth, extra: 2) {
                lot.center = c
                lots.append(lot)
                maxDepth = max(maxDepth, lot.depth + setback)
            }
            s += lot.width + gap
        }
        return maxDepth
    }

    private func makeLots() {
        for b in blocks {
            let r = b.rect
            switch b.kind {
            case .park, .plaza, .civic:
                continue
            case .downtown:
                makeDowntownBlock(r)
            case .midrise:
                makeFrontage(r, mode: 0, setback: 0.5, maxHeight: 60)
            case .residential:
                makeFrontage(r, mode: 1, setback: 6, maxHeight: 24)
            case .industrial:
                makeFrontage(r, mode: 2, setback: 8, maxHeight: 20)
            }
        }
    }

    private func makeFrontage(_ r: WRect, mode: Int, setback: Float, maxHeight: Float) {
        var mh = maxHeight
        let dist = simd_length(r.center)
        if mode == 0 && dist > 650 { mh = 32 }
        let dN = fillRow(start: Vec2(r.x0, r.z1), along: Vec2(1, 0), outward: Vec2(0, 1), length: r.width, setback: setback, mode: mode, maxHeight: mh)
        let dS = fillRow(start: Vec2(r.x0, r.z0), along: Vec2(1, 0), outward: Vec2(0, -1), length: r.width, setback: setback, mode: mode, maxHeight: mh)
        let zLo = r.z0 + dS + 1
        let zHi = r.z1 - dN - 1
        if zHi - zLo > 12 {
            _ = fillRow(start: Vec2(r.x1, zLo), along: Vec2(0, 1), outward: Vec2(1, 0), length: zHi - zLo, setback: setback, mode: mode, maxHeight: mh)
            _ = fillRow(start: Vec2(r.x0, zLo), along: Vec2(0, 1), outward: Vec2(-1, 0), length: zHi - zLo, setback: setback, mode: mode, maxHeight: mh)
        }
    }

    private func makeDowntownBlock(_ r: WRect) {
        let hw = (r.width - 4) * 0.5
        let hd = (r.depth - 4) * 0.5
        for i in 0..<2 {
            for j in 0..<2 {
                let x0 = i == 0 ? r.x0 : r.x1 - hw
                let z0 = j == 0 ? r.z0 : r.z1 - hd
                let c = Vec2(x0 + hw * 0.5, z0 + hd * 0.5)
                var mask = 0
                if j == 1 { mask |= 1 }
                if j == 0 { mask |= 2 }
                if i == 1 { mask |= 4 }
                if i == 0 { mask |= 8 }
                let dist = simd_length(c)
                let t = 1 - clampf(dist / 520, 0, 1)
                if rng.chance(0.2) {
                    var lot = newLot(WLotKind.lowrise, c, 0, hw, hd, rng.float(16, 34))
                    lot.style = 3 + rng.int(0, 3)
                    lot.variant = rng.int(0, 1)
                    lot.mask = mask
                    if footprintFree(c, Vec2(1, 0), Vec2(0, 1), hw, hd, extra: 2) { lots.append(lot) }
                    continue
                }
                var h: Float = 42 + powf(t, 1.3) * 150 * rng.float(0.55, 1.0) + rng.float(0, 18)
                h = clampf(h, 34, 215)
                var lot = newLot(WLotKind.tower, c, 0, hw, hd, h)
                lot.style = rng.chance(0.75) ? rng.int(0, 2) : (rng.chance(0.5) ? 3 : 6)
                lot.variant = rng.int(0, 1)
                lot.mask = mask
                if footprintFree(c, Vec2(1, 0), Vec2(0, 1), hw, hd, extra: 2) { lots.append(lot) }
            }
        }
    }

    // MARK: suburb and the player's house plot

    private func makeSuburb() {
        // house plot on Summit Lane, on the side with more room
        let summit = roads[suburbRoadIDs[1]]
        let s = summit.length * 0.45
        let smp = summit.sample(at: s)
        let left = smp.dir.leftPerp
        let hill = roads[suburbRoadIDs[0]]
        var bestSide: Float = 1
        var bestDist: Float = -1
        for side in [Float(1), Float(-1)] {
            let cand = smp.p + left * side * 26.5
            var md: Float = 1e9
            for p in hill.points { md = min(md, simd_length(p - cand)) }
            if md > bestDist { bestDist = md; bestSide = side }
        }
        let sideDir = left * bestSide
        let center = smp.p + sideDir * 26.5
        let heading = headingOf(sideDir * -1)
        plot = WPlot(center: center, heading: heading)
        let h = Vec3(center.x, 0, center.y)
        func w(_ lx: Float, _ lz: Float) -> Vec3 { let p = plot.toWorld(lx, lz); return Vec3(p.x, 0, p.y) }
        spawn.house = Spawn(position: h, heading: heading)
        spawn.houseDoor = Spawn(position: w(-3, 8.4), heading: heading)
        spawn.garageDoor = Spawn(position: w(14, 8.4), heading: heading)
        spawn.car = Spawn(position: w(14, 15.5), heading: heading)
        spawn.player = Spawn(position: w(-3, 13.5), heading: wrapAngle(heading + Float.pi))

        // houses along the suburb streets
        for rid in [suburbRoadIDs[0], suburbRoadIDs[1]] {
            let road = roads[rid]
            var pos: Float = 18
            while pos < road.length - 16 {
                let smpl = road.sample(at: pos)
                let lft = smpl.dir.leftPerp
                for side in [Float(1), Float(-1)] {
                    let sideVec = lft * side
                    let d = rng.float(10, 12)
                    let wd = rng.float(11, 15)
                    let off = road.corridor + 7 + d * 0.5
                    let c = smpl.p + sideVec * off
                    let headingH = headingOf(sideVec * -1)
                    // stay clear of the reserved plot and other curved roads
                    let lp = plot.toLocal(c)
                    if abs(lp.x) < 34 && lp.y > -32 && lp.y < 30 { continue }
                    if abs(c.x) > 1480 || abs(c.y) > 1480 { continue }
                    let alongV = sideVec.leftPerp
                    var ok = true
                    let offsets: [(Float, Float)] = [(0, 0), (wd * 0.5, d * 0.5), (-wd * 0.5, d * 0.5), (wd * 0.5, -d * 0.5), (-wd * 0.5, -d * 0.5)]
                    for o in offsets {
                        let p = c + alongV * o.0 + sideVec * o.1
                        if nearOtherRoad(p, excluding: rid) { ok = false; break }
                    }
                    if !ok { continue }
                    var lot = newLot(WLotKind.house, c, headingH, wd, d, rng.float(6.2, 9.0))
                    lot.style = rng.int(0, 2)
                    lot.variant = rng.int(0, 2)
                    lots.append(lot)
                }
                pos += rng.float(30, 38)
            }
        }
    }

    private func nearOtherRoad(_ p: Vec2, excluding rid: Int) -> Bool {
        if let hit = index.nearest(p, maxDist: 30) {
            _ = hit
        }
        // check every road in the neighbourhood other than `rid`
        let segs = index.segments(in: WRect(x0: p.x - 1, z0: p.y - 1, x1: p.x + 1, z1: p.y + 1))
        for packed in segs {
            let ri = packed >> 20
            if ri == rid { continue }
            let r = index.roads[ri]
            let si = packed & 0xFFFFF
            let d = wSegmentDistance(p, r.segA(si), r.segB(si)).dist
            if d <= r.corridor + 3 { return true }
        }
        return false
    }

    func insidePlot(_ p: Vec2, margin: Float) -> Bool {
        let lp = plot.toLocal(p)
        return abs(lp.x) < 24 + margin && lp.y > -22 - margin && lp.y < 18 + margin
    }

    // MARK: race routes

    private func lat(_ a: Float, _ b: Float) -> Vec2 { return Vec2(a * WC.pitch, b * WC.pitch) }

    /// rounds the corners of a closed waypoint loop with the given radii and returns a dense polyline
    static func roundedLoop(_ wp: [Vec2], _ radii: [Float]) -> [Vec2] {
        var out: [Vec2] = []
        let n = wp.count
        for i in 0..<n {
            let prev = wp[(i + n - 1) % n]
            let q = wp[i]
            let next = wp[(i + 1) % n]
            let d0 = (q - prev).normalizedSafe
            let d1 = (next - q).normalizedSafe
            let r = radii[i]
            let cosT = clampf(simd_dot(d0, d1), -1, 1)
            let theta = acosf(cosT)
            if r < 0.01 || theta < 0.02 {
                out.append(q)
                continue
            }
            let cut = r * tanf(theta * 0.5)
            let sPt = q - d0 * cut
            let ePt = q + d1 * cut
            let crossZ = d0.x * d1.y - d0.y * d1.x
            let side: Float = crossZ > 0 ? 1 : -1
            let nrm = Vec2(-d0.y, d0.x) * side
            let cen = sPt + nrm * r
            let a0 = atan2f(sPt.y - cen.y, sPt.x - cen.x)
            let a1 = atan2f(ePt.y - cen.y, ePt.x - cen.x)
            let delta = wrapAngle(a1 - a0)
            let steps = max(4, Int(abs(delta) * r / 1.5))
            for k in 0...steps {
                let a = a0 + delta * Float(k) / Float(steps)
                out.append(cen + Vec2(cosf(a), sinf(a)) * r)
            }
        }
        return out
    }

    private func makeRoutes() {
        let r: Float = 16
        let wp: [Vec2] = [lat(-3, -3), lat(2, -3), lat(2, -1), lat(4, -1), lat(4, 1), Vec2(910, 140), Vec2(910, 280),
                          lat(1, 2), lat(1, 0), lat(-1, 0), lat(-1, -2), lat(-3, -2)]
        let radii: [Float] = [r, r, r, r, r, 70, 70, r, r, r, r, r]
        let dense = WCityLayout.roundedLoop(wp, radii)
        var pts = WSpline.resample(dense, spacing: 5, closed: true)
        // rotate so the route starts at the race gate
        let gatePos = Vec2(-210, -420)
        var bestI = 0
        var bestD: Float = 1e9
        for (i, p) in pts.enumerated() {
            let d = simd_length(p - gatePos)
            if d < bestD { bestD = d; bestI = i }
        }
        if bestI > 0 { pts = Array(pts[bestI...]) + Array(pts[..<bestI]) }
        let len = WSpline.length(pts, closed: true)
        routes.append(RaceRoute(name: "Downtown GP", points: pts, width: 16, closed: true, length: len))
        gate = Spawn(position: Vec3(pts[0].x, 0, pts[0].y), heading: headingOf((pts[1] - pts[0]).normalizedSafe))
        spawn.raceGate = gate
        // second route: the ring road
        let ring = roads[ringID]
        let ringPts = WSpline.resample(ring.points, spacing: 5, closed: true)
        routes.append(RaceRoute(name: "Ring Road Sprint", points: ringPts, width: 18, closed: true, length: WSpline.length(ringPts, closed: true)))
    }

    private func bucketLots() {
        for (i, l) in lots.enumerated() {
            let key = wChunkKey(wChunkCoord(l.center.x), wChunkCoord(l.center.y))
            if lotsByChunk[key] == nil { lotsByChunk[key] = [i] } else { lotsByChunk[key]!.append(i) }
        }
    }

    // MARK: queries

    func surface(at p: Vec2) -> SurfaceType {
        let c = index.classify(p)
        if c == 1 { return SurfaceType.asphalt }
        if c == 2 { return SurfaceType.sidewalk }
        if c == 3 { return SurfaceType.grass }
        if insidePlot(p, margin: 0) {
            let lp = plot.toLocal(p)
            if HousePlan.isPaved(lp) { return SurfaceType.concrete }
            return SurfaceType.grass
        }
        let n = WC.gridN
        let ext = Float(n) * WC.pitch
        if abs(p.x) <= ext && abs(p.y) <= ext {
            let bi = Int(floorf(p.x / WC.pitch))
            let bj = Int(floorf(p.y / WC.pitch))
            if let b = blockAt(i: bi, j: bj) {
                switch b.kind {
                case .park: return SurfaceType.grass
                case .residential: return SurfaceType.grass
                default: return SurfaceType.concrete
                }
            }
            return SurfaceType.concrete
        }
        // suburb yards
        for rid in suburbRoadIDs {
            let r = roads[rid]
            if let hit = index.nearest(p, maxDist: 70), hit.road.id == r.id { return SurfaceType.grass }
        }
        // the green belt between the city islands: fields
        return SurfaceType.grass
    }
}
