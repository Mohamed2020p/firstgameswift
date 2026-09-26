import SwiftUI
import UIKit

// MARK: - The c0derz look: neon green / magenta / cyan on near-black glass panels.

enum Neon {
    static let green = Color(red: 0.22, green: 1.0, blue: 0.53)
    static let magenta = Color(red: 1.0, green: 0.17, blue: 0.84)
    static let cyan = Color(red: 0.17, green: 0.90, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.10)
    static let red = Color(red: 1.0, green: 0.22, blue: 0.28)
    static let ink = Color(red: 0.02, green: 0.025, blue: 0.04)
    static let panel = Color(red: 0.043, green: 0.055, blue: 0.086)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.14)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        return Font.system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        return Font.system(size: size, weight: weight, design: .monospaced)
    }
}

enum ScreenInsets {
    @MainActor
    static var current: UIEdgeInsets {
        let scene: UIWindowScene? = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window: UIWindow? = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        return window?.safeAreaInsets ?? UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

struct NeonButtonStyle: ButtonStyle {
    var tint: Color = Neon.green
    var filled: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed: Bool = configuration.isPressed
        return configuration.label
            .font(Neon.font(compact ? 14 : 17, .heavy))
            .foregroundColor(filled ? Neon.ink : tint)
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 8 : 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(filled ? tint : tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint, lineWidth: 1.5))
            .shadow(color: tint.opacity(pressed ? 0.9 : 0.4), radius: pressed ? 14 : 7)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

struct GlassPanel: ViewModifier {
    var tint: Color = Neon.green
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Neon.panel.opacity(0.84))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(LinearGradient(colors: [tint.opacity(0.9), Neon.magenta.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
            )
            .shadow(color: tint.opacity(0.18), radius: 14)
    }
}

extension View {
    func glassPanel(tint: Color = Neon.green, radius: CGFloat = 18) -> some View {
        modifier(GlassPanel(tint: tint, radius: radius))
    }
}

/// The animated "SUPERCARS" wordmark with the c0derz signature.
struct LogoView: View {
    var size: CGFloat = 64
    @State private var pulse: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SUPERCARS")
                .font(.system(size: size, weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(LinearGradient(colors: [Neon.green, Neon.cyan, Neon.magenta], startPoint: .leading, endPoint: .trailing))
                .shadow(color: Neon.green.opacity(pulse ? 0.85 : 0.35), radius: pulse ? 22 : 10)
            HStack(spacing: 8) {
                Text("</>")
                    .font(Neon.mono(size * 0.30, .heavy))
                    .foregroundColor(Neon.magenta)
                Text("by c0derz")
                    .font(Neon.mono(size * 0.28, .semibold))
                    .foregroundColor(Neon.dim)
            }
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct NeonToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Neon.font(15, .semibold)).foregroundColor(.white)
                if let s = subtitle { Text(s).font(Neon.font(11, .regular)).foregroundColor(Neon.dim) }
            }
        }
        .tint(Neon.green)
    }
}

struct NeonSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Neon.font(15, .semibold)).foregroundColor(.white)
                Spacer()
                Text(valueText).font(Neon.mono(13, .bold)).foregroundColor(Neon.green)
            }
            Slider(value: $value, in: range).tint(Neon.green)
        }
    }
}

struct NeonPickerRow<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Neon.font(15, .semibold)).foregroundColor(.white)
            HStack(spacing: 6) {
                ForEach(options.indices, id: \.self) { i in
                    let opt: T = options[i]
                    let on: Bool = opt == selection
                    Button(action: { selection = opt }) {
                        Text(label(opt))
                            .font(Neon.font(12, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(on ? Neon.ink : Neon.green)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Neon.green : Neon.green.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Neon.green.opacity(on ? 1 : 0.4), lineWidth: 1))
                    }
                }
            }
        }
    }
}

extension Binding where Value == Float {
    /// Slider helper: Float property -> Double binding
    func asDouble() -> Binding<Double> {
        return Binding<Double>(get: { Double(self.wrappedValue) }, set: { self.wrappedValue = Float($0) })
    }
}
