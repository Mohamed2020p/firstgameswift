import SwiftUI
import UIKit
import simd

// MARK: - The big map: dark neutral streets on graphite, pan / pinch zoom, tap a place to select it, set it as the destination, see the
// route and where you are facing.  The city repeats every `tilePeriod` metres (endless world), so the streets are drawn in tile copies.

private enum MapStyle {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.066)
    static let road = Color(red: 0.80, green: 0.81, blue: 0.83)
    static let roadCasing = Color(red: 0.03, green: 0.03, blue: 0.035)
    static let route = Color(red: 0.92, green: 0.76, blue: 0.42)

    static func districtColor(_ kind: String) -> Color {
        switch kind {
        case "downtown": return Color(red: 0.17, green: 0.18, blue: 0.20)
        case "midrise": return Color(red: 0.145, green: 0.155, blue: 0.17)
        case "residential": return Color(red: 0.115, green: 0.125, blue: 0.135)
        case "luxury": return Color(red: 0.13, green: 0.14, blue: 0.125)
        case "industrial": return Color(red: 0.15, green: 0.14, blue: 0.13)
        case "park": return Color(red: 0.10, green: 0.17, blue: 0.12)
        case "plaza": return Color(red: 0.19, green: 0.19, blue: 0.18)
        case "civic": return Color(red: 0.13, green: 0.15, blue: 0.20)
        default: return Color(red: 0.12, green: 0.12, blue: 0.13)
        }
    }
}

/// world <-> screen transform of the big map (north = +Z is up, +X to the left, like looking down at the 3D world from behind +Z)
struct MapTransform {
    var center: Vec2
    var scale: CGFloat
    var size: CGSize

    func toScreen(_ p: Vec2) -> CGPoint {
        return CGPoint(x: size.width / 2 - CGFloat(p.x - center.x) * scale, y: size.height / 2 - CGFloat(p.y - center.y) * scale)
    }

    func toWorld(_ pt: CGPoint) -> Vec2 {
        return Vec2(center.x - Float((pt.x - size.width / 2) / scale), center.y - Float((pt.y - size.height / 2) / scale))
    }
}

struct MapScreen: View {
    let ctx: GameContext
    @ObservedObject private var state: GameState

    @State private var center: Vec2 = Vec2(0, 0)
    @State private var scale: CGFloat = 0.22
    @State private var panStart: Vec2? = nil
    @State private var scaleStart: CGFloat? = nil
    @State private var selected: MapWaypoint? = nil
    @State private var started: Bool = false

    init(ctx: GameContext) {
        self.ctx = ctx
        _state = ObservedObject(wrappedValue: ctx.state)
    }

    private var waypoints: [MapWaypoint] { return ctx.nav?.registry.all ?? [] }

    private func playerPos() -> Vec2 { return state.playerMapPosition }

    var body: some View {
        GeometryReader { geo in
            let tf = MapTransform(center: center, scale: scale, size: geo.size)
            ZStack {
                MapStyle.background.ignoresSafeArea()
                MapCanvas(tf: tf, data: state.minimap, nav: state.navigation, player: state.playerMapPosition, heading: state.playerMapHeading,
                          selected: selected?.position, showDistrictNames: scale > 0.16)
                    .gesture(panGesture(tf))
                    .simultaneousGesture(zoomGesture())
                    .simultaneousGesture(SpatialTapGesture().onEnded { (v: SpatialTapGesture.Value) in tap(at: v.location, tf: tf) })
                pins(tf)
                topBar
                sideControls
                bottomCard
            }
            .onAppear {
                if !started {
                    started = true
                    center = playerPos()
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: gestures

    private func panGesture(_ tf: MapTransform) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { (v: DragGesture.Value) in
                if panStart == nil { panStart = center }
                if let s = panStart {
                    center = Vec2(s.x + Float(v.translation.width / scale), s.y + Float(v.translation.height / scale))
                }
            }
            .onEnded { (_: DragGesture.Value) in panStart = nil }
    }

    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { (m: CGFloat) in
                if scaleStart == nil { scaleStart = scale }
                if let s = scaleStart { scale = max(0.06, min(2.6, s * m)) }
            }
            .onEnded { (_: CGFloat) in scaleStart = nil }
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) { scale = max(0.06, min(2.6, scale * factor)) }
    }

    private func tap(at point: CGPoint, tf: MapTransform) {
        // nearest waypoint within reach of the finger
        var best: MapWaypoint? = nil
        var bd: CGFloat = 34
        for w in waypoints {
            let p: CGPoint = tf.toScreen(w.position)
            let d: CGFloat = hypot(p.x - point.x, p.y - point.y)
            if d < bd {
                bd = d
                best = w
            }
        }
        if let b = best {
            selected = b
            ctx.audio.play(SFX.uiTap, volume: 0.5, rate: 1, position: nil)
            return
        }
        // empty map: drop a pin
        let world: Vec2 = tf.toWorld(point)
        let name: String = ctx.nav?.districtName(at: world) ?? "Pin"
        let pin = MapWaypoint(id: "pin", name: name.isEmpty ? "Dropped pin" : name, subtitle: "Dropped pin", kind: WaypointKind.custom, position: world)
        ctx.nav?.registry.register(pin)
        selected = pin
        ctx.audio.play(SFX.uiTap, volume: 0.5, rate: 1, position: nil)
    }

    // MARK: overlays

    private func pins(_ tf: MapTransform) -> some View {
        ZStack {
            ForEach(waypoints) { w in
                let p: CGPoint = tf.toScreen(w.position)
                if p.x > -40 && p.x < tf.size.width + 40 && p.y > -40 && p.y < tf.size.height + 40 && showPin(w) {
                    PinView(waypoint: w, selected: selected?.id == w.id, active: state.navigation?.destinationID == w.id)
                        .position(p)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// districts and taxi stands only appear when zoomed in enough to read them
    private func showPin(_ w: MapWaypoint) -> Bool {
        if w.kind == WaypointKind.taxiStand { return scale > 0.14 }
        if w.kind.isPointOfInterest || w.kind == WaypointKind.custom { return true }
        return scale < 0.5
    }

    private var topBar: some View {
        let inset: UIEdgeInsets = ScreenInsets.current
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { ctx.closeMap() }) {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .overlay(Circle().stroke(Neon.hairline, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("MAP").font(Neon.font(15, .semibold)).tracking(3).foregroundColor(.white)
                    Text(state.districtName.isEmpty ? "—" : state.districtName).font(Neon.font(11, .regular)).foregroundColor(Neon.dim)
                }
                Spacer()
                if state.navigation != nil {
                    Button(action: { ctx.nav?.clear() }) {
                        Text("Clear route").font(Neon.font(12, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                            .overlay(Capsule().stroke(Neon.hairline, lineWidth: 1))
                    }
                }
                CompassBadge()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickList) { w in
                        Button(action: { jump(to: w) }) {
                            HStack(spacing: 6) {
                                Image(systemName: w.kind.symbol).font(.system(size: 12, weight: .semibold))
                                Text(w.name).font(Neon.font(12, .medium))
                            }
                            .foregroundColor(selected?.id == w.id ? Neon.ink : .white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(selected?.id == w.id ? Neon.green : Color.white.opacity(0.09)))
                            .overlay(Capsule().stroke(Neon.hairline, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, max(inset.left, 16) + 4)
        .padding(.top, max(inset.top, 10) + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var quickList: [MapWaypoint] {
        var out: [MapWaypoint] = []
        for id in ["raceStart", "home", "garage", "police", "downtown", "plaza"] {
            if let w = ctx.nav?.registry.waypoint(id: id) { out.append(w) }
        }
        if let t = nearestTaxi() { out.append(t) }
        return out
    }

    private func nearestTaxi() -> MapWaypoint? {
        let p: Vec2 = playerPos()
        var best: MapWaypoint? = nil
        var bd: Float = Float.greatestFiniteMagnitude
        for w in waypoints where w.kind == WaypointKind.taxiStand {
            let d: Float = simd_distance(w.position, p)
            if d < bd {
                bd = d
                best = w
            }
        }
        return best
    }

    private func jump(to w: MapWaypoint) {
        selected = w
        withAnimation(.easeOut(duration: 0.25)) {
            center = w.position
            if scale < 0.2 { scale = 0.3 }
        }
        ctx.audio.play(SFX.uiTap, volume: 0.5, rate: 1, position: nil)
    }

    private var sideControls: some View {
        let inset: UIEdgeInsets = ScreenInsets.current
        return VStack(spacing: 10) {
            roundButton("plus") { zoom(by: 1.5) }
            roundButton("minus") { zoom(by: 1 / 1.5) }
            roundButton("location.fill") {
                withAnimation(.easeOut(duration: 0.25)) { center = playerPos() }
            }
        }
        .padding(.trailing, max(inset.right, 16) + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func roundButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().stroke(Neon.hairline, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var bottomCard: some View {
        if let w = selected {
            let inset: UIEdgeInsets = ScreenInsets.current
            let dist: Float = simd_distance(w.position, playerPos())
            let isDest: Bool = state.navigation?.destinationID == w.id
            HStack(spacing: 14) {
                Image(systemName: w.kind.symbol).font(.system(size: 20, weight: .semibold)).foregroundColor(Neon.ink)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Neon.green))
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name).font(Neon.font(17, .semibold)).foregroundColor(.white)
                    Text(w.subtitle).font(Neon.font(12, .regular)).foregroundColor(Neon.dim).lineLimit(1)
                    Text(distanceText(dist) + " away").font(Neon.mono(11, .medium)).foregroundColor(Neon.magenta)
                }
                Spacer(minLength: 8)
                VStack(spacing: 8) {
                    Button(action: {
                        if isDest {
                            ctx.nav?.clear()
                        } else {
                            ctx.nav?.setDestination(w)
                            ctx.closeMap()
                        }
                    }) {
                        Text(isDest ? "Cancel route" : "Set destination").font(Neon.font(14, .semibold)).foregroundColor(Neon.ink)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Neon.green))
                    }
                    Button(action: { selected = nil }) {
                        Text("Dismiss").font(Neon.font(12, .medium)).foregroundColor(Neon.dim)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 560)
            .glassPanel()
            .padding(.horizontal, max(inset.left, 16) + 4)
            .padding(.bottom, max(inset.bottom, 12) + 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func distanceText(_ d: Float) -> String {
        if d >= 1000 { return String(format: "%.1f km", d / 1000) }
        return "\(Int(d)) m"
    }
}

// MARK: - pieces

private struct CompassBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Circle().stroke(Neon.hairline, lineWidth: 1)
            VStack(spacing: 0) {
                Text("N").font(Neon.font(11, .semibold)).foregroundColor(.white)
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7)).foregroundColor(Neon.magenta)
            }
        }
        .frame(width: 38, height: 38)
    }
}

private struct PinView: View {
    let waypoint: MapWaypoint
    let selected: Bool
    let active: Bool

    var body: some View {
        let size: CGFloat = selected ? 36 : 28
        ZStack {
            Circle().fill(active ? Neon.magenta : (selected ? Neon.green : Color(red: 0.16, green: 0.17, blue: 0.19)))
            Circle().stroke(selected || active ? Color.white : Neon.hairline, lineWidth: selected ? 2 : 1)
            Image(systemName: waypoint.kind.symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundColor(selected || active ? Neon.ink : .white)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 2)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct MapCanvas: View {
    let tf: MapTransform
    let data: MinimapData
    let nav: NavigationInfo?
    let player: Vec2
    let heading: Float
    let selected: Vec2?
    let showDistrictNames: Bool

    var body: some View {
        Canvas { c, size in
            let period: Float = max(500, data.tilePeriod)
            let half: Float = period * 0.5
            // visible world rectangle
            let a: Vec2 = tf.toWorld(CGPoint(x: 0, y: 0))
            let b: Vec2 = tf.toWorld(CGPoint(x: size.width, y: size.height))
            let minX: Float = min(a.x, b.x)
            let maxX: Float = max(a.x, b.x)
            let minZ: Float = min(a.y, b.y)
            let maxZ: Float = max(a.y, b.y)
            let t0x: Int = Int(floorf((minX + half) / period))
            let t1x: Int = Int(floorf((maxX + half) / period))
            let t0z: Int = Int(floorf((minZ + half) / period))
            let t1z: Int = Int(floorf((maxZ + half) / period))
            if t1x < t0x || t1z < t0z { return }
            let roadW: CGFloat = max(1.4, min(9, 13 * tf.scale))
            for tx in t0x...t1x {
                for tz in t0z...t1z {
                    let off: Vec2 = Vec2(Float(tx) * period, Float(tz) * period)
                    // ---- districts
                    for d in data.districts {
                        let p0: CGPoint = tf.toScreen(Vec2(d.rect.x0, d.rect.z0) + off)
                        let p1: CGPoint = tf.toScreen(Vec2(d.rect.x1, d.rect.z1) + off)
                        let r = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
                        if r.maxX < 0 || r.minX > size.width || r.maxY < 0 || r.minY > size.height { continue }
                        c.fill(Path(r), with: .color(MapStyle.districtColor(d.kind)))
                        if showDistrictNames && (d.kind == "park" || d.kind == "plaza" || d.kind == "civic") && r.width > 60 {
                            c.draw(Text(d.name.uppercased()).font(Neon.font(9, .semibold)).foregroundColor(Color.white.opacity(0.35)), at: CGPoint(x: r.midX, y: r.midY))
                        }
                    }
                    // ---- roads (dark casing, light core)
                    var roads = Path()
                    for line in data.roads {
                        if line.count < 2 { continue }
                        roads.move(to: tf.toScreen(line[0] + off))
                        for i in 1..<line.count { roads.addLine(to: tf.toScreen(line[i] + off)) }
                    }
                    c.stroke(roads, with: .color(MapStyle.roadCasing), style: StrokeStyle(lineWidth: roadW + 2.4, lineCap: .round, lineJoin: .round))
                    c.stroke(roads, with: .color(MapStyle.road.opacity(0.55)), style: StrokeStyle(lineWidth: roadW, lineCap: .round, lineJoin: .round))
                    // ---- race circuit
                    if data.route.count > 2 {
                        var circuit = Path()
                        circuit.move(to: tf.toScreen(data.route[0] + off))
                        for i in 1..<data.route.count { circuit.addLine(to: tf.toScreen(data.route[i] + off)) }
                        c.stroke(circuit, with: .color(Color(red: 0.75, green: 0.35, blue: 0.32).opacity(0.75)),
                                 style: StrokeStyle(lineWidth: max(1.2, roadW * 0.5), lineCap: .round, lineJoin: .round, dash: [6, 5]))
                    }
                }
            }
            // ---- navigation route
            if let n = nav, n.route.count > 1 {
                var rp = Path()
                rp.move(to: tf.toScreen(n.route[0]))
                for i in 1..<n.route.count { rp.addLine(to: tf.toScreen(n.route[i])) }
                c.stroke(rp, with: .color(Color.black.opacity(0.7)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                c.stroke(rp, with: .color(MapStyle.route), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            }
            // ---- selection ring
            if let s = selected {
                let p: CGPoint = tf.toScreen(s)
                c.stroke(Path(ellipseIn: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52)), with: .color(Color.white.opacity(0.7)), lineWidth: 1.5)
            }
            // ---- the player: an arrow that points where the car / character faces
            let pp: CGPoint = tf.toScreen(player)
            var arrow = Path()
            arrow.move(to: CGPoint(x: 0, y: -13))
            arrow.addLine(to: CGPoint(x: 8.5, y: 10))
            arrow.addLine(to: CGPoint(x: 0, y: 5))
            arrow.addLine(to: CGPoint(x: -8.5, y: 10))
            arrow.closeSubpath()
            let rot = CGAffineTransform(translationX: pp.x, y: pp.y).rotated(by: CGFloat(-heading))
            let placed: Path = arrow.applying(rot)
            c.fill(placed, with: .color(Color.white))
            c.stroke(placed, with: .color(Color.black), lineWidth: 1.5)
        }
    }
}
