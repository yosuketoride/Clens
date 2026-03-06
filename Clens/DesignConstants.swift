import SwiftUI

struct DesignConstants {
    // Colors
    static let backgroundDark = Color(red: 0.05, green: 0.05, blue: 0.08)
    static let cardBackground = Color.white.opacity(0.1)
    static let primaryGradient = LinearGradient(
        gradient: Gradient(colors: [Color.blue, Color.purple]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let secondaryGradient = LinearGradient(
        gradient: Gradient(colors: [Color.purple, Color.pink]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // Glassmorphism effect
    struct GlassModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .background(
                    VisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
                        .opacity(0.8)
                )
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
        }
    }
}

// ぼかし効果のためのUIKitラッパー
struct VisualEffectView: UIViewRepresentable {
    var effect: UIVisualEffect?
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView() }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) { uiView.effect = effect }
}

extension View {
    func glassStyle() -> some View {
        self.modifier(DesignConstants.GlassModifier())
    }
}

class HapticManager {
    static let shared = HapticManager()
    func trigger(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
    
    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}

extension Int64 {
    func formatBytes() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
    
    func formatBytesSmall() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
