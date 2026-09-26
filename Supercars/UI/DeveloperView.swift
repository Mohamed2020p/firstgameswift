import SwiftUI

// MARK: - Developer tools panel (hidden: see DeveloperMode).  Compact grid of test actions; every action is local and offline.

struct DeveloperView: View {
    let ctx: GameContext
    @ObservedObject private var dev: DeveloperMode

    init(ctx: GameContext) {
        self.ctx = ctx
        _dev = ObservedObject(wrappedValue: ctx.dev ?? DeveloperMode(ctx: ctx))
    }

    private func close() {
        ctx.state.screen = .pause
    }

    private func act(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: {
            ctx.audio.play(SFX.uiTap, volume: 0.6, rate: 1, position: nil)
            action()
        }) {
            Text(title).font(Neon.font(12, .medium)).frame(maxWidth: .infinity)
        }
        .buttonStyle(NeonButtonStyle(compact: true))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Neon.font(10, .semibold)).tracking(1.5).foregroundColor(Neon.dim)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 10)
    }

    private var columns: [GridItem] {
        return [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        let inset: UIEdgeInsets = ScreenInsets.current
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 10) {
                HStack {
                    Text("DEVELOPER").font(Neon.font(20, .semibold)).tracking(3).foregroundColor(.white)
                    Text("local test tools").font(Neon.font(11, .regular)).foregroundColor(Neon.dim)
                    Spacer()
                    Button(action: { close() }) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(NeonButtonStyle(filled: true, compact: true))
                }
                Text(dev.statusLine).font(Neon.mono(10, .regular)).foregroundColor(Neon.dim).frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    VStack(spacing: 10) {
                        section("Wanted level") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                                ForEach(0..<6, id: \.self) { i in
                                    act("\(i)★") { dev.setWanted(i) }
                                }
                            }
                            LazyVGrid(columns: columns, spacing: 6) {
                                act("Clear police") { dev.clearPolice() }
                                act("Spawn taxi") { dev.spawnTaxi() }
                                act("Spawn police") { dev.spawnPolice() }
                            }
                            NeonToggleRow(title: "Freeze wanted level", subtitle: "no decay, no escalation", isOn: Binding<Bool>(get: { dev.freezeWanted }, set: { dev.setFreeze($0) }))
                        }
                        section("Teleport") {
                            LazyVGrid(columns: columns, spacing: 6) {
                                act("Race start") { dev.teleportToRace(); ctx.state.screen = .none; ctx.resume() }
                                act("Home") { dev.teleportHome(); ctx.state.screen = .none; ctx.resume() }
                                act("Garage") { dev.teleportGarage(); ctx.state.screen = .none; ctx.resume() }
                                act("Downtown") { dev.teleportDowntown(); ctx.state.screen = .none; ctx.resume() }
                                act("Police station") { dev.teleportPolice(); ctx.state.screen = .none; ctx.resume() }
                            }
                        }
                        section("Vehicle and economy") {
                            LazyVGrid(columns: columns, spacing: 6) {
                                act("Repair car") { dev.repairCar() }
                                act("Reset car") { dev.resetCar() }
                                act("Unlock all") { dev.unlockVehicles() }
                                act("Money $1M") { dev.setMoney(1_000_000) }
                                act("Money $999M") { dev.setMoney(999_999_999) }
                            }
                        }
                        section("World") {
                            LazyVGrid(columns: columns, spacing: 6) {
                                act("Day 09:00") { dev.setTime(9) }
                                act("Sunset 18:30") { dev.setTime(18.5) }
                                act("Night 23:00") { dev.setTime(23) }
                            }
                            HStack(spacing: 6) {
                                ForEach(WeatherKind.allCases, id: \.rawValue) { w in
                                    Button(action: { dev.setWeather(w) }) {
                                        Text(w.title).font(Neon.font(12, .medium)).frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(NeonButtonStyle(filled: dev.weather == w, compact: true))
                                }
                            }
                            NeonToggleRow(title: "Pedestrians", subtitle: nil, isOn: Binding<Bool>(get: { dev.npcsEnabled }, set: { dev.setNPCs($0) }))
                            NeonToggleRow(title: "Taxis (traffic)", subtitle: nil, isOn: Binding<Bool>(get: { dev.trafficEnabled }, set: { dev.setTraffic($0) }))
                            NeonToggleRow(title: "Police", subtitle: nil, isOn: Binding<Bool>(get: { dev.policeEnabled }, set: { dev.setPolice($0) }))
                        }
                    }
                }
            }
            .padding(.horizontal, max(inset.left, 20) + 8)
            .padding(.vertical, max(inset.top, 14) + 4)
            .frame(maxWidth: 640)
        }
    }
}
