import Foundation
import UIKit
import CoreGraphics

// MARK: - The c0derz design: neon green + magenta on near-black, circuit-board traces, "</>" and code. Everything is drawn with
// CoreGraphics so the house has murals on its walls without shipping image files.

enum C0derzArt {
    static let green: CGColor = UIColor(red: 0.22, green: 1.0, blue: 0.53, alpha: 1).cgColor
    static let magenta: CGColor = UIColor(red: 1.0, green: 0.17, blue: 0.84, alpha: 1).cgColor
    static let cyan: CGColor = UIColor(red: 0.17, green: 0.90, blue: 1.0, alpha: 1).cgColor
    static let ink: CGColor = UIColor(red: 0.02, green: 0.025, blue: 0.04, alpha: 1).cgColor

    private static func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let r = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt)
        return r.image { rc in draw(rc.cgContext) }
    }

    private static func rnd(_ a: Int, _ b: Int, _ s: Int) -> CGFloat {
        return CGFloat(wHash01(a, b, s))
    }

    // MARK: circuit traces

    static func drawCircuit(_ c: CGContext, _ rect: CGRect, seed: Int, density: Int, colour: CGColor, alpha: CGFloat) {
        c.saveGState()
        c.clip(to: rect)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        let step: CGFloat = 22
        for i in 0..<density {
            var x: CGFloat = rect.minX + (rnd(i, 1, seed) * rect.width / step).rounded() * step
            var y: CGFloat = rect.minY + (rnd(i, 2, seed) * rect.height / step).rounded() * step
            let cc = UIColor(cgColor: colour).withAlphaComponent(alpha * (0.35 + 0.65 * rnd(i, 3, seed))).cgColor
            c.setStrokeColor(cc)
            c.setFillColor(cc)
            c.setLineWidth(1.6 + 1.6 * rnd(i, 4, seed))
            c.move(to: CGPoint(x: x, y: y))
            let segs: Int = 3 + Int(rnd(i, 5, seed) * 5)
            var dir: Int = Int(rnd(i, 6, seed) * 8)
            for s in 0..<segs {
                let len: CGFloat = step * (1 + CGFloat(Int(rnd(i, 10 + s, seed) * 5)))
                let dx: [CGFloat] = [1, 1, 0, -1, -1, -1, 0, 1]
                let dy: [CGFloat] = [0, 1, 1, 1, 0, -1, -1, -1]
                x += dx[dir % 8] * len
                y += dy[dir % 8] * len
                c.addLine(to: CGPoint(x: x, y: y))
                if rnd(i, 30 + s, seed) > 0.5 { dir += (rnd(i, 50 + s, seed) > 0.5 ? 1 : 7) }
            }
            c.strokePath()
            c.fillEllipse(in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
            c.setFillColor(ink)
            c.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
        }
        c.restoreGState()
    }

    private static func neonText(_ c: CGContext, _ text: String, in rect: CGRect, font: UIFont, colour: UIColor, glow: CGColor, glowBlur: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let str = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: para]
        let h: CGFloat = str.size(withAttributes: attrs).height
        let r = CGRect(x: rect.minX, y: rect.minY + (rect.height - h) * 0.5, width: rect.width, height: h)
        c.saveGState()
        c.setShadow(offset: CGSize.zero, blur: glowBlur, color: glow)
        str.draw(in: r, withAttributes: attrs)
        str.draw(in: r, withAttributes: attrs)
        c.restoreGState()
    }

    // MARK: murals

    /// large wall mural: "c0derz" neon graffiti + </> + circuit board, aspect ~ 4:3 .. 2:1
    static func mural(width: Int, height: Int, seed: Int) -> UIImage {
        return render(width, height) { c in
            let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            c.setFillColor(ink)
            c.fill(full)
            // soft colour washes
            let cs = CGColorSpaceCreateDeviceRGB()
            let washColors: [CGColor] = [UIColor(red: 1, green: 0.17, blue: 0.84, alpha: 0.30).cgColor, UIColor(red: 1, green: 0.17, blue: 0.84, alpha: 0).cgColor]
            if let g = CGGradient(colorsSpace: cs, colors: washColors as CFArray, locations: [0, 1]) {
                c.drawRadialGradient(g, startCenter: CGPoint(x: full.width * 0.85, y: full.height * 0.15), startRadius: 0,
                                     endCenter: CGPoint(x: full.width * 0.85, y: full.height * 0.15), endRadius: full.width * 0.55, options: [])
            }
            let washG: [CGColor] = [UIColor(red: 0.22, green: 1, blue: 0.53, alpha: 0.26).cgColor, UIColor(red: 0.22, green: 1, blue: 0.53, alpha: 0).cgColor]
            if let g = CGGradient(colorsSpace: cs, colors: washG as CFArray, locations: [0, 1]) {
                c.drawRadialGradient(g, startCenter: CGPoint(x: full.width * 0.1, y: full.height * 0.9), startRadius: 0,
                                     endCenter: CGPoint(x: full.width * 0.1, y: full.height * 0.9), endRadius: full.width * 0.6, options: [])
            }
            drawCircuit(c, full, seed: seed, density: 42, colour: green, alpha: 0.55)
            drawCircuit(c, full, seed: seed + 7, density: 26, colour: magenta, alpha: 0.5)
            // frame
            c.setStrokeColor(green)
            c.setLineWidth(6)
            c.stroke(full.insetBy(dx: 10, dy: 10))
            c.setStrokeColor(magenta)
            c.setLineWidth(3)
            c.stroke(full.insetBy(dx: 22, dy: 22))
            // "</>" small on top
            let big: CGFloat = CGFloat(height) * 0.34
            neonText(c, "</>", in: CGRect(x: 0, y: CGFloat(height) * 0.06, width: CGFloat(width), height: big * 0.9),
                     font: UIFont(name: "Menlo-Bold", size: big * 0.62) ?? UIFont.boldSystemFont(ofSize: big * 0.62),
                     colour: UIColor(cgColor: magenta), glow: magenta, glowBlur: 28)
            // main word
            neonText(c, "c0derz", in: CGRect(x: 0, y: CGFloat(height) * 0.28, width: CGFloat(width), height: CGFloat(height) * 0.5),
                     font: UIFont.systemFont(ofSize: CGFloat(height) * 0.36, weight: UIFont.Weight.black),
                     colour: UIColor(cgColor: green), glow: green, glowBlur: 36)
            // tagline
            neonText(c, "code · drive · repeat", in: CGRect(x: 0, y: CGFloat(height) * 0.76, width: CGFloat(width), height: CGFloat(height) * 0.16),
                     font: UIFont(name: "Menlo", size: CGFloat(height) * 0.075) ?? UIFont.systemFont(ofSize: CGFloat(height) * 0.075),
                     colour: UIColor(cgColor: cyan), glow: cyan, glowBlur: 12)
        }
    }

    /// dark circuit-board wallpaper (no text) that tiles vertically / horizontally
    static func circuitWall(size: Int, seed: Int) -> UIImage {
        return render(size, size) { c in
            let full = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
            c.setFillColor(ink)
            c.fill(full)
            drawCircuit(c, full, seed: seed, density: 60, colour: green, alpha: 0.45)
            drawCircuit(c, full, seed: seed + 3, density: 30, colour: magenta, alpha: 0.4)
            drawCircuit(c, full, seed: seed + 9, density: 18, colour: cyan, alpha: 0.35)
        }
    }

    /// monospaced code listing, tileable vertically (used on the monitors, scrolled by animating the texture transform)
    static func codeScreen(seed: Int) -> UIImage {
        let w = 512
        let h = 512
        return render(w, h) { c in
            c.setFillColor(UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let lines: [String] = [
                "import Supercars", "", "final class Player {", "    let name = \"c0derz\"", "    var engine: Engine = .v16",
                "    func drive(_ car: Car) {", "        car.throttle = 1.0", "        while car.isAlive {", "            car.steer(tilt)",
                "            if car.hitLamp { crash() }", "        }", "    }", "}", "", "// commit: fix camera far bug",
                "git push origin main", "> build succeeded", "> unsigned.ipa ready", "", "func garage() {", "    swap(.v12)", "    paint(\"#39FF88\")", "}"
            ]
            let font = UIFont(name: "Menlo", size: 21) ?? UIFont.systemFont(ofSize: 21)
            for (i, line) in lines.enumerated() {
                let y: CGFloat = CGFloat(i) * 22 + 4
                var col = UIColor(red: 0.75, green: 0.85, blue: 0.9, alpha: 1)
                if line.hasPrefix("//") { col = UIColor(red: 0.4, green: 0.5, blue: 0.5, alpha: 1) }
                else if line.hasPrefix(">") { col = UIColor(cgColor: green) }
                else if line.contains("func") || line.contains("class") || line.contains("import") { col = UIColor(cgColor: magenta) }
                else if line.contains("\"") { col = UIColor(cgColor: cyan) }
                (line as NSString).draw(at: CGPoint(x: 14, y: y), withAttributes: [.font: font, .foregroundColor: col])
                _ = i + seed
            }
            c.setFillColor(UIColor(cgColor: green).withAlphaComponent(0.06).cgColor)
            for k in 0..<64 { c.fill(CGRect(x: 0, y: CGFloat(k) * 8, width: CGFloat(w), height: 1)) }
        }
    }

    /// TV picture: colourful gradient with the c0derz mark
    static func tvScreen() -> UIImage {
        return render(512, 288) { c in
            let cs = CGColorSpaceCreateDeviceRGB()
            let cols: [CGColor] = [UIColor(red: 0.10, green: 0.05, blue: 0.25, alpha: 1).cgColor, UIColor(red: 0.85, green: 0.10, blue: 0.65, alpha: 1).cgColor,
                                   UIColor(red: 0.10, green: 0.85, blue: 0.55, alpha: 1).cgColor]
            if let g = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: [0, 0.55, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 512, y: 288), options: [])
            }
            neonText(c, "c0derz TV", in: CGRect(x: 0, y: 90, width: 512, height: 110), font: UIFont.systemFont(ofSize: 74, weight: UIFont.Weight.heavy),
                     colour: UIColor.white, glow: cyan, glowBlur: 16)
        }
    }

    /// small emissive sign (neon "c0derz" on black) for outdoor use
    static func sign(width: Int, height: Int) -> UIImage {
        return render(width, height) { c in
            c.setFillColor(ink)
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            neonText(c, "c0derz", in: CGRect(x: 0, y: 0, width: CGFloat(width) * 0.72, height: CGFloat(height)),
                     font: UIFont.systemFont(ofSize: CGFloat(height) * 0.62, weight: UIFont.Weight.black),
                     colour: UIColor(cgColor: green), glow: green, glowBlur: 20)
            neonText(c, "</>", in: CGRect(x: CGFloat(width) * 0.68, y: 0, width: CGFloat(width) * 0.32, height: CGFloat(height)),
                     font: UIFont(name: "Menlo-Bold", size: CGFloat(height) * 0.5) ?? UIFont.boldSystemFont(ofSize: CGFloat(height) * 0.5),
                     colour: UIColor(cgColor: magenta), glow: magenta, glowBlur: 20)
        }
    }

    /// wall poster (a car silhouette-less abstract: stripes + tag)
    static func poster(seed: Int, text: String) -> UIImage {
        return render(256, 384) { c in
            let cs = CGColorSpaceCreateDeviceRGB()
            let cols: [CGColor] = [UIColor(red: 0.05, green: 0.03, blue: 0.12, alpha: 1).cgColor, UIColor(red: 0.5, green: 0.05, blue: 0.45, alpha: 1).cgColor]
            if let g = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: [0, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 384), options: [])
            }
            c.setStrokeColor(green)
            c.setLineWidth(5)
            for k in 0..<7 {
                let y: CGFloat = 210 + CGFloat(k) * 16
                c.move(to: CGPoint(x: 20, y: y))
                c.addLine(to: CGPoint(x: 236, y: y - CGFloat(k) * 2 - CGFloat(seed % 5)))
                c.strokePath()
            }
            neonText(c, text, in: CGRect(x: 0, y: 40, width: 256, height: 90), font: UIFont.systemFont(ofSize: 42, weight: UIFont.Weight.black),
                     colour: UIColor.white, glow: magenta, glowBlur: 14)
        }
    }
}
