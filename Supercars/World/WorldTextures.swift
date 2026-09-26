import Foundation
import UIKit
import CoreGraphics

// MARK: - Procedural textures (own helpers so the World module does not depend on the assets team's ProceduralTextures)

enum WTex {
    // MARK: noise

    static func vnoise(_ x: Float, _ y: Float, _ period: Int, _ seed: Int) -> Float {
        let fx = floorf(x)
        let fy = floorf(y)
        let xi = Int(fx)
        let yi = Int(fy)
        let tx = x - fx
        let ty = y - fy
        let x0 = ((xi % period) + period) % period
        let y0 = ((yi % period) + period) % period
        let x1 = (x0 + 1) % period
        let y1 = (y0 + 1) % period
        let a = wHash01(x0, y0, seed)
        let b = wHash01(x1, y0, seed)
        let c = wHash01(x0, y1, seed)
        let d = wHash01(x1, y1, seed)
        let sx = tx * tx * (3 - 2 * tx)
        let sy = ty * ty * (3 - 2 * ty)
        let top = a + (b - a) * sx
        let bot = c + (d - c) * sx
        return top + (bot - top) * sy
    }

    /// tileable fractal noise; u,v in 0..1 over the whole tile
    static func fbm(_ u: Float, _ v: Float, _ basePeriod: Int, _ octaves: Int, _ seed: Int) -> Float {
        var sum: Float = 0
        var amp: Float = 0.5
        var norm: Float = 0
        var period = basePeriod
        for o in 0..<octaves {
            sum += amp * vnoise(u * Float(period), v * Float(period), period, seed + o * 17)
            norm += amp
            amp *= 0.5
            period *= 2
        }
        return sum / max(norm, 0.001)
    }

    // MARK: image plumbing

    static func render(_ w: Int, _ h: Int, opaque: Bool, _ draw: (CGContext) -> Void) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = opaque
        let r = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt)
        return r.image { rc in
            draw(rc.cgContext)
        }
    }

    static func imageFromPixels(_ pixels: [UInt8], _ w: Int, _ h: Int, hasAlpha: Bool) -> UIImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return UIImage() }
        let info: CGBitmapInfo = hasAlpha
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                               bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: CGColorRenderingIntent.defaultIntent) else {
            return UIImage()
        }
        return UIImage(cgImage: cg)
    }

    static func byte(_ f: Float) -> UInt8 {
        let v = Int(clampf(f, 0, 1) * 255 + 0.5)
        return UInt8(v)
    }

    /// Opaque per-pixel generated texture. `fn(u, v, x, y)` returns rgb in 0...1.
    static func pixelTexture(_ size: Int, _ fn: (Float, Float, Int, Int) -> Vec3) -> UIImage {
        var px = [UInt8](repeating: 255, count: size * size * 4)
        let inv: Float = 1.0 / Float(size)
        for y in 0..<size {
            for x in 0..<size {
                let c = fn(Float(x) * inv, Float(y) * inv, x, y)
                let o = (y * size + x) * 4
                px[o] = byte(c.x)
                px[o + 1] = byte(c.y)
                px[o + 2] = byte(c.z)
                px[o + 3] = 255
            }
        }
        return imageFromPixels(px, size, size, hasAlpha: false)
    }

    static func col(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> CGColor {
        return UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)).cgColor
    }

    static func lin(_ ctx: CGContext, _ c0: CGColor, _ c1: CGColor, from: CGPoint, to: CGPoint) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors: [CGColor] = [c0, c1]
        let locs: [CGFloat] = [0, 1]
        if let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) {
            ctx.drawLinearGradient(g, start: from, end: to, options: [])
        }
    }

    static func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, stops: [(CGFloat, CGColor)]) {
        let cs = CGColorSpaceCreateDeviceRGB()
        var colors: [CGColor] = []
        var locs: [CGFloat] = []
        for s in stops { locs.append(s.0); colors.append(s.1) }
        if let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }

    // MARK: ground textures

    static func asphalt() -> UIImage {
        let size = 512
        let base = pixelTexture(size) { u, v, x, y in
            let n1 = fbm(u, v, 6, 3, 11)
            let n2 = fbm(u, v, 3, 2, 91)
            let grain = wHash01(x, y, 5)
            var g: Float = 0.19 + n1 * 0.05 + (n2 - 0.5) * 0.03 + (grain - 0.5) * 0.05
            if grain > 0.985 { g += 0.10 }
            if n2 > 0.63 { g -= 0.025 }
            return Vec3(g, g * 1.0, g * 1.03)
        }
        return render(size, size, opaque: true) { c in
            base.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
            var rng = SeededRNG(seed: 777)
            // hairline cracks (wrapped)
            for _ in 0..<14 {
                var px = CGFloat(rng.float(0, Float(size)))
                var py = CGFloat(rng.float(0, Float(size)))
                var ang = CGFloat(rng.float(0, Float.tau))
                c.setStrokeColor(col(0.06, 0.06, 0.07, 0.55))
                c.setLineWidth(CGFloat(rng.float(0.8, 1.6)))
                c.beginPath()
                c.move(to: CGPoint(x: px, y: py))
                for _ in 0..<18 {
                    ang += CGFloat(rng.float(-0.6, 0.6))
                    px += cos(ang) * 9
                    py += sin(ang) * 9
                    c.addLine(to: CGPoint(x: px, y: py))
                }
                c.strokePath()
            }
            // oil stains
            for _ in 0..<7 {
                let cx = CGFloat(rng.float(0, Float(size)))
                let cy = CGFloat(rng.float(0, Float(size)))
                let r = CGFloat(rng.float(8, 26))
                radial(c, center: CGPoint(x: cx, y: cy), radius: r, stops: [(0, col(0.04, 0.04, 0.05, 0.4)), (1, col(0.04, 0.04, 0.05, 0))])
            }
            // repair patches
            for _ in 0..<4 {
                let rect = CGRect(x: CGFloat(rng.float(0, Float(size) - 90)), y: CGFloat(rng.float(0, Float(size) - 90)),
                                  width: CGFloat(rng.float(40, 90)), height: CGFloat(rng.float(30, 80)))
                c.setFillColor(col(0.12, 0.12, 0.13, 0.5))
                c.fill(rect)
            }
        }
    }

    static func ground() -> UIImage {
        let size = 512
        return pixelTexture(size) { u, v, x, y in
            let n = fbm(u, v, 4, 4, 33)
            let m = fbm(u, v, 9, 3, 71)
            let grain = wHash01(x, y, 9)
            let dry = smoothstep(0.35, 0.65, m)
            let grassC = Vec3(0.24, 0.34, 0.14)
            let dirtC = Vec3(0.40, 0.33, 0.22)
            var c = wMixVec3(grassC, dirtC, dry * 0.75)
            c = c * (0.82 + n * 0.32 + (grain - 0.5) * 0.10)
            return c
        }
    }

    static func lawn() -> UIImage {
        let size = 512
        return pixelTexture(size) { u, v, x, y in
            let n = fbm(u, v, 5, 3, 21)
            let grain = wHash01(x, y, 3)
            let blade = wHash01(x / 2, y / 3, 8)
            let base = Vec3(0.17, 0.36, 0.10)
            var c = base * (0.75 + n * 0.5)
            c.y += (grain - 0.5) * 0.08 + (blade - 0.5) * 0.05
            c.x += (blade - 0.5) * 0.03
            return c
        }
    }

    static func concrete(seed: Int, tone: Float) -> UIImage {
        let size = 256
        return pixelTexture(size) { u, v, x, y in
            let n = fbm(u, v, 5, 3, seed)
            let grain = wHash01(x, y, seed + 4)
            let g = tone + (n - 0.5) * 0.10 + (grain - 0.5) * 0.05
            return Vec3(g, g * 0.99, g * 0.96)
        }
    }

    static func pave() -> UIImage {
        let size = 512
        return pixelTexture(size) { u, v, x, y in
            let n = fbm(u, v, 6, 3, 61)
            let grain = wHash01(x, y, 12)
            var g: Float = 0.42 + (n - 0.5) * 0.12 + (grain - 0.5) * 0.05
            let jx = x % 128
            let jy = y % 128
            if jx < 2 || jy < 2 { g -= 0.09 }
            return Vec3(g, g * 0.99, g * 0.95)
        }
    }

    static func roofGravel() -> UIImage {
        let size = 256
        return pixelTexture(size) { u, v, x, y in
            let n = fbm(u, v, 8, 3, 15)
            let grain = wHash01(x, y, 2)
            let g: Float = 0.30 + (n - 0.5) * 0.10 + (grain - 0.5) * 0.14
            return Vec3(g, g * 0.98, g * 0.95)
        }
    }

    static func water() -> UIImage {
        let size = 256
        return pixelTexture(size) { u, v, x, y in
            let n = fbm(u, v, 5, 3, 44)
            let r = fbm(u * 3, v * 3, 12, 2, 55)
            let k: Float = 0.5 + (n - 0.5) * 0.5 + (r - 0.5) * 0.25
            return Vec3(0.06 + k * 0.08, 0.20 + k * 0.16, 0.26 + k * 0.18)
        }
    }

    static func pavers() -> UIImage {
        let size = 512
        return render(size, size, opaque: true) { c in
            c.setFillColor(col(0.42, 0.41, 0.40))
            c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let n = 8
            let cell = size / n
            for r in 0..<n {
                for k in 0..<n {
                    let h1 = wHash01(r, k, 101)
                    let h2 = wHash01(r, k, 202)
                    let g: Float = 0.62 + h1 * 0.14
                    let warm: Float = (h2 - 0.5) * 0.06
                    c.setFillColor(col(g + warm, g, g - warm))
                    let rect = CGRect(x: k * cell + 2, y: r * cell + 2, width: cell - 4, height: cell - 4)
                    c.fill(rect)
                    // subtle speckle
                    c.setFillColor(col(g - 0.10, g - 0.10, g - 0.10, 0.35))
                    for s in 0..<6 {
                        let sx = CGFloat(k * cell + 6) + CGFloat(wHash01(r * 9 + s, k, 5)) * CGFloat(cell - 12)
                        let sy = CGFloat(r * cell + 6) + CGFloat(wHash01(r, k * 9 + s, 6)) * CGFloat(cell - 12)
                        c.fill(CGRect(x: sx, y: sy, width: 2, height: 2))
                    }
                }
            }
        }
    }

    static func plaza() -> UIImage {
        let size = 512
        return render(size, size, opaque: true) { c in
            c.setFillColor(col(0.35, 0.34, 0.33))
            c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let n = 4
            let cell = size / n
            for r in 0..<n {
                for k in 0..<n {
                    let dark = (r + k) % 2 == 0
                    let h = wHash01(r, k, 303)
                    let g: Float = dark ? 0.50 + h * 0.06 : 0.70 + h * 0.06
                    c.setFillColor(col(g, g * 0.98, g * 0.94))
                    c.fill(CGRect(x: k * cell + 3, y: r * cell + 3, width: cell - 6, height: cell - 6))
                }
            }
        }
    }

    static func roofTile(r: Float, g: Float, b: Float) -> UIImage {
        let size = 256
        return render(size, size, opaque: true) { c in
            c.setFillColor(col(r * 0.6, g * 0.6, b * 0.6))
            c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let rows = 16
            let rh = size / rows
            for row in 0..<rows {
                let cols = 12
                let cw = size / cols
                for k in 0..<cols {
                    let h = wHash01(row, k, 404)
                    let f: Float = 0.85 + h * 0.3
                    c.setFillColor(col(r * f, g * f, b * f))
                    let off = (row % 2 == 0) ? 0 : cw / 2
                    c.fill(CGRect(x: k * cw + off + 1, y: row * rh, width: cw - 2, height: rh - 1))
                }
            }
        }
    }

    // MARK: decals

    static func manhole() -> UIImage {
        return render(128, 128, opaque: false) { c in
            c.clear(CGRect(x: 0, y: 0, width: 128, height: 128))
            c.setFillColor(col(0.10, 0.10, 0.11, 0.95))
            c.fillEllipse(in: CGRect(x: 6, y: 6, width: 116, height: 116))
            c.setStrokeColor(col(0.28, 0.28, 0.30, 1))
            c.setLineWidth(5)
            c.strokeEllipse(in: CGRect(x: 12, y: 12, width: 104, height: 104))
            c.setLineWidth(3)
            c.setStrokeColor(col(0.20, 0.20, 0.22, 1))
            for i in 0..<7 {
                let y = CGFloat(30 + i * 11)
                c.move(to: CGPoint(x: 26, y: y))
                c.addLine(to: CGPoint(x: 102, y: y))
            }
            c.strokePath()
        }
    }

    static func lightPool() -> UIImage {
        return render(128, 128, opaque: false) { c in
            c.clear(CGRect(x: 0, y: 0, width: 128, height: 128))
            radial(c, center: CGPoint(x: 64, y: 64), radius: 64, stops: [
                (0, col(1.0, 0.86, 0.55, 0.55)),
                (0.45, col(1.0, 0.80, 0.45, 0.22)),
                (1, col(1.0, 0.75, 0.40, 0.0))
            ])
        }
    }

    // MARK: props atlas (8 x 8 cells of 64 px; row 0 is the top of the image)

    static func atlasCellUV(_ cell: Int) -> (u: Float, v: Float) {
        let col = cell % 8
        let row = cell / 8
        return ((Float(col) + 0.5) / 8, 1 - (Float(row) + 0.5) / 8)
    }

    /// uv rectangle of a cell (u0, v0 bottom, u1, v1 top) inset by a texel
    static func atlasCellRect(_ cell: Int) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        let col = cell % 8
        let row = cell / 8
        let e: Float = 1.0 / 512
        let u0 = Float(col) / 8 + e
        let u1 = Float(col + 1) / 8 - e
        let v1 = 1 - Float(row) / 8 - e
        let v0 = 1 - Float(row + 1) / 8 + e
        return (u0, v0, u1, v1)
    }

    static let atlasColors: [Int: (Float, Float, Float)] = [
        0: (0.23, 0.24, 0.26), 1: (0.36, 0.38, 0.41), 2: (1.0, 0.92, 0.75), 3: (0.55, 0.36, 0.18),
        4: (0.18, 0.36, 0.22), 5: (0.72, 0.12, 0.16), 6: (0.85, 0.70, 0.10), 7: (0.60, 0.60, 0.58),
        8: (0.06, 0.06, 0.07), 9: (1.0, 0.10, 0.08), 10: (1.0, 0.65, 0.05), 11: (0.10, 1.0, 0.35),
        12: (0.45, 0.65, 0.72), 13: (0.92, 0.92, 0.90), 14: (0.20, 0.20, 0.22), 15: (0.14, 0.32, 0.10),
        24: (0.85, 0.12, 0.14), 25: (0.95, 0.80, 0.15), 26: (0.92, 0.45, 0.65), 27: (0.55, 0.30, 0.80),
        28: (0.95, 0.95, 0.95), 29: (0.95, 0.50, 0.12), 30: (0.30, 0.20, 0.10), 31: (0.35, 0.50, 0.18)
    ]

    static func propsAtlas() -> UIImage {
        return render(512, 512, opaque: true) { c in
            c.setFillColor(col(0.5, 0.5, 0.5))
            c.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            for (cell, rgb) in atlasColors {
                let x = CGFloat((cell % 8) * 64)
                let y = CGFloat((cell / 8) * 64)
                c.setFillColor(col(rgb.0, rgb.1, rgb.2))
                c.fill(CGRect(x: x, y: y, width: 64, height: 64))
            }
            // sign faces: row 2 (cells 16...23)
            for s in 0..<8 {
                let x = CGFloat(s * 64)
                let y = CGFloat(2 * 64)
                drawSignFace(c, s, CGRect(x: x, y: y, width: 64, height: 64))
            }
        }
    }

    private static func drawText(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let str = text as NSString
        let h = str.size(withAttributes: attrs).height
        let r = CGRect(x: rect.minX, y: rect.minY + (rect.height - h) * 0.5, width: rect.width, height: h)
        str.draw(in: r, withAttributes: attrs)
    }

    private static func drawSignFace(_ c: CGContext, _ kind: Int, _ r: CGRect) {
        c.saveGState()
        c.clip(to: r)
        switch kind {
        case 0: // stop
            c.setFillColor(col(0.75, 0.08, 0.10))
            c.fill(r)
            c.setStrokeColor(col(1, 1, 1))
            c.setLineWidth(3)
            c.stroke(r.insetBy(dx: 4, dy: 4))
            drawText("STOP", in: r, size: 17, color: UIColor.white)
        case 1: // speed limit
            c.setFillColor(col(0.95, 0.95, 0.95))
            c.fill(r)
            c.setStrokeColor(col(0.85, 0.1, 0.1))
            c.setLineWidth(6)
            c.strokeEllipse(in: r.insetBy(dx: 6, dy: 6))
            drawText("50", in: r, size: 26, color: UIColor.black)
        case 2: // street name
            c.setFillColor(col(0.06, 0.28, 0.55))
            c.fill(r)
            c.setStrokeColor(col(1, 1, 1))
            c.setLineWidth(2)
            c.stroke(r.insetBy(dx: 3, dy: 3))
            drawText("MAIN ST", in: r, size: 13, color: UIColor.white)
        case 3: // one way
            c.setFillColor(col(0.05, 0.05, 0.06))
            c.fill(r)
            c.setFillColor(col(1, 1, 1))
            c.fill(CGRect(x: r.minX + 8, y: r.midY - 8, width: 40, height: 16))
            c.move(to: CGPoint(x: r.minX + 46, y: r.midY - 18))
            c.addLine(to: CGPoint(x: r.maxX - 5, y: r.midY))
            c.addLine(to: CGPoint(x: r.minX + 46, y: r.midY + 18))
            c.fillPath()
        case 4: // no parking
            c.setFillColor(col(0.12, 0.30, 0.75))
            c.fill(r)
            c.setStrokeColor(col(0.85, 0.1, 0.1))
            c.setLineWidth(5)
            c.strokeEllipse(in: r.insetBy(dx: 8, dy: 8))
            drawText("P", in: r, size: 28, color: UIColor.white)
        case 5: // yield
            c.setFillColor(col(0.95, 0.95, 0.95))
            c.fill(r)
            c.setFillColor(col(0.85, 0.1, 0.1))
            c.move(to: CGPoint(x: r.minX + 6, y: r.minY + 10))
            c.addLine(to: CGPoint(x: r.maxX - 6, y: r.minY + 10))
            c.addLine(to: CGPoint(x: r.midX, y: r.maxY - 8))
            c.fillPath()
        case 6: // pedestrian crossing
            c.setFillColor(col(0.95, 0.80, 0.10))
            c.fill(r)
            c.setFillColor(col(0.05, 0.05, 0.05))
            c.fillEllipse(in: CGRect(x: r.midX - 5, y: r.minY + 10, width: 10, height: 10))
            c.fill(CGRect(x: r.midX - 5, y: r.minY + 22, width: 10, height: 22))
        default: // parking
            c.setFillColor(col(0.12, 0.30, 0.75))
            c.fill(r)
            drawText("P", in: r, size: 40, color: UIColor.white)
        }
        c.restoreGState()
    }

    /// emission atlas: 0 = lamp glow only, 1 = traffic lights only
    static func propsEmission(kind: Int) -> UIImage {
        return render(512, 512, opaque: true) { c in
            c.setFillColor(col(0, 0, 0))
            c.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            var cells: [Int] = []
            if kind == 0 { cells = [2] } else { cells = [9, 10, 11] }
            for cell in cells {
                if let rgb = atlasColors[cell] {
                    let x = CGFloat((cell % 8) * 64)
                    let y = CGFloat((cell / 8) * 64)
                    c.setFillColor(col(rgb.0, rgb.1, rgb.2))
                    c.fill(CGRect(x: x, y: y, width: 64, height: 64))
                }
            }
        }
    }
}
