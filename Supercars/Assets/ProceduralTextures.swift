import Foundation
import UIKit
import CoreGraphics

// MARK: - ProceduralTextures: deterministic, CoreGraphics-only texture generators (no per-pixel loops above 512x512).
//
// All images are drawn in UIKit coordinates (origin top-left, y down) and are rendered at scale 1 (1 point = 1 pixel, standard sRGB range).
// The top row of the image ends up at v = 1 when used as a SCNMaterialProperty (SceneKit convention, see MeshBuilder).
// "Tileable" generators wrap around every edge so they can use wrapS/wrapT = .repeat without visible seams.
// Every generator takes a `seed`; the same arguments always produce the same pixels.

enum ProceduralTextures {

    // MARK: core

    /// Renders `draw` into a UIImage of `size` pixels. The CGContext uses UIKit coordinates (origin top-left).
    static func image(size: CGSize, opaque: Bool, draw: (CGContext) -> Void) -> UIImage {
        let format: UIGraphicsImageRendererFormat = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        format.preferredRange = UIGraphicsImageRendererFormat.Range.standard
        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { (rc: UIGraphicsImageRendererContext) -> Void in
            draw(rc.cgContext)
        }
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        return UIColor(red: r, green: g, blue: b, alpha: a).cgColor
    }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        ctx.setFillColor(color(r, g, b, a))
        ctx.fill(rect)
    }

    private static func rand(_ rng: inout SeededRNG, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        return CGFloat(rng.float(Float(lo), Float(hi)))
    }

    private static func linearGradient(_ ctx: CGContext, _ rect: CGRect, top: [CGFloat], bottom: [CGFloat]) {
        let space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
        let colors: [CGColor] = [color(top[0], top[1], top[2], 1), color(bottom[0], bottom[1], bottom[2], 1)]
        guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    /// extra offsets (0 plus +-size) needed to draw a feature of radius `r` at coordinate `v` so it wraps around the tile edge
    private static func wrapOffsets(_ v: CGFloat, _ r: CGFloat, _ size: CGFloat) -> [CGFloat] {
        var o: [CGFloat] = [0]
        if v < r { o.append(size) }
        if v > size - r { o.append(-size) }
        return o
    }

    /// calls `body(dx, dy)` for every wrapped copy of a feature at (x, y) with radius `r`
    private static func forWrapped(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ size: CGFloat, _ body: (CGFloat, CGFloat) -> Void) {
        let xs: [CGFloat] = wrapOffsets(x, r, size)
        let ys: [CGFloat] = wrapOffsets(y, r, size)
        for dx in xs {
            for dy in ys { body(dx, dy) }
        }
    }

    // MARK: noise

    private static func hash01(_ x: Int, _ y: Int, _ seed: UInt64) -> Float {
        var h: UInt64 = seed &+ 0x9E37_79B9_7F4A_7C15
        let hx: UInt64 = UInt64(truncatingIfNeeded: x) &* 0xBF58_476D_1CE4_E5B9
        let hy: UInt64 = UInt64(truncatingIfNeeded: y) &* 0x94D0_49BB_1331_11EB
        h = h ^ hx
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = h ^ hy
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        h = h ^ (h >> 31)
        return Float(h >> 40) / 16777216.0
    }

    /// Tileable fractal value noise in 0...1 (size*size values, row-major, top row first). `size` is clamped to 4...512.
    static func noiseField(size: Int, seed: UInt64, octaves: Int) -> [Float] {
        let s: Int = max(4, min(size, 512))
        var out: [Float] = [Float](repeating: 0, count: s * s)
        var amp: Float = 1
        var total: Float = 0
        var period: Int = 4
        let count: Int = max(1, min(octaves, 7))
        for o in 0..<count {
            if period > s { break }
            let octaveSeed: UInt64 = seed &+ UInt64(o) &* 7919
            var lattice: [Float] = [Float](repeating: 0, count: period * period)
            for ly in 0..<period {
                for lx in 0..<period { lattice[ly * period + lx] = hash01(lx, ly, octaveSeed) }
            }
            for y in 0..<s {
                let fy: Float = Float(y) / Float(s) * Float(period)
                let iy: Int = Int(fy)
                let ty0: Float = fy - Float(iy)
                let ty: Float = ty0 * ty0 * (3 - 2 * ty0)
                let y0: Int = iy % period
                let y1: Int = (iy + 1) % period
                for x in 0..<s {
                    let fx: Float = Float(x) / Float(s) * Float(period)
                    let ix: Int = Int(fx)
                    let tx0: Float = fx - Float(ix)
                    let tx: Float = tx0 * tx0 * (3 - 2 * tx0)
                    let x0: Int = ix % period
                    let x1: Int = (ix + 1) % period
                    let a: Float = lattice[y0 * period + x0]
                    let b: Float = lattice[y0 * period + x1]
                    let c: Float = lattice[y1 * period + x0]
                    let d: Float = lattice[y1 * period + x1]
                    let top: Float = a + (b - a) * tx
                    let bottom: Float = c + (d - c) * tx
                    out[y * s + x] += (top + (bottom - top) * ty) * amp
                }
            }
            total += amp
            amp *= 0.5
            period *= 2
        }
        if total > 0 {
            for i in 0..<out.count { out[i] = min(max(out[i] / total, 0), 1) }
        }
        return out
    }

    private static func grayImage(_ field: [Float], side: Int, contrast: Float) -> UIImage {
        let space: CGColorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = ctx.data else {
            return UIImage()
        }
        let p: UnsafeMutablePointer<UInt8> = raw.assumingMemoryBound(to: UInt8.self)
        let bpr: Int = ctx.bytesPerRow
        for y in 0..<side {
            for x in 0..<side {
                let v: Float = (field[y * side + x] - 0.5) * contrast + 0.5
                p[y * bpr + x] = UInt8(min(max(v * 255 + 0.5, 0), 255))
            }
        }
        guard let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// Grey tileable fractal noise image (generated at <= 512 px and smoothly scaled up when `size` is larger).
    static func noise(size: Int, seed: UInt64 = 1, octaves: Int = 4, contrast: Float = 1) -> UIImage {
        let s: Int = max(4, min(size, 512))
        let field: [Float] = noiseField(size: s, seed: seed, octaves: octaves)
        let small: UIImage = grayImage(field, side: s, contrast: contrast)
        if size <= 512 { return small }
        let sz: CGSize = CGSize(width: size, height: size)
        return image(size: sz, opaque: true) { (ctx: CGContext) -> Void in
            ctx.interpolationQuality = CGInterpolationQuality.high
            small.draw(in: CGRect(origin: CGPoint.zero, size: sz))
        }
    }

    /// blends a noise layer over the current context
    private static func overlayNoise(_ size: CGFloat, seed: UInt64, octaves: Int, mode: CGBlendMode, alpha: CGFloat, contrast: Float = 1.6) {
        let n: UIImage = noise(size: Int(size), seed: seed, octaves: octaves, contrast: contrast)
        n.draw(in: CGRect(x: 0, y: 0, width: size, height: size), blendMode: mode, alpha: alpha)
    }

    // MARK: asphalt

    static func asphalt(size: Int = 512, seed: UInt64 = 11) -> UIImage {
        let s: CGFloat = CGFloat(size)
        return image(size: CGSize(width: s, height: s), opaque: true) { (ctx: CGContext) -> Void in
            var rng: SeededRNG = SeededRNG(seed: seed)
            fill(ctx, CGRect(x: 0, y: 0, width: s, height: s), 0.19, 0.19, 0.20)
            overlayNoise(s, seed: seed &+ 1, octaves: 3, mode: CGBlendMode.overlay, alpha: 0.75)
            overlayNoise(s, seed: seed &+ 2, octaves: 6, mode: CGBlendMode.softLight, alpha: 0.6, contrast: 2.2)
            // aggregate speckles
            let dots: Int = max(200, size * size / 70)
            for _ in 0..<dots {
                let x: CGFloat = rand(&rng, 0, s)
                let y: CGFloat = rand(&rng, 0, s)
                let r: CGFloat = rand(&rng, 0.35, 1.15)
                let light: CGFloat = rand(&rng, 0.05, 0.6)
                let dark: Bool = rng.chance(0.4)
                let g: CGFloat = dark ? 0.06 : 0.35 + light * 0.4
                forWrapped(x, y, r, s) { (dx: CGFloat, dy: CGFloat) -> Void in
                    ctx.setFillColor(color(g, g, g * 1.02, dark ? 0.45 : 0.35))
                    ctx.fillEllipse(in: CGRect(x: x + dx - r, y: y + dy - r, width: r * 2, height: r * 2))
                }
            }
            // hairline cracks that stay inside the tile
            ctx.setLineCap(CGLineCap.round)
            for _ in 0..<3 {
                var x: CGFloat = rand(&rng, s * 0.15, s * 0.85)
                var y: CGFloat = rand(&rng, s * 0.15, s * 0.85)
                var a: CGFloat = rand(&rng, 0, CGFloat.pi * 2)
                ctx.setStrokeColor(color(0.05, 0.05, 0.06, 0.55))
                ctx.setLineWidth(max(0.7, s / 600))
                ctx.beginPath()
                ctx.move(to: CGPoint(x: x, y: y))
                for _ in 0..<14 {
                    a += rand(&rng, -0.6, 0.6)
                    x += cos(a) * s * 0.03
                    y += sin(a) * s * 0.03
                    if x < s * 0.04 || x > s * 0.96 || y < s * 0.04 || y > s * 0.96 { break }
                    ctx.addLine(to: CGPoint(x: x, y: y))
                }
                ctx.strokePath()
            }
        }
    }

    // MARK: concrete slabs (sidewalks)

    static func concreteTiles(size: Int = 512, tiles: Int = 4, seed: UInt64 = 21) -> UIImage {
        let s: CGFloat = CGFloat(size)
        let n: Int = max(1, tiles)
        let cell: CGFloat = s / CGFloat(n)
        return image(size: CGSize(width: s, height: s), opaque: true) { (ctx: CGContext) -> Void in
            var rng: SeededRNG = SeededRNG(seed: seed)
            fill(ctx, CGRect(x: 0, y: 0, width: s, height: s), 0.62, 0.62, 0.60)
            for ty in 0..<n {
                for tx in 0..<n {
                    let v: CGFloat = rand(&rng, -0.05, 0.05)
                    fill(ctx, CGRect(x: CGFloat(tx) * cell, y: CGFloat(ty) * cell, width: cell, height: cell), 0.62 + v, 0.62 + v, 0.60 + v, 1)
                }
            }
            overlayNoise(s, seed: seed &+ 1, octaves: 4, mode: CGBlendMode.softLight, alpha: 0.8)
            overlayNoise(s, seed: seed &+ 2, octaves: 6, mode: CGBlendMode.overlay, alpha: 0.35, contrast: 2.0)
            let dots: Int = max(100, size * size / 120)
            for _ in 0..<dots {
                let x: CGFloat = rand(&rng, 0, s)
                let y: CGFloat = rand(&rng, 0, s)
                let r: CGFloat = rand(&rng, 0.3, 0.9)
                let g: CGFloat = rand(&rng, 0.35, 0.8)
                forWrapped(x, y, r, s) { (dx: CGFloat, dy: CGFloat) -> Void in
                    ctx.setFillColor(color(g, g, g, 0.28))
                    ctx.fillEllipse(in: CGRect(x: x + dx - r, y: y + dy - r, width: r * 2, height: r * 2))
                }
            }
            // expansion joints (drawn across the tile edge so they wrap)
            let joint: CGFloat = max(2, s / 170)
            ctx.setFillColor(color(0.20, 0.20, 0.19, 0.9))
            for i in 0...n {
                let p: CGFloat = CGFloat(i) * cell
                ctx.fill(CGRect(x: p - joint * 0.5, y: 0, width: joint, height: s))
                ctx.fill(CGRect(x: 0, y: p - joint * 0.5, width: s, height: joint))
            }
            ctx.setFillColor(color(1, 1, 1, 0.12))
            for i in 0..<n {
                let p: CGFloat = CGFloat(i) * cell + joint * 0.5
                ctx.fill(CGRect(x: p, y: 0, width: 1, height: s))
                ctx.fill(CGRect(x: 0, y: p, width: s, height: 1))
            }
        }
    }

    // MARK: brick wall

    /// `rows` is rounded up to an even number so the running bond tiles vertically.
    static func brickWall(size: Int = 512, rows: Int = 16, cols: Int = 8, seed: UInt64 = 31) -> UIImage {
        let s: CGFloat = CGFloat(size)
        var rowCount: Int = max(2, rows)
        if rowCount % 2 == 1 { rowCount += 1 }
        let colCount: Int = max(1, cols)
        let bh: CGFloat = s / CGFloat(rowCount)
        let bw: CGFloat = s / CGFloat(colCount)
        return image(size: CGSize(width: s, height: s), opaque: true) { (ctx: CGContext) -> Void in
            var rng: SeededRNG = SeededRNG(seed: seed)
            fill(ctx, CGRect(x: 0, y: 0, width: s, height: s), 0.70, 0.68, 0.64)
            let gap: CGFloat = max(1.5, bh * 0.10)
            for row in 0..<rowCount {
                let shift: CGFloat = (row % 2 == 1) ? -bw * 0.5 : 0
                for col in 0...colCount {
                    let x: CGFloat = CGFloat(col) * bw + shift
                    let y: CGFloat = CGFloat(row) * bh
                    let v: CGFloat = rand(&rng, -0.07, 0.07)
                    let warm: CGFloat = rand(&rng, -0.03, 0.05)
                    let rect: CGRect = CGRect(x: x + gap * 0.5, y: y + gap * 0.5, width: bw - gap, height: bh - gap)
                    fill(ctx, rect, 0.55 + v + warm, 0.26 + v * 0.6, 0.19 + v * 0.5)
                    // top highlight / bottom shade
                    fill(ctx, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1.2), 1, 0.9, 0.85, 0.18)
                    fill(ctx, CGRect(x: rect.minX, y: rect.maxY - 1.5, width: rect.width, height: 1.5), 0, 0, 0, 0.18)
                }
            }
            overlayNoise(s, seed: seed &+ 1, octaves: 5, mode: CGBlendMode.overlay, alpha: 0.7, contrast: 2.0)
            overlayNoise(s, seed: seed &+ 2, octaves: 3, mode: CGBlendMode.softLight, alpha: 0.5)
        }
    }

    // MARK: facades

    enum FacadeStyle {
        case glass       // curtain wall: large reflective glass panes
        case concrete    // punched windows in a concrete grid
        case brick       // punched windows in brick
        case stripes     // continuous ribbon windows
    }

    /// Building facade of `cols` x `rows` windows (row 0 = top floor). `lit: false` = daytime colour map, `lit: true` = matching emissive map
    /// (black wall, some windows glowing warm/cool). The pattern of lit windows depends only on `seed`, so both images line up.
    static func windowFacade(size: CGSize, cols: Int, rows: Int, style: FacadeStyle = .glass, seed: UInt64 = 5, lit: Bool = false) -> UIImage {
        let c: Int = max(1, cols)
        let r: Int = max(1, rows)
        let cw: CGFloat = size.width / CGFloat(c)
        let ch: CGFloat = size.height / CGFloat(r)
        var rngLit: SeededRNG = SeededRNG(seed: seed)
        var rngTone: SeededRNG = SeededRNG(seed: seed &+ 77)
        var litFlags: [Bool] = []
        var warmIndex: [Int] = []
        var tones: [CGFloat] = []
        for _ in 0..<(c * r) {
            litFlags.append(rngLit.float() < 0.42)
            warmIndex.append(rngLit.int(0, 3))
            tones.append(CGFloat(rngTone.float()))
        }
        let warmColours: [[CGFloat]] = [[1.0, 0.86, 0.55], [1.0, 0.93, 0.76], [0.74, 0.88, 1.0], [1.0, 0.72, 0.42]]
        var mx: CGFloat = 0.06
        var my: CGFloat = 0.08
        switch style {
        case .glass: mx = 0.04; my = 0.07
        case .concrete: mx = 0.20; my = 0.22
        case .brick: mx = 0.24; my = 0.20
        case .stripes: mx = 0.0; my = 0.26
        }
        return image(size: size, opaque: true) { (ctx: CGContext) -> Void in
            let full: CGRect = CGRect(origin: CGPoint.zero, size: size)
            if lit {
                fill(ctx, full, 0, 0, 0)
            } else {
                switch style {
                case .glass: fill(ctx, full, 0.12, 0.16, 0.20)
                case .concrete: fill(ctx, full, 0.63, 0.63, 0.61)
                case .brick: fill(ctx, full, 0.52, 0.27, 0.21)
                case .stripes: fill(ctx, full, 0.78, 0.78, 0.76)
                }
                if style != .glass {
                    let m: CGFloat = min(size.width, size.height)
                    let n: UIImage = noise(size: Int(min(m, 512)), seed: seed &+ 5, octaves: 5, contrast: 1.8)
                    n.draw(in: full, blendMode: CGBlendMode.softLight, alpha: 0.7)
                }
            }
            for row in 0..<r {
                for col in 0..<c {
                    let i: Int = row * c + col
                    let cell: CGRect = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch, width: cw, height: ch)
                    var win: CGRect = cell.insetBy(dx: cw * mx, dy: ch * my)
                    if style == .stripes { win = CGRect(x: cell.minX, y: cell.minY + ch * my, width: cw, height: ch * (1 - 2 * my)) }
                    if lit {
                        if litFlags[i] {
                            let w: [CGFloat] = warmColours[warmIndex[i]]
                            let k: CGFloat = 0.75 + tones[i] * 0.25
                            linearGradient(ctx, win, top: [w[0] * k, w[1] * k, w[2] * k], bottom: [w[0] * k * 0.55, w[1] * k * 0.55, w[2] * k * 0.55])
                        }
                    } else {
                        let t: CGFloat = tones[i]
                        if litFlags[i] && !lit {
                            // slightly brighter "lights on" glass in daylight
                            linearGradient(ctx, win, top: [0.42 + t * 0.10, 0.50 + t * 0.10, 0.58 + t * 0.08], bottom: [0.20, 0.26, 0.32])
                        } else {
                            linearGradient(ctx, win, top: [0.45 + t * 0.18, 0.60 + t * 0.15, 0.72 + t * 0.12], bottom: [0.10 + t * 0.05, 0.16 + t * 0.05, 0.22 + t * 0.05])
                        }
                        // frame + sill
                        ctx.setStrokeColor(color(0.06, 0.07, 0.08, 0.9))
                        ctx.setLineWidth(max(1, cw * 0.025))
                        ctx.stroke(win)
                        if style != .glass {
                            fill(ctx, CGRect(x: win.minX - 1, y: win.maxY, width: win.width + 2, height: max(1.5, ch * 0.04)), 0.85, 0.85, 0.82)
                        } else {
                            // mullion cross
                            ctx.setStrokeColor(color(0.05, 0.06, 0.07, 0.55))
                            ctx.setLineWidth(max(1, cw * 0.015))
                            ctx.move(to: CGPoint(x: win.midX, y: win.minY))
                            ctx.addLine(to: CGPoint(x: win.midX, y: win.maxY))
                            ctx.strokePath()
                        }
                    }
                }
            }
        }
    }

    // MARK: roof gravel

    static func roofGravel(size: Int = 512, seed: UInt64 = 41) -> UIImage {
        let s: CGFloat = CGFloat(size)
        return image(size: CGSize(width: s, height: s), opaque: true) { (ctx: CGContext) -> Void in
            var rng: SeededRNG = SeededRNG(seed: seed)
            fill(ctx, CGRect(x: 0, y: 0, width: s, height: s), 0.42, 0.41, 0.40)
            overlayNoise(s, seed: seed &+ 1, octaves: 4, mode: CGBlendMode.overlay, alpha: 0.6)
            let dots: Int = max(400, size * size / 18)
            for _ in 0..<dots {
                let x: CGFloat = rand(&rng, 0, s)
                let y: CGFloat = rand(&rng, 0, s)
                let r: CGFloat = rand(&rng, 0.5, 1.6)
                let g: CGFloat = rand(&rng, 0.18, 0.72)
                forWrapped(x, y, r, s) { (dx: CGFloat, dy: CGFloat) -> Void in
                    ctx.setFillColor(color(g, g * 0.98, g * 0.96, 0.75))
                    ctx.fillEllipse(in: CGRect(x: x + dx - r, y: y + dy - r * 0.8, width: r * 2, height: r * 1.6))
                }
            }
        }
    }

    // MARK: grass

    static func grass(size: Int = 512, seed: UInt64 = 51) -> UIImage {
        let s: CGFloat = CGFloat(size)
        return image(size: CGSize(width: s, height: s), opaque: true) { (ctx: CGContext) -> Void in
            var rng: SeededRNG = SeededRNG(seed: seed)
            fill(ctx, CGRect(x: 0, y: 0, width: s, height: s), 0.20, 0.40, 0.13)
            overlayNoise(s, seed: seed &+ 1, octaves: 3, mode: CGBlendMode.overlay, alpha: 0.8)
            overlayNoise(s, seed: seed &+ 2, octaves: 6, mode: CGBlendMode.softLight, alpha: 0.7, contrast: 2.2)
            ctx.setLineCap(CGLineCap.round)
            let blades: Int = max(300, size * size / 40)
            for _ in 0..<blades {
                let x: CGFloat = rand(&rng, 0, s)
                let y: CGFloat = rand(&rng, 0, s)
                let len: CGFloat = rand(&rng, s / 160, s / 60)
                let lean: CGFloat = rand(&rng, -0.5, 0.5)
                let shade: CGFloat = rand(&rng, 0.0, 1.0)
                let g: CGFloat = 0.30 + shade * 0.35
                forWrapped(x, y, len + 2, s) { (dx: CGFloat, dy: CGFloat) -> Void in
                    ctx.setStrokeColor(color(0.10 + shade * 0.2, g, 0.06 + shade * 0.1, 0.55))
                    ctx.setLineWidth(max(0.6, s / 500))
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: x + dx, y: y + dy))
                    ctx.addLine(to: CGPoint(x: x + dx + lean * len, y: y + dy - len))
                    ctx.strokePath()
                }
            }
        }
    }

    // MARK: wood floor

    /// Horizontal planks (`planks` rows), tileable. Boards have random end joints, grain and colour variation.
    static func woodFloor(size: Int = 512, planks: Int = 8, seed: UInt64 = 61) -> UIImage {
        let s: CGFloat = CGFloat(size)
        let n: Int = max(1, planks)
        let ph: CGFloat = s / CGFloat(n)
        return image(size: CGSize(width: s, height: s), opaque: true) { (ctx: CGContext) -> Void in
            var rng: SeededRNG = SeededRNG(seed: seed)
            fill(ctx, CGRect(x: 0, y: 0, width: s, height: s), 0.22, 0.13, 0.07)
            for row in 0..<n {
                let y: CGFloat = CGFloat(row) * ph
                // split the row into 1...3 boards
                var cuts: [CGFloat] = [0]
                let pieces: Int = rng.int(1, 3)
                if pieces > 1 {
                    var xs: [CGFloat] = []
                    for _ in 0..<(pieces - 1) { xs.append(rand(&rng, s * 0.15, s * 0.85)) }
                    xs.sort()
                    cuts.append(contentsOf: xs)
                }
                cuts.append(s)
                for k in 0..<(cuts.count - 1) {
                    let x0: CGFloat = cuts[k]
                    let x1: CGFloat = cuts[k + 1]
                    let tone: CGFloat = rand(&rng, -0.06, 0.06)
                    let rect: CGRect = CGRect(x: x0 + 1, y: y + 1, width: x1 - x0 - 1, height: ph - 2)
                    fill(ctx, rect, 0.56 + tone, 0.38 + tone * 0.8, 0.22 + tone * 0.5)
                    // grain
                    ctx.saveGState()
                    ctx.clip(to: rect)
                    let lines: Int = Int(ph / 3)
                    for _ in 0..<max(3, lines) {
                        let gy: CGFloat = rand(&rng, rect.minY, rect.maxY)
                        let amp: CGFloat = rand(&rng, 0.3, 1.6)
                        let phase: CGFloat = rand(&rng, 0, 6.28)
                        let dark: Bool = rng.chance(0.7)
                        ctx.setStrokeColor(dark ? color(0.25, 0.13, 0.06, 0.28) : color(0.80, 0.60, 0.38, 0.18))
                        ctx.setLineWidth(rand(&rng, 0.5, 1.2))
                        ctx.beginPath()
                        ctx.move(to: CGPoint(x: rect.minX, y: gy))
                        var gx: CGFloat = rect.minX
                        while gx < rect.maxX {
                            gx += 12
                            ctx.addLine(to: CGPoint(x: gx, y: gy + sin(gx * 0.03 + phase) * amp))
                        }
                        ctx.strokePath()
                    }
                    ctx.restoreGState()
                    // end joint shadow
                    fill(ctx, CGRect(x: x0, y: y, width: 1.5, height: ph), 0.08, 0.04, 0.02, 0.7)
                }
                fill(ctx, CGRect(x: 0, y: y, width: s, height: 1.5), 0.08, 0.04, 0.02, 0.7)
            }
            overlayNoise(s, seed: seed &+ 1, octaves: 4, mode: CGBlendMode.softLight, alpha: 0.5)
        }
    }

    // MARK: road markings atlas

    /// 4 x 4 grid of markings on a transparent background (cells are size/4 square, arrows point UP = along the direction of travel).
    enum RoadMarking: Int, CaseIterable {
        case whiteDash = 0, whiteSolid, yellowSolid, yellowDouble
        case yellowDash, crosswalk, stopLine, edgeLine
        case arrowStraight, arrowLeft, arrowRight, arrowStraightLeft
        case parkingBay, chevron, bikeLane, blank
    }

    /// UV rectangle of a marking in the atlas (SceneKit convention: v = 1 at the top of the image), shrunk by `inset` to avoid bleeding.
    static func atlasRect(_ m: RoadMarking, inset: Float = 0.004) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        let col: Int = m.rawValue % 4
        let row: Int = m.rawValue / 4
        let u0: Float = Float(col) / 4 + inset
        let u1: Float = Float(col + 1) / 4 - inset
        let v1: Float = 1 - Float(row) / 4 - inset
        let v0: Float = 1 - Float(row + 1) / 4 + inset
        return (u0, v0, u1, v1)
    }

    static func roadMarkingsAtlas(size: Int = 1024) -> UIImage {
        let s: CGFloat = CGFloat(size)
        let c: CGFloat = s / 4
        return image(size: CGSize(width: s, height: s), opaque: false) { (ctx: CGContext) -> Void in
            var rng: SeededRNG = SeededRNG(seed: 77)
            func cellRect(_ m: RoadMarking) -> CGRect {
                return CGRect(x: CGFloat(m.rawValue % 4) * c, y: CGFloat(m.rawValue / 4) * c, width: c, height: c)
            }
            func bar(_ m: RoadMarking, _ cx: CGFloat, _ w: CGFloat, _ y0: CGFloat, _ y1: CGFloat, _ col: [CGFloat]) {
                let r: CGRect = cellRect(m)
                ctx.setFillColor(color(col[0], col[1], col[2], 1))
                ctx.fill(CGRect(x: r.minX + cx * c - w * c * 0.5, y: r.minY + y0 * c, width: w * c, height: (y1 - y0) * c))
            }
            func poly(_ m: RoadMarking, _ pts: [CGPoint], _ col: [CGFloat]) {
                let r: CGRect = cellRect(m)
                ctx.setFillColor(color(col[0], col[1], col[2], 1))
                ctx.beginPath()
                for (i, p) in pts.enumerated() {
                    let q: CGPoint = CGPoint(x: r.minX + p.x * c, y: r.minY + p.y * c)
                    if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
                }
                ctx.closePath()
                ctx.fillPath()
            }
            let white: [CGFloat] = [0.95, 0.95, 0.93]
            let yellow: [CGFloat] = [0.96, 0.78, 0.10]
            bar(.whiteDash, 0.5, 0.10, 0.2, 0.8, white)
            bar(.whiteSolid, 0.5, 0.10, 0.0, 1.0, white)
            bar(.yellowSolid, 0.5, 0.10, 0.0, 1.0, yellow)
            bar(.yellowDouble, 0.42, 0.07, 0.0, 1.0, yellow)
            bar(.yellowDouble, 0.58, 0.07, 0.0, 1.0, yellow)
            bar(.yellowDash, 0.5, 0.10, 0.2, 0.8, yellow)
            for i in 0..<5 { bar(.crosswalk, 0.1 + 0.2 * CGFloat(i), 0.11, 0.0, 1.0, white) }
            bar(.stopLine, 0.5, 1.0, 0.38, 0.62, white)
            bar(.edgeLine, 0.5, 0.06, 0.0, 1.0, white)
            for m in [RoadMarking.arrowStraight, RoadMarking.arrowLeft, RoadMarking.arrowRight, RoadMarking.arrowStraightLeft] {
                bar(m, 0.5, 0.12, 0.42, 0.92, white)
                poly(m, [CGPoint(x: 0.5, y: 0.06), CGPoint(x: 0.72, y: 0.42), CGPoint(x: 0.28, y: 0.42)], white)
            }
            // side arrows
            poly(.arrowLeft, [CGPoint(x: 0.5, y: 0.66), CGPoint(x: 0.5, y: 0.52), CGPoint(x: 0.1, y: 0.40), CGPoint(x: 0.1, y: 0.28),
                              CGPoint(x: 0.02, y: 0.40), CGPoint(x: 0.1, y: 0.52)], white)
            poly(.arrowRight, [CGPoint(x: 0.5, y: 0.66), CGPoint(x: 0.5, y: 0.52), CGPoint(x: 0.9, y: 0.40), CGPoint(x: 0.9, y: 0.28),
                               CGPoint(x: 0.98, y: 0.40), CGPoint(x: 0.9, y: 0.52)], white)
            poly(.arrowStraightLeft, [CGPoint(x: 0.5, y: 0.7), CGPoint(x: 0.5, y: 0.58), CGPoint(x: 0.14, y: 0.46), CGPoint(x: 0.14, y: 0.34),
                                      CGPoint(x: 0.06, y: 0.46), CGPoint(x: 0.14, y: 0.58)], white)
            // parking bay: U shape
            bar(.parkingBay, 0.08, 0.06, 0.1, 0.9, white)
            bar(.parkingBay, 0.92, 0.06, 0.1, 0.9, white)
            bar(.parkingBay, 0.5, 0.84, 0.84, 0.90, white)
            // chevron
            poly(.chevron, [CGPoint(x: 0.5, y: 0.15), CGPoint(x: 0.95, y: 0.55), CGPoint(x: 0.95, y: 0.75), CGPoint(x: 0.5, y: 0.35),
                            CGPoint(x: 0.05, y: 0.75), CGPoint(x: 0.05, y: 0.55)], white)
            // bike lane: green-ish outline square with a bar
            bar(.bikeLane, 0.5, 0.86, 0.12, 0.20, white)
            bar(.bikeLane, 0.5, 0.86, 0.80, 0.88, white)
            bar(.bikeLane, 0.5, 0.10, 0.30, 0.70, white)
            // wear: erase random specks
            ctx.setBlendMode(CGBlendMode.clear)
            let specks: Int = max(200, size * size / 600)
            for _ in 0..<specks {
                let x: CGFloat = rand(&rng, 0, s)
                let y: CGFloat = rand(&rng, 0, s)
                let r: CGFloat = rand(&rng, 0.6, 2.2)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            ctx.setBlendMode(CGBlendMode.normal)
        }
    }
}
