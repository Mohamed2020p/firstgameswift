import SwiftUI
import UIKit

// MARK: - Garage: engine swap (V6 / V8 / V10 / V12 / V16), colour + finish, livery, rims, calipers, tint, wing, tyres. Every change is
// previewed live on the car through `ctx.car.apply(config:)`; the camera orbits the car (drag to rotate, pinch to zoom).

enum GarageTab: String, CaseIterable, Identifiable {
    case engine, paint, wheels, body, tyres
    var id: String { return rawValue }
    var title: String {
        switch self {
        case .engine: return "Engine"
        case .paint: return "Paint"
        case .wheels: return "Wheels"
        case .body: return "Body"
        case .tyres: return "Tyres"
        }
    }
    var icon: String {
        switch self {
        case .engine: return "engine.combustion.fill"
        case .paint: return "paintbrush.pointed.fill"
        case .wheels: return "circle.circle.fill"
        case .body: return "car.side.fill"
        case .tyres: return "arrow.triangle.2.circlepath"
        }
    }
}

struct GarageView: View {
    let ctx: GameContext
    @ObservedObject private var save: SaveStore
    @State private var tab: GarageTab = .engine
    @State private var lastDrag: CGSize = CGSize.zero
    @State private var lastZoom: CGFloat = 1

    init(ctx: GameContext) {
        self.ctx = ctx
        _save = ObservedObject(wrappedValue: ctx.save)
    }

    private var cfg: CarConfig { return save.data.car }

    private func update(_ change: (inout CarConfig) -> Void) {
        var c: CarConfig = save.data.car
        change(&c)
        save.data.car = c
        ctx.car.apply(config: c)
    }

    private func tap() {
        ctx.audio.play(SFX.uiTap, volume: 0.7, rate: 1, position: nil)
    }

    private func poor() {
        ctx.audio.play(SFX.uiError, volume: 0.8, rate: 1, position: nil)
        ctx.input.haptic(HapticKind.error)
        ctx.state.showToast("Not enough money — take on a freelance job at your desk or win a race")
    }

    private func bought() {
        ctx.audio.play(SFX.purchase, volume: 0.9, rate: 1, position: nil)
        ctx.input.haptic(HapticKind.success)
    }

    // MARK: body

    var body: some View {
        let inset: UIEdgeInsets = ScreenInsets.current
        ZStack {
            // drag surface over the whole screen (the car is in the 3D view underneath)
            Color.black.opacity(0.001)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { (v: DragGesture.Value) in
                            let dx: CGFloat = v.translation.width - lastDrag.width
                            let dy: CGFloat = v.translation.height - lastDrag.height
                            lastDrag = v.translation
                            ctx.house.orbit(dx: Float(dx) * 0.008, dy: Float(dy) * 0.004)
                        }
                        .onEnded { _ in lastDrag = CGSize.zero }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { (m: CGFloat) in
                            let d: CGFloat = m - lastZoom
                            lastZoom = m
                            ctx.house.zoom(by: Float(-d) * 4)
                        }
                        .onEnded { _ in lastZoom = 1 }
                )
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    header
                    tabBar
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            tabContent
                        }
                        .padding(.bottom, 6)
                    }
                    footer
                }
                .padding(12)
                .frame(width: 340)
                .glassPanel(tint: Neon.green, radius: 20)
                .padding(.leading, max(inset.left, 12) + 8)
                .padding(.vertical, max(inset.top, 8) + 4)
                Spacer()
                VStack {
                    Spacer()
                    Text("Drag to rotate  •  pinch to zoom")
                        .font(Neon.mono(10, .regular)).foregroundColor(Neon.dim)
                        .padding(.bottom, max(inset.bottom, 8) + 6)
                }
                .padding(.trailing, max(inset.right, 12) + 12)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("GARAGE").font(Neon.font(22, .black)).foregroundColor(.white)
                Text("c0derz  •  Porsche 992 GT3 R").font(Neon.mono(9, .regular)).foregroundColor(Neon.magenta)
            }
            Spacer()
            Text("$\(save.data.money)").font(Neon.mono(17, .heavy)).foregroundColor(Neon.amber)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(GarageTab.allCases) { t in
                Button(action: { tap(); tab = t }) {
                    VStack(spacing: 2) {
                        Image(systemName: t.icon).font(.system(size: 15, weight: .bold))
                        Text(t.title).font(Neon.font(9, .bold))
                    }
                    .foregroundColor(tab == t ? Neon.ink : Neon.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Neon.green : Neon.green.opacity(0.08)))
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: {
                tap()
                let keep: EngineType = save.data.car.engine
                update { (c: inout CarConfig) in
                    c = CarConfig()
                    c.engine = keep
                }
            }) { Text("Reset look") }
                .buttonStyle(NeonButtonStyle(tint: Neon.magenta, compact: true))
            Button(action: {
                ctx.audio.play(SFX.uiConfirm, volume: 0.8, rate: 1, position: nil)
                ctx.closeGarage()
            }) { Label("Done", systemImage: "checkmark") }
                .buttonStyle(NeonButtonStyle(tint: Neon.green, filled: true, compact: true))
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .engine: engineTab
        case .paint: paintTab
        case .wheels: wheelsTab
        case .body: bodyTab
        case .tyres: tyresTab
        }
    }

    // MARK: engine

    private func statBar(_ label: String, _ value: Float, _ maxV: Float, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(Neon.mono(9, .bold)).foregroundColor(Neon.dim).frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(tint).frame(width: geo.size.width * CGFloat(max(0.04, min(1, value / maxV))))
                }
            }
            .frame(height: 5)
            Text(text).font(Neon.mono(9, .bold)).foregroundColor(.white).frame(width: 58, alignment: .trailing)
        }
    }

    private func engineCard(_ type: EngineType) -> some View {
        let spec: EngineSpec = EngineSpec.spec(type)
        let owned: Bool = save.data.ownedEngines.contains(type) || spec.price == 0
        let current: Bool = cfg.engine == type
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(type.rawValue.uppercased()).font(Neon.font(20, .black)).foregroundColor(current ? Neon.green : .white)
                Text(spec.name).font(Neon.font(11, .semibold)).foregroundColor(Neon.dim).lineLimit(1)
                Spacer()
                if current {
                    Text("EQUIPPED").font(Neon.mono(9, .heavy)).foregroundColor(Neon.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Neon.green))
                }
            }
            Text(spec.blurb).font(Neon.font(11, .regular)).foregroundColor(Neon.dim)
            statBar("POWER", spec.powerKW, 900, Neon.red, "\(Int(spec.powerKW * 1.341)) hp")
            statBar("TORQUE", spec.torqueNm, 1100, Neon.amber, "\(Int(spec.torqueNm)) Nm")
            statBar("WEIGHT", 1600 - spec.massKg, 500, Neon.cyan, "\(Int(spec.massKg)) kg")
            statBar("REDLINE", spec.redline, 9500, Neon.magenta, "\(Int(spec.redline)) rpm")
            HStack {
                if owned {
                    if !current {
                        Button(action: { tap(); update { (c: inout CarConfig) in c.engine = type }; ctx.audio.play(SFX.engineStart, volume: 0.6, rate: 1, position: nil) }) {
                            Text("Equip")
                        }
                        .buttonStyle(NeonButtonStyle(tint: Neon.green, compact: true))
                    }
                } else {
                    Button(action: {
                        if ctx.save.spend(spec.price) {
                            var d: SaveData = save.data
                            d.ownedEngines.append(type)
                            save.data = d
                            update { (c: inout CarConfig) in c.engine = type }
                            bought()
                            ctx.state.showToast("\(spec.name) installed")
                        } else { poor() }
                    }) { Text("Buy  $\(spec.price)") }
                        .buttonStyle(NeonButtonStyle(tint: Neon.amber, compact: true))
                }
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(current ? Neon.green.opacity(0.10) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? Neon.green : Neon.faint, lineWidth: 1))
    }

    private var engineTab: some View {
        VStack(spacing: 8) {
            ForEach(EngineType.allCases) { t in engineCard(t) }
        }
    }

    // MARK: paint / wheels

    private let bodyColours: [String] = ["#e8e8ec", "#0b0b0e", "#8a8f98", "#c0121c", "#ff6a00", "#ffd21a", "#39ff88", "#00b7a8", "#22d3ee",
                                         "#1c46d6", "#6b2bd9", "#ff2bd6", "#ff8fb8", "#d4af37", "#3a3f4a", "#f5f0dc"]
    private let rimColours: [String] = ["#151515", "#c9ccd2", "#d4af37", "#ffffff", "#8c5a2b", "#39ff88", "#ff2bd6", "#22d3ee"]
    private let caliperColours: [String] = ["#d40000", "#ffd21a", "#1c6bff", "#39ff88", "#ff7a00", "#ffffff", "#ff2bd6", "#151515"]

    private func swatches(_ colours: [String], selected: String, action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
            ForEach(colours, id: \.self) { hex in
                let on: Bool = hex.lowercased() == selected.lowercased()
                Button(action: { tap(); action(hex) }) {
                    Circle().fill(Color(UIColor(hexString: hex)))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(on ? Neon.green : Color.white.opacity(0.35), lineWidth: on ? 3 : 1))
                        .shadow(color: on ? Neon.green.opacity(0.8) : Color.clear, radius: 6)
                }
            }
        }
    }

    private var paintTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            NeonToggleRow(title: "Race livery", subtitle: "Black + gold Manthey style (turn off for a solid colour)",
                          isOn: Binding<Bool>(get: { cfg.livery }, set: { (v: Bool) in update { (c: inout CarConfig) in c.livery = v } }))
            Text("BODY COLOUR").font(Neon.mono(10, .heavy)).foregroundColor(Neon.cyan)
            swatches(bodyColours, selected: cfg.paint) { (hex: String) in update { (c: inout CarConfig) in c.paint = hex } }
            ColorPicker("Custom colour", selection: Binding<Color>(
                get: { Color(UIColor(hexString: cfg.paint)) },
                set: { (col: Color) in
                    let hex: String = UIColor(col).hexString
                    update { (c: inout CarConfig) in c.paint = hex }
                }), supportsOpacity: false)
                .font(Neon.font(13, .semibold)).foregroundColor(.white)
            NeonPickerRow(title: "Finish", options: PaintFinish.allCases, label: { $0.title },
                          selection: Binding<PaintFinish>(get: { cfg.finish }, set: { (v: PaintFinish) in update { (c: inout CarConfig) in c.finish = v } }))
        }
    }

    private var wheelsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RIM COLOUR").font(Neon.mono(10, .heavy)).foregroundColor(Neon.cyan)
            swatches(rimColours, selected: cfg.rims) { (hex: String) in update { (c: inout CarConfig) in c.rims = hex } }
            Text("BRAKE CALIPERS").font(Neon.mono(10, .heavy)).foregroundColor(Neon.cyan)
            swatches(caliperColours, selected: cfg.caliper) { (hex: String) in update { (c: inout CarConfig) in c.caliper = hex } }
        }
    }

    private var bodyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            NeonSliderRow(title: "Window tint", valueText: "\(Int(cfg.tint * 100))%",
                          value: Binding<Double>(get: { Double(cfg.tint) }, set: { (v: Double) in update { (c: inout CarConfig) in c.tint = Float(v) } }),
                          range: 0...1)
            NeonPickerRow(title: "Rear wing", options: [0, 1, 2], label: { ["None", "GT3", "Big"][$0] },
                          selection: Binding<Int>(get: { cfg.wing }, set: { (v: Int) in update { (c: inout CarConfig) in c.wing = v } }))
            Text("The big wing adds downforce and drag.").font(Neon.font(11, .regular)).foregroundColor(Neon.dim)
        }
    }

    // MARK: tyres

    private var tyresTab: some View {
        VStack(spacing: 8) {
            ForEach(TyreCompound.allCases) { t in
                let owned: Bool = save.data.ownedTyres.contains(t) || t.price == 0
                let current: Bool = cfg.tyres == t
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(t.title.uppercased()).font(Neon.font(18, .black)).foregroundColor(current ? Neon.green : .white)
                        Spacer()
                        if current { Text("EQUIPPED").font(Neon.mono(9, .heavy)).foregroundColor(Neon.green) }
                    }
                    statBar("GRIP", t.grip, 1.8, Neon.green, String(format: "%.2f", t.grip))
                    HStack {
                        if owned {
                            if !current {
                                Button(action: { tap(); update { (c: inout CarConfig) in c.tyres = t } }) { Text("Equip") }
                                    .buttonStyle(NeonButtonStyle(tint: Neon.green, compact: true))
                            }
                        } else {
                            Button(action: {
                                if ctx.save.spend(t.price) {
                                    var d: SaveData = save.data
                                    d.ownedTyres.append(t)
                                    save.data = d
                                    update { (c: inout CarConfig) in c.tyres = t }
                                    bought()
                                } else { poor() }
                            }) { Text("Buy  $\(t.price)") }
                                .buttonStyle(NeonButtonStyle(tint: Neon.amber, compact: true))
                        }
                        Spacer()
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(current ? Neon.green.opacity(0.10) : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? Neon.green : Neon.faint, lineWidth: 1))
            }
        }
    }
}
