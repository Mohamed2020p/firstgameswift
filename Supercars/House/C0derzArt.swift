import Foundation
import UIKit
import CoreGraphics

// MARK: - The c0derz signature, restrained: graphite panels with fine line-work in steel and brass, small lettering, no glow.
// Everything is drawn with CoreGraphics so the house has wall art without shipping image files.

enum C0derzArt {
    static let steel: CGColor = UIColor(red: 0.74, green: 0.76, blue: 0.79, alpha: 1).cgColor
    static let brass: CGColor = UIColor(red: 0.78, green: 0.66, blue: 0.44, alpha: 1).cgColor
    static let mist: CGColor = UIColor(red: 0.56, green: 0.62, blue: 0.68, alpha: 1).cgColor
    static let ink: CGColor = UIColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1).cgColor
    static let graphite: CGColor = UIColor(red: 0.13, green: 0.14, blue: 0.155, alpha: 1).cgColor

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

    // MARK: line-work

    /// fine orthogonal traces, low contrast
    static func drawTraces(_ c: CGContext, _ rect: CGRect, seed: Int, density: Int, colour: CGColor, alpha: CGFloat) {
        c.saveGState()
        c.clip(to: rect)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        let step: CGFloat = 26
        for i in 0..<density {
            var x: CGFloat = rect.minX + (rnd(i, 1, seed) * rect.width / step).rounded() * step
            var y: CGFloat = rect.minY + (rnd(i, 2, seed) * rect.height / step).rounded() * step
            let cc = UIColor(cgColor: colour).withAlphaComponent(alpha * (0.35 + 0.65 * rnd(i, 3, seed))).cgColor
            c.setStrokeColor(cc)
            c.setFillColor(cc)
            c.setLineWidth(1.0 + 0.8 * rnd(i, 4, seed))
            c.move(to: CGPoint(x: x, y: y))
            let segs: Int = 3 + Int(rnd(i, 5, seed) * 4)
            var dir: Int = Int(rnd(i, 6, seed) * 4) * 2
            for s in 0..<segs {
                let len: CGFloat = step * (1 + CGFloat(Int(rnd(i, 10 + s, seed) * 4)))
                let dx: [CGFloat] = [1, 1, 0, -1, -1, -1, 0, 1]
                let dy: [CGFloat] = [0, 1, 1, 1, 0, -1, -1, -1]
                x += dx[dir % 8] * len
                y += dy[dir % 8] * len
                c.addLine(to: CGPoint(x: x, y: y))
                if rnd(i, 30 + s, seed) > 0.5 { dir += (rnd(i, 50 + s, seed) > 0.5 ? 2 : 6) }
            }
            c.strokePath()
            c.fillEllipse(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
        }
        c.restoreGState()
    }

    private static func text(_ c: CGContext, _ text: String, in rect: CGRect, font: UIFont, colour: UIColor, kern: CGFloat = 0) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let str = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: para, .kern: kern]
        let h: CGFloat = str.size(withAttributes: attrs).height
        let r = CGRect(x: rect.minX, y: rect.minY + (rect.height - h) * 0.5, width: rect.width, height: h)
        str.draw(in: r, withAttributes: attrs)
    }

    // MARK: wall art

    /// framed graphite panel: fine steel traces, small brass "</>" and a lower-case "c0derz" in light steel
    static func mural(width: Int, height: Int, seed: Int) -> UIImage {
        return render(width, height) { c in
            let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            c.setFillColor(graphite)
            c.fill(full)
            drawTraces(c, full, seed: seed, density: 34, colour: steel, alpha: 0.16)
            drawTraces(c, full, seed: seed + 7, density: 14, colour: brass, alpha: 0.22)
            c.setStrokeColor(UIColor(cgColor: steel).withAlphaComponent(0.55).cgColor)
            c.setLineWidth(3)
            c.stroke(full.insetBy(dx: 12, dy: 12))
            c.setStrokeColor(UIColor(cgColor: brass).withAlphaComponent(0.6).cgColor)
            c.setLineWidth(1.2)
            c.stroke(full.insetBy(dx: 22, dy: 22))
            let hh: CGFloat = CGFloat(height)
            text(c, "</>", in: CGRect(x: 0, y: hh * 0.10, width: CGFloat(width), height: hh * 0.22),
                 font: UIFont(name: "Menlo", size: hh * 0.14) ?? UIFont.systemFont(ofSize: hh * 0.14), colour: UIColor(cgColor: brass))
            text(c, "c0derz", in: CGRect(x: 0, y: hh * 0.32, width: CGFloat(width), height: hh * 0.40),
                 font: UIFont.systemFont(ofSize: hh * 0.30, weight: UIFont.Weight.semibold), colour: UIColor(cgColor: steel), kern: hh * 0.02)
            text(c, "code  ·  drive  ·  repeat", in: CGRect(x: 0, y: hh * 0.74, width: CGFloat(width), height: hh * 0.14),
                 font: UIFont(name: "Menlo", size: hh * 0.06) ?? UIFont.systemFont(ofSize: hh * 0.06), colour: UIColor(cgColor: mist), kern: 2)
        }
    }

    /// dark wallpaper with faint traces
    static func circuitWall(size: Int, seed: Int) -> UIImage {
        return render(size, size) { c in
            let full = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
            c.setFillColor(ink)
            c.fill(full)
            drawTraces(c, full, seed: seed, density: 40, colour: steel, alpha: 0.10)
            drawTraces(c, full, seed: seed + 3, density: 16, colour: brass, alpha: 0.12)
        }
    }

    /// monospaced code listing (an editor window), tileable vertically
    static func codeScreen(seed: Int) -> UIImage {
        let w = 512
        let h = 512
        return render(w, h) { c in
            c.setFillColor(UIColor(red: 0.075, green: 0.08, blue: 0.09, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let lines: [String] = [
                "import Supercars", "", "final class Player {", "    let name = \"c0derz\"", "    var engine: Engine = .v12",
                "    func drive(_ car: Car) {", "        car.throttle = 0.6", "        while car.isAlive {", "            car.steer(tilt)",
                "            if car.hitLamp { crash() }", "        }", "    }", "}", "", "// commit: tune suspension",
                "git push origin main", "> build succeeded", "> ipa ready", "", "func garage() {", "    swap(.v12)", "    paint(\"graphite\")", "}"
            ]
            let font = UIFont(name: "Menlo", size: 21) ?? UIFont.systemFont(ofSize: 21)
            for (i, line) in lines.enumerated() {
                let y: CGFloat = CGFloat(i) * 22 + 4
                var col = UIColor(red: 0.80, green: 0.82, blue: 0.85, alpha: 1)
                if line.hasPrefix("//") { col = UIColor(red: 0.45, green: 0.50, blue: 0.52, alpha: 1) }
                else if line.hasPrefix(">") { col = UIColor(red: 0.55, green: 0.75, blue: 0.60, alpha: 1) }
                else if line.contains("func") || line.contains("class") || line.contains("import") { col = UIColor(cgColor: brass) }
                else if line.contains("\"") { col = UIColor(red: 0.62, green: 0.72, blue: 0.82, alpha: 1) }
                (line as NSString).draw(at: CGPoint(x: 14, y: y), withAttributes: [.font: font, .foregroundColor: col])
                _ = i + seed
            }
        }
    }

    /// TV picture: a calm dusk landscape gradient with the c0derz mark
    static func tvScreen() -> UIImage {
        return render(512, 288) { c in
            let cs = CGColorSpaceCreateDeviceRGB()
            let cols: [CGColor] = [UIColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1).cgColor, UIColor(red: 0.42, green: 0.36, blue: 0.40, alpha: 1).cgColor,
                                   UIColor(red: 0.82, green: 0.62, blue: 0.42, alpha: 1).cgColor]
            if let g = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: [0, 0.6, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 288), options: [])
            }
            c.setFillColor(UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 232, width: 512, height: 56))
            text(c, "c0derz", in: CGRect(x: 0, y: 90, width: 512, height: 110), font: UIFont.systemFont(ofSize: 64, weight: UIFont.Weight.medium),
                 colour: UIColor(white: 1, alpha: 0.85), kern: 6)
        }
    }

    /// small house-number style plaque: brushed steel on graphite (no light emission)
    static func sign(width: Int, height: Int) -> UIImage {
        return render(width, height) { c in
            c.setFillColor(graphite)
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            c.setStrokeColor(UIColor(cgColor: brass).withAlphaComponent(0.7).cgColor)
            c.setLineWidth(3)
            c.stroke(CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 5, dy: 5))
            text(c, "c0derz", in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
                 font: UIFont.systemFont(ofSize: CGFloat(height) * 0.5, weight: UIFont.Weight.semibold), colour: UIColor(cgColor: steel), kern: 4)
        }
    }

    /// wall poster: graphite with a few steel lines and a tag
    static func poster(seed: Int, text t: String) -> UIImage {
        return render(256, 384) { c in
            let cs = CGColorSpaceCreateDeviceRGB()
            let cols: [CGColor] = [UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor, UIColor(red: 0.26, green: 0.24, blue: 0.24, alpha: 1).cgColor]
            if let g = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: [0, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 384), options: [])
            }
            c.setStrokeColor(UIColor(cgColor: steel).withAlphaComponent(0.7).cgColor)
            c.setLineWidth(3)
            for k in 0..<7 {
                let y: CGFloat = 210 + CGFloat(k) * 16
                c.move(to: CGPoint(x: 20, y: y))
                c.addLine(to: CGPoint(x: 236, y: y - CGFloat(k) * 2 - CGFloat(seed % 5)))
                c.strokePath()
            }
            text(c, t, in: CGRect(x: 0, y: 40, width: 256, height: 90), font: UIFont.systemFont(ofSize: 42, weight: UIFont.Weight.semibold),
                 colour: UIColor(white: 0.95, alpha: 1), kern: 3)
        }
    }
}
