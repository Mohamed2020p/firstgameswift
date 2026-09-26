import SwiftUI
import UIKit

// MARK: - Settings: graphics, controls (tilt!), audio, gameplay, credits

enum SettingsTab: String, CaseIterable, Identifiable {
    case graphics, controls, audio, gameplay, credits
    var id: String { return rawValue }
    var title: String {
        switch self {
        case .graphics: return "Graphics"
        case .controls: return "Controls"
        case .audio: return "Audio"
        case .gameplay: return "Gameplay"
        case .credits: return "Credits"
        }
    }
    var icon: String {
        switch self {
        case .graphics: return "sparkles.tv"
        case .controls: return "gamecontroller.fill"
        case .audio: return "speaker.wave.3.fill"
        case .gameplay: return "car.fill"
        case .credits: return "heart.text.square.fill"
        }
    }
}

struct SettingsView: View {
    let ctx: GameContext
    let onClose: () -> Void
    @ObservedObject private var store: SettingsStore
    @State private var tab: SettingsTab

    init(ctx: GameContext, initialTab: SettingsTab, onClose: @escaping () -> Void) {
        self.ctx = ctx
        self.onClose = onClose
        _store = ObservedObject(wrappedValue: ctx.settings)
        _tab = State(initialValue: initialTab)
    }

    // MARK: bindings

    private func bind<T>(_ kp: WritableKeyPath<GameSettings, T>, custom: Bool = false) -> Binding<T> {
        return Binding<T>(
            get: { store.settings[keyPath: kp] },
            set: { (v: T) in
                store.settings[keyPath: kp] = v
                if custom { store.markCustom() }
            })
    }

    private func slider(_ kp: WritableKeyPath<GameSettings, Float>, custom: Bool = false) -> Binding<Double> {
        return Binding<Double>(
            get: { Double(store.settings[keyPath: kp]) },
            set: { (v: Double) in
                store.settings[keyPath: kp] = Float(v)
                if custom { store.markCustom() }
            })
    }

    private func click() {
        ctx.audio.play(SFX.uiTap, volume: 0.7, rate: 1, position: nil)
    }

    // MARK: layout

    var body: some View {
        let inset: UIEdgeInsets = ScreenInsets.current
        ZStack {
            Neon.ink.opacity(0.95)
            VStack(spacing: 0) {
                HStack {
                    Text("SETTINGS").font(Neon.font(24, .black)).foregroundColor(.white)
                    Text("c0derz").font(Neon.mono(12, .bold)).foregroundColor(Neon.magenta)
                    Spacer()
                    Button(action: { ctx.audio.play(SFX.uiBack, volume: 0.8, rate: 1, position: nil); store.saveNow(); onClose() }) {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(NeonButtonStyle(tint: Neon.green, filled: true, compact: true))
                }
                .padding(.horizontal, max(inset.left, 20) + 16)
                .padding(.top, max(inset.top, 8) + 6)
                .padding(.bottom, 8)
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                        .padding(.leading, max(inset.left, 20) + 10)
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 14) {
                            content
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, max(inset.bottom, 10) + 24)
                    }
                    .padding(.trailing, max(inset.right, 12))
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            ForEach(SettingsTab.allCases) { t in
                Button(action: { click(); tab = t }) {
                    HStack(spacing: 8) {
                        Image(systemName: t.icon).frame(width: 20)
                        Text(t.title).font(Neon.font(14, .bold))
                        Spacer()
                    }
                    .foregroundColor(tab == t ? Neon.ink : Neon.green)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(width: 150)
                    .background(RoundedRectangle(cornerRadius: 10).fill(tab == t ? Neon.green : Neon.green.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Neon.green.opacity(0.5), lineWidth: 1))
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .graphics: graphicsTab
        case .controls: controlsTab
        case .audio: audioTab
        case .gameplay: gameplayTab
        case .credits: creditsTab
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(Neon.mono(11, .heavy)).foregroundColor(Neon.cyan)
            body()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(tint: Neon.cyan, radius: 14)
    }

    // MARK: graphics

    private var graphicsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Quality preset") {
                NeonPickerRow(title: "Preset", options: GraphicsPreset.allCases, label: { $0.title },
                              selection: Binding<GraphicsPreset>(get: { store.settings.graphics.preset }, set: { store.applyPreset($0) }))
                Text("Low keeps 60 fps on older iPhones. Ultra turns on 120 fps, 4x MSAA, 4K shadows and motion blur.")
                    .font(Neon.font(11, .regular)).foregroundColor(Neon.dim)
            }
            card("Rendering") {
                NeonSliderRow(title: "Render resolution", valueText: "\(Int(store.settings.graphics.renderScale * 100))%",
                              value: slider(\.graphics.renderScale, custom: true), range: 0.5...1.0)
                NeonPickerRow(title: "Shadows", options: ShadowQuality.allCases, label: { $0.title }, selection: bind(\.graphics.shadows, custom: true))
                NeonPickerRow(title: "Anti-aliasing", options: AntialiasLevel.allCases, label: { $0.title }, selection: bind(\.graphics.antialiasing, custom: true))
                NeonPickerRow(title: "Frame rate cap", options: [30, 60, 120], label: { "\($0) fps" }, selection: bind(\.graphics.fpsCap, custom: true))
                NeonSliderRow(title: "Draw distance", valueText: String(format: "%.1fx", store.settings.graphics.drawDistance),
                              value: slider(\.graphics.drawDistance, custom: true), range: 0.5...1.5)
            }
            card("World detail") {
                NeonPickerRow(title: "Tree detail", options: [0, 1, 2], label: { ["Low", "Medium", "High"][$0] }, selection: bind(\.graphics.treeDetail, custom: true))
                NeonSliderRow(title: "Prop density (applies next launch)", valueText: String(format: "%.0f%%", store.settings.graphics.propDensity * 100),
                              value: slider(\.graphics.propDensity, custom: true), range: 0.3...1.2)
            }
            card("Effects") {
                NeonToggleRow(title: "Reflections", subtitle: "Sky reflections on the paint and glass", isOn: bind(\.graphics.reflections, custom: true))
                NeonToggleRow(title: "Bloom", subtitle: "Glow on neon, lamps and lit windows", isOn: bind(\.graphics.bloom, custom: true))
                NeonToggleRow(title: "HDR", subtitle: "High dynamic range lighting", isOn: bind(\.graphics.hdr, custom: true))
                NeonToggleRow(title: "Motion blur", subtitle: nil, isOn: bind(\.graphics.motionBlur, custom: true))
                NeonToggleRow(title: "Particles", subtitle: "Smoke, sparks, dust and debris", isOn: bind(\.graphics.particles, custom: true))
                NeonToggleRow(title: "Camera shake", subtitle: nil, isOn: bind(\.graphics.cameraShake, custom: true))
            }
        }
    }

    // MARK: controls

    private var controlsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Steering") {
                NeonPickerRow(title: "Steering method", options: SteeringMode.allCases, label: { $0.title }, selection: bind(\.controls.steering))
                if store.settings.controls.steering == .tilt {
                    Text("Hold the phone like a steering wheel and turn it left / right. Press Calibrate while holding it the way you like.")
                        .font(Neon.font(11, .regular)).foregroundColor(Neon.dim)
                    TiltPreview(steer: ctx.input.steerVisuals)
                    HStack(spacing: 10) {
                        Button(action: { click(); ctx.input.calibrateTilt(); ctx.input.haptic(HapticKind.success) }) {
                            Label("Calibrate tilt", systemImage: "scope")
                        }
                        .buttonStyle(NeonButtonStyle(tint: Neon.cyan, compact: true))
                        Text(ctx.input.tiltAvailable ? "Motion sensors ready" : "No motion sensor: use the touch wheel")
                            .font(Neon.mono(10, .regular)).foregroundColor(ctx.input.tiltAvailable ? Neon.green : Neon.amber)
                    }
                    NeonSliderRow(title: "Tilt sensitivity", valueText: String(format: "%.2fx", store.settings.controls.tiltSensitivity),
                                  value: slider(\.controls.tiltSensitivity), range: 0.3...2.5)
                    NeonSliderRow(title: "Full-lock angle", valueText: "\(Int(store.settings.controls.tiltRangeDegrees))°",
                                  value: slider(\.controls.tiltRangeDegrees), range: 15...60)
                    NeonSliderRow(title: "Dead zone", valueText: String(format: "%.0f%%", store.settings.controls.tiltDeadzone * 100),
                                  value: slider(\.controls.tiltDeadzone), range: 0...0.2)
                    NeonSliderRow(title: "Smoothing", valueText: String(format: "%.0f%%", store.settings.controls.tiltSmoothing * 100),
                                  value: slider(\.controls.tiltSmoothing), range: 0...1)
                } else {
                    NeonSliderRow(title: "Touch steering sensitivity", valueText: String(format: "%.2fx", store.settings.controls.touchSteerSensitivity),
                                  value: slider(\.controls.touchSteerSensitivity), range: 0.4...2.0)
                }
            }
            card("Camera and feedback") {
                NeonSliderRow(title: "Camera sensitivity", valueText: String(format: "%.2fx", store.settings.controls.cameraSensitivity),
                              value: slider(\.controls.cameraSensitivity), range: 0.3...2.5)
                NeonToggleRow(title: "Invert vertical look", subtitle: nil, isOn: bind(\.controls.invertLookY))
                NeonToggleRow(title: "Haptics", subtitle: "Vibration for crashes, gear shifts and UI", isOn: bind(\.controls.haptics))
            }
            card("On-screen controls") {
                NeonSliderRow(title: "HUD / button size", valueText: String(format: "%.0f%%", store.settings.controls.hudScale * 100),
                              value: slider(\.controls.hudScale), range: 0.7...1.4)
                NeonSliderRow(title: "Control opacity", valueText: String(format: "%.0f%%", store.settings.controls.controlOpacity * 100),
                              value: slider(\.controls.controlOpacity), range: 0.3...1.0)
                NeonToggleRow(title: "Left-handed layout", subtitle: "Swaps the pedal and steering sides", isOn: bind(\.controls.leftHanded))
                NeonToggleRow(title: "Auto throttle", subtitle: "The car accelerates by itself", isOn: bind(\.controls.autoThrottle))
            }
        }
    }

    // MARK: audio

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Volume") {
                NeonSliderRow(title: "Master", valueText: "\(Int(store.settings.audio.master * 100))%", value: slider(\.audio.master), range: 0...1)
                NeonSliderRow(title: "Engine and tyres", valueText: "\(Int(store.settings.audio.engine * 100))%", value: slider(\.audio.engine), range: 0...1)
                NeonSliderRow(title: "Effects", valueText: "\(Int(store.settings.audio.sfx * 100))%", value: slider(\.audio.sfx), range: 0...1)
                NeonSliderRow(title: "Music", valueText: "\(Int(store.settings.audio.music * 100))%", value: slider(\.audio.music), range: 0...1)
                NeonSliderRow(title: "Ambience", valueText: "\(Int(store.settings.audio.ambience * 100))%", value: slider(\.audio.ambience), range: 0...1)
            }
            card("Test") {
                HStack(spacing: 10) {
                    Button(action: { ctx.audio.start(); ctx.audio.play(SFX.horn, volume: 0.9, rate: 1, position: nil) }) { Text("Horn") }
                        .buttonStyle(NeonButtonStyle(tint: Neon.magenta, compact: true))
                    Button(action: { ctx.audio.start(); ctx.audio.play(SFX.crashMetalLight, volume: 0.9, rate: 1, position: nil) }) { Text("Crash") }
                        .buttonStyle(NeonButtonStyle(tint: Neon.amber, compact: true))
                    Button(action: { ctx.audio.start(); ctx.audio.play(SFX.raceWin, volume: 0.9, rate: 1, position: nil) }) { Text("Fanfare") }
                        .buttonStyle(NeonButtonStyle(tint: Neon.green, compact: true))
                }
            }
        }
    }

    // MARK: gameplay

    private var gameplayTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Driving") {
                NeonPickerRow(title: "Speed unit", options: SpeedUnit.allCases, label: { $0.title }, selection: bind(\.gameplay.units))
                NeonPickerRow(title: "Default camera", options: CameraView.allCases, label: { $0.title }, selection: bind(\.gameplay.defaultView))
                NeonToggleRow(title: "Traction control", subtitle: nil, isOn: bind(\.gameplay.tractionControl))
                NeonToggleRow(title: "ABS", subtitle: nil, isOn: bind(\.gameplay.abs))
                NeonSliderRow(title: "Stability assist", valueText: String(format: "%.0f%%", store.settings.gameplay.stability * 100),
                              value: slider(\.gameplay.stability), range: 0...1)
                NeonToggleRow(title: "Crash damage", subtitle: "Hitting things hurts the car", isOn: bind(\.gameplay.damage))
                NeonSliderRow(title: "Field of view", valueText: String(format: "%.2fx", store.settings.gameplay.fovScale),
                              value: slider(\.gameplay.fovScale), range: 0.8...1.2)
            }
            card("World") {
                NeonToggleRow(title: "Minimap", subtitle: nil, isOn: bind(\.gameplay.showMinimap))
                NeonSliderRow(title: "Opponent skill", valueText: String(format: "%.0f%%", store.settings.gameplay.opponentSkill * 100),
                              value: slider(\.gameplay.opponentSkill), range: 0.6...1.0)
                NeonSliderRow(title: "Day length", valueText: "\(Int(store.settings.gameplay.dayLengthMinutes)) min",
                              value: slider(\.gameplay.dayLengthMinutes), range: 6...60)
            }
            card("Reset") {
                Button(action: { click(); store.resetToDefaults() }) { Text("Reset all settings to default") }
                    .buttonStyle(NeonButtonStyle(tint: Neon.red, compact: true))
            }
        }
    }

    // MARK: credits

    private func creditRow(_ title: String, _ author: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Neon.font(15, .heavy)).foregroundColor(.white)
            Text("by \(author)").font(Neon.font(12, .semibold)).foregroundColor(Neon.green)
            Text(note).font(Neon.mono(10, .regular)).foregroundColor(Neon.dim)
        }
    }

    private var creditsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Supercars") {
                Text("A native iPhone game written in Swift with SceneKit, SwiftUI and AVAudioEngine.")
                    .font(Neon.font(13, .regular)).foregroundColor(.white)
                Text("Design, code, world, physics, sound synthesis and the c0derz house: c0derz")
                    .font(Neon.font(13, .semibold)).foregroundColor(Neon.green)
                Text("</>  c0derz").font(Neon.mono(20, .heavy)).foregroundColor(Neon.magenta)
            }
            card("3D models (CC BY 4.0)") {
                creditRow("2024 Porsche 992 GT3 R", "Dave Love (Tyler_Dave)", "Sketchfab · CC BY 4.0 · optimised and re-rigged for mobile")
                creditRow("bike rider 3d", "Atrikumar Das (ganash3691)", "Sketchfab · CC BY 4.0 · the player character")
                creditRow("Buildings", "Elbolillo", "Sketchfab · CC BY 4.0 · city buildings")
                creditRow("Mango Tree", "stealth86", "Sketchfab · CC BY 4.0 · trees")
            }
            card("Sound") {
                Text("Every sound effect, engine, ambience and music track in this game is synthesised from scratch (no samples).")
                    .font(Neon.font(13, .regular)).foregroundColor(.white)
            }
            card("Version") {
                Text("Supercars 1.0  •  built with Bitrise (unsigned IPA)").font(Neon.mono(11, .regular)).foregroundColor(Neon.dim)
            }
        }
    }
}

struct TiltPreview: View {
    @ObservedObject var steer: SteerVisuals

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Live tilt").font(Neon.font(12, .semibold)).foregroundColor(.white)
                Spacer()
                Text(String(format: "%+.0f°", steer.tiltRollDegrees)).font(Neon.mono(12, .bold)).foregroundColor(Neon.cyan)
            }
            GeometryReader { geo in
                ZStack {
                    Capsule().fill(Color.white.opacity(0.12))
                    Rectangle().fill(Color.white.opacity(0.5)).frame(width: 2)
                    Circle().fill(Neon.green).frame(width: 20, height: 20)
                        .offset(x: CGFloat(max(-1, min(1, steer.tilt))) * -(geo.size.width * 0.5 - 12))
                        .shadow(color: Neon.green, radius: 6)
                }
            }
            .frame(height: 20)
        }
    }
}
