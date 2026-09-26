import Foundation
import UIKit
import CoreGraphics

// MARK: - Facade textures: curtain wall / ribbon / punched windows with mullions, reflections and per-building lit patterns

struct WFacadeStyle {
    let kind: Int            // 0 curtain wall, 1 ribbon windows, 2 punched (brick), 3 punched (stucco), 4 punched (stone)
    let wall: Vec3
    let frame: Vec3
    let glassTop: Vec3
    let glassBottom: Vec3
    let spandrel: Vec3
    let litProbability: Float
    let pbr: Bool
    let metalness: Float
    let roughness: Float
}

enum WFacades {
    static let cells: Int = 8                 // cells per tile edge (bays x floors)
    static let bayWidth: Float = 3.6
    static let floorHeight: Float = 3.6
    static var tileWidth: Float { return bayWidth * Float(cells) }
    static var tileHeight: Float { return floorHeight * Float(cells) }

    static let styles: [WFacadeStyle] = [
        WFacadeStyle(kind: 0, wall: Vec3(0.12, 0.22, 0.32), frame: Vec3(0.55, 0.60, 0.66), glassTop: Vec3(0.50, 0.70, 0.88),
                     glassBottom: Vec3(0.10, 0.20, 0.32), spandrel: Vec3(0.10, 0.16, 0.23), litProbability: 0.34, pbr: true, metalness: 0.25, roughness: 0.22),
        WFacadeStyle(kind: 0, wall: Vec3(0.10, 0.26, 0.24), frame: Vec3(0.60, 0.64, 0.62), glassTop: Vec3(0.52, 0.82, 0.76),
                     glassBottom: Vec3(0.07, 0.22, 0.20), spandrel: Vec3(0.09, 0.20, 0.18), litProbability: 0.30, pbr: true, metalness: 0.25, roughness: 0.22),
        WFacadeStyle(kind: 0, wall: Vec3(0.06, 0.07, 0.09), frame: Vec3(0.20, 0.21, 0.24), glassTop: Vec3(0.32, 0.38, 0.48),
                     glassBottom: Vec3(0.03, 0.04, 0.06), spandrel: Vec3(0.05, 0.06, 0.08), litProbability: 0.40, pbr: true, metalness: 0.35, roughness: 0.18),
        WFacadeStyle(kind: 1, wall: Vec3(0.72, 0.71, 0.68), frame: Vec3(0.30, 0.32, 0.34), glassTop: Vec3(0.52, 0.64, 0.74),
                     glassBottom: Vec3(0.12, 0.16, 0.22), spandrel: Vec3(0.66, 0.65, 0.62), litProbability: 0.36, pbr: false, metalness: 0, roughness: 0.6),
        WFacadeStyle(kind: 2, wall: Vec3(0.55, 0.25, 0.18), frame: Vec3(0.92, 0.90, 0.85), glassTop: Vec3(0.40, 0.52, 0.62),
                     glassBottom: Vec3(0.08, 0.10, 0.14), spandrel: Vec3(0.50, 0.22, 0.16), litProbability: 0.38, pbr: false, metalness: 0, roughness: 0.8),
        WFacadeStyle(kind: 3, wall: Vec3(0.86, 0.80, 0.68), frame: Vec3(0.95, 0.94, 0.90), glassTop: Vec3(0.42, 0.55, 0.66),
                     glassBottom: Vec3(0.10, 0.12, 0.16), spandrel: Vec3(0.80, 0.74, 0.62), litProbability: 0.40, pbr: false, metalness: 0, roughness: 0.9),
        WFacadeStyle(kind: 4, wall: Vec3(0.78, 0.72, 0.60), frame: Vec3(0.60, 0.56, 0.48), glassTop: Vec3(0.40, 0.52, 0.64),
                     glassBottom: Vec3(0.08, 0.10, 0.14), spandrel: Vec3(0.72, 0.66, 0.54), litProbability: 0.36, pbr: false, metalness: 0, roughness: 0.85)
    ]

    private static func windowRect(_ kind: Int, _ x: CGFloat, _ y: CGFloat, _ cs: CGFloat) -> CGRect {
        switch kind {
        case 0:
            return CGRect(x: x, y: y, width: cs, height: cs * 0.78)
        case 1:
            return CGRect(x: x, y: y + cs * 0.22, width: cs, height: cs * 0.50)
        default:
            return CGRect(x: x + cs * 0.22, y: y + cs * 0.20, width: cs * 0.56, height: cs * 0.60)
        }
    }

    private static func c(_ v: Vec3, _ a: Float = 1) -> CGColor { return WTex.col(v.x, v.y, v.z, a) }

    static func diffuse(style: Int, size: Int = 1024) -> UIImage {
        let st = styles[style % styles.count]
        let cs = CGFloat(size / cells)
        return WTex.render(size, size, opaque: true) { g in
            g.setFillColor(c(st.wall))
            g.fill(CGRect(x: 0, y: 0, width: size, height: size))
            // wall texture
            if st.kind == 2 {
                let bh = CGFloat(size) / 128
                for row in 0..<128 {
                    let y = CGFloat(row) * bh
                    let shade: Float = 0.9 + wHash01(row, 1, 5) * 0.2
                    g.setFillColor(c(st.wall * shade, 0.35))
                    g.fill(CGRect(x: 0, y: y, width: CGFloat(size), height: bh - 1))
                    g.setStrokeColor(c(Vec3(0.75, 0.72, 0.68), 0.5))
                    g.setLineWidth(1)
                    g.move(to: CGPoint(x: 0, y: y + bh - 0.5))
                    g.addLine(to: CGPoint(x: CGFloat(size), y: y + bh - 0.5))
                    let off: CGFloat = (row % 2 == 0) ? 0 : bh * 2
                    var x = off
                    while x < CGFloat(size) {
                        g.move(to: CGPoint(x: x, y: y))
                        g.addLine(to: CGPoint(x: x, y: y + bh))
                        x += bh * 4
                    }
                    g.strokePath()
                }
            } else if st.kind >= 3 || st.kind == 1 {
                for i in 0..<2600 {
                    let px = CGFloat(wHash01(i, 3, 41)) * CGFloat(size)
                    let py = CGFloat(wHash01(i, 7, 42)) * CGFloat(size)
                    let d = wHash01(i, 9, 43)
                    let tone: Float = d > 0.5 ? 1.08 : 0.9
                    g.setFillColor(c(st.wall * tone, 0.35))
                    g.fill(CGRect(x: px, y: py, width: 3, height: 3))
                }
            }
            for r in 0..<cells {
                for k in 0..<cells {
                    let x = CGFloat(k) * cs
                    let y = CGFloat(r) * cs
                    let wr = windowRect(st.kind, x, y, cs)
                    let jitter: Float = 0.9 + wHash01(r, k, 55 + style) * 0.2
                    if st.kind == 0 {
                        // spandrel band under the glass
                        g.setFillColor(c(st.spandrel))
                        g.fill(CGRect(x: x, y: y + cs * 0.78, width: cs, height: cs * 0.22))
                    }
                    // glass with reflection gradient
                    g.saveGState()
                    g.clip(to: wr)
                    WTex.lin(g, c(st.glassTop * jitter), c(st.glassBottom * jitter), from: CGPoint(x: wr.minX, y: wr.minY), to: CGPoint(x: wr.minX, y: wr.maxY))
                    if wHash01(r, k, 77) > 0.55 {
                        g.setFillColor(WTex.col(1, 1, 1, 0.16))
                        g.move(to: CGPoint(x: wr.minX + wr.width * 0.2, y: wr.minY))
                        g.addLine(to: CGPoint(x: wr.minX + wr.width * 0.55, y: wr.minY))
                        g.addLine(to: CGPoint(x: wr.minX + wr.width * 0.15, y: wr.maxY))
                        g.addLine(to: CGPoint(x: wr.minX - wr.width * 0.2, y: wr.maxY))
                        g.fillPath()
                    }
                    g.restoreGState()
                    // frame / mullions
                    g.setStrokeColor(c(st.frame))
                    if st.kind == 0 {
                        g.setLineWidth(cs * 0.035)
                        g.stroke(wr)
                        g.setLineWidth(cs * 0.02)
                        g.move(to: CGPoint(x: wr.midX, y: wr.minY))
                        g.addLine(to: CGPoint(x: wr.midX, y: wr.maxY))
                        g.strokePath()
                    } else if st.kind == 1 {
                        g.setLineWidth(cs * 0.04)
                        g.stroke(wr)
                        g.setLineWidth(cs * 0.025)
                        g.move(to: CGPoint(x: wr.minX + wr.width * 0.33, y: wr.minY))
                        g.addLine(to: CGPoint(x: wr.minX + wr.width * 0.33, y: wr.maxY))
                        g.move(to: CGPoint(x: wr.minX + wr.width * 0.66, y: wr.minY))
                        g.addLine(to: CGPoint(x: wr.minX + wr.width * 0.66, y: wr.maxY))
                        g.strokePath()
                        // slab edge shadow
                        g.setFillColor(WTex.col(0, 0, 0, 0.18))
                        g.fill(CGRect(x: x, y: wr.maxY, width: cs, height: cs * 0.05))
                    } else {
                        g.setLineWidth(cs * 0.045)
                        g.stroke(wr)
                        g.setLineWidth(cs * 0.025)
                        g.move(to: CGPoint(x: wr.midX, y: wr.minY))
                        g.addLine(to: CGPoint(x: wr.midX, y: wr.maxY))
                        g.move(to: CGPoint(x: wr.minX, y: wr.minY + wr.height * 0.4))
                        g.addLine(to: CGPoint(x: wr.maxX, y: wr.minY + wr.height * 0.4))
                        g.strokePath()
                        // sill and lintel
                        g.setFillColor(c(st.frame))
                        g.fill(CGRect(x: wr.minX - cs * 0.03, y: wr.maxY, width: wr.width + cs * 0.06, height: cs * 0.05))
                        g.setFillColor(WTex.col(0, 0, 0, 0.28))
                        g.fill(CGRect(x: wr.minX, y: wr.minY - cs * 0.04, width: wr.width, height: cs * 0.04))
                        if st.kind == 3 {
                            g.setFillColor(c(Vec3(0.20, 0.30, 0.25)))
                            g.fill(CGRect(x: wr.minX - cs * 0.10, y: wr.minY, width: cs * 0.08, height: wr.height))
                            g.fill(CGRect(x: wr.maxX + cs * 0.02, y: wr.minY, width: cs * 0.08, height: wr.height))
                        }
                    }
                }
            }
            // floor slab lines
            if st.kind != 1 {
                g.setFillColor(WTex.col(0, 0, 0, 0.10))
                for r in 0..<cells {
                    g.fill(CGRect(x: 0, y: CGFloat(r) * cs, width: CGFloat(size), height: 2))
                }
            }
        }
    }

    static func emission(style: Int, variant: Int, size: Int = 512) -> UIImage {
        let st = styles[style % styles.count]
        let cs = CGFloat(size / cells)
        return WTex.render(size, size, opaque: true) { g in
            g.setFillColor(WTex.col(0, 0, 0))
            g.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let seed = 900 + style * 31 + variant * 7
            for r in 0..<cells {
                for k in 0..<cells {
                    let x = CGFloat(k) * cs
                    let y = CGFloat(r) * cs
                    let wr = windowRect(st.kind, x, y, cs)
                    let roll = wHash01(r, k, seed)
                    // whole floors are sometimes on (offices)
                    let floorBias = wHash01(r, 3, seed + 1) > 0.8 ? 0.35 : 0.0
                    if roll > st.litProbability + Float(floorBias) { continue }
                    let tone = wHash01(r, k, seed + 2)
                    var col = Vec3(1.0, 0.86, 0.58)
                    if tone > 0.85 { col = Vec3(0.75, 0.88, 1.0) }
                    else if tone > 0.6 { col = Vec3(1.0, 0.72, 0.42) }
                    else if tone < 0.15 { col = Vec3(0.55, 0.50, 0.40) }
                    let bright: Float = 0.55 + wHash01(r, k, seed + 3) * 0.45
                    g.saveGState()
                    g.clip(to: wr.insetBy(dx: 2, dy: 2))
                    WTex.lin(g, WTex.col(col.x * bright, col.y * bright, col.z * bright), WTex.col(col.x * bright * 0.55, col.y * bright * 0.55, col.z * bright * 0.55),
                             from: CGPoint(x: wr.minX, y: wr.minY), to: CGPoint(x: wr.minX, y: wr.maxY))
                    g.restoreGState()
                }
            }
        }
    }

    // MARK: shop fronts (4 shops per tile; each 6 m wide, 5 m high)

    private static let shopNames: [String] = ["CAFE", "PIZZA", "BANK", "HOTEL", "BOOKS", "SPORT", "PHARMA", "DINER", "TECH", "BAKERY", "MODA", "BAR"]
    private static let signColors: [Vec3] = [
        Vec3(0.75, 0.10, 0.12), Vec3(0.10, 0.35, 0.65), Vec3(0.10, 0.50, 0.30), Vec3(0.85, 0.55, 0.08),
        Vec3(0.45, 0.15, 0.55), Vec3(0.08, 0.08, 0.10), Vec3(0.80, 0.15, 0.45), Vec3(0.05, 0.55, 0.60)
    ]

    static func shopDiffuse(seed: Int) -> UIImage {
        return WTex.render(1024, 256, opaque: true) { g in
            for i in 0..<4 {
                let ox = CGFloat(i * 256)
                let sc = signColors[Int(wHash01(i, seed, 8) * Float(signColors.count)) % signColors.count]
                let wallTone: Float = 0.55 + wHash01(i, seed, 9) * 0.3
                g.setFillColor(WTex.col(wallTone, wallTone * 0.96, wallTone * 0.9))
                g.fill(CGRect(x: ox, y: 0, width: 256, height: 256))
                // sign plate
                g.setFillColor(c(sc))
                g.fill(CGRect(x: ox + 14, y: 10, width: 228, height: 44))
                g.setStrokeColor(WTex.col(0.9, 0.9, 0.9))
                g.setLineWidth(2)
                g.stroke(CGRect(x: ox + 14, y: 10, width: 228, height: 44))
                let name = shopNames[Int(wHash01(i, seed, 10) * Float(shopNames.count)) % shopNames.count]
                drawShopText(name, CGRect(x: ox + 14, y: 12, width: 228, height: 40), 30)
                // glass storefront
                let glass = CGRect(x: ox + 14, y: 70, width: 160, height: 150)
                g.saveGState()
                g.clip(to: glass)
                WTex.lin(g, WTex.col(0.32, 0.40, 0.46), WTex.col(0.06, 0.08, 0.10), from: CGPoint(x: glass.minX, y: glass.minY), to: CGPoint(x: glass.minX, y: glass.maxY))
                g.setFillColor(WTex.col(1, 1, 1, 0.12))
                g.move(to: CGPoint(x: glass.minX + 40, y: glass.minY))
                g.addLine(to: CGPoint(x: glass.minX + 90, y: glass.minY))
                g.addLine(to: CGPoint(x: glass.minX + 30, y: glass.maxY))
                g.addLine(to: CGPoint(x: glass.minX - 20, y: glass.maxY))
                g.fillPath()
                g.restoreGState()
                g.setStrokeColor(WTex.col(0.12, 0.12, 0.13))
                g.setLineWidth(4)
                g.stroke(glass)
                // door
                let door = CGRect(x: ox + 184, y: 70, width: 58, height: 150)
                g.saveGState()
                g.clip(to: door)
                WTex.lin(g, WTex.col(0.36, 0.44, 0.50), WTex.col(0.08, 0.10, 0.12), from: CGPoint(x: door.minX, y: door.minY), to: CGPoint(x: door.minX, y: door.maxY))
                g.restoreGState()
                g.stroke(door)
                g.setFillColor(WTex.col(0.8, 0.8, 0.8))
                g.fill(CGRect(x: door.minX + 6, y: door.midY, width: 4, height: 24))
                // plinth
                g.setFillColor(WTex.col(0.22, 0.22, 0.24))
                g.fill(CGRect(x: ox, y: 226, width: 256, height: 30))
            }
        }
    }

    static func shopEmission(seed: Int) -> UIImage {
        return WTex.render(1024, 256, opaque: true) { g in
            g.setFillColor(WTex.col(0, 0, 0))
            g.fill(CGRect(x: 0, y: 0, width: 1024, height: 256))
            for i in 0..<4 {
                let ox = CGFloat(i * 256)
                let sc = signColors[Int(wHash01(i, seed, 8) * Float(signColors.count)) % signColors.count]
                g.setFillColor(WTex.col(sc.x * 1.3, sc.y * 1.3, sc.z * 1.3))
                g.fill(CGRect(x: ox + 16, y: 12, width: 224, height: 40))
                let name = shopNames[Int(wHash01(i, seed, 10) * Float(shopNames.count)) % shopNames.count]
                drawShopText(name, CGRect(x: ox + 14, y: 12, width: 228, height: 40), 30)
                let glass = CGRect(x: ox + 18, y: 74, width: 152, height: 142)
                g.saveGState()
                g.clip(to: glass)
                let warm = wHash01(i, seed, 11) > 0.3
                let top: CGColor = warm ? WTex.col(0.85, 0.62, 0.30) : WTex.col(0.6, 0.8, 0.95)
                let bot: CGColor = warm ? WTex.col(0.35, 0.22, 0.10) : WTex.col(0.15, 0.25, 0.35)
                WTex.lin(g, top, bot, from: CGPoint(x: glass.minX, y: glass.minY), to: CGPoint(x: glass.minX, y: glass.maxY))
                g.restoreGState()
                g.setFillColor(WTex.col(0.5, 0.42, 0.30))
                g.fill(CGRect(x: ox + 188, y: 74, width: 50, height: 142))
            }
        }
    }

    private static func drawShopText(_ text: String, _ rect: CGRect, _ size: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: size),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    static func awning() -> UIImage {
        return WTex.render(256, 64, opaque: true) { g in
            let palette: [Vec3] = [Vec3(0.75, 0.10, 0.12), Vec3(0.10, 0.35, 0.60), Vec3(0.10, 0.50, 0.28), Vec3(0.85, 0.55, 0.08)]
            for i in 0..<16 {
                let stripe = i % 2 == 0
                let p = palette[(i / 4) % palette.count]
                if stripe { g.setFillColor(c(p)) } else { g.setFillColor(WTex.col(0.93, 0.92, 0.88)) }
                g.fill(CGRect(x: CGFloat(i * 16), y: 0, width: 16, height: 64))
            }
        }
    }
}
