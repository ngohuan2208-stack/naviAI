import SwiftUI

// MARK: - NaviAI mouse mascot (pure SwiftUI vector)

struct MouseMascotView: View {
    var body: some View {
        ZStack {
            // Ears
            Circle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 14, height: 14)
                .offset(x: -7, y: -13)
            Circle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 14, height: 14)
                .offset(x: 7, y: -13)
            // Body
            Capsule()
                .fill(Color.accentColor.gradient)
                .frame(width: 24, height: 30)
                .offset(y: 2)
            // Belly
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 13, height: 17)
                .offset(y: 6)
            // Eyes
            Circle().fill(.white).frame(width: 6, height: 6).offset(x: -5, y: -5)
            Circle().fill(.white).frame(width: 6, height: 6).offset(x: 5, y: -5)
            Circle().fill(.black).frame(width: 2.6, height: 2.6).offset(x: -5.2, y: -4.6)
            Circle().fill(.black).frame(width: 2.6, height: 2.6).offset(x: 4.8, y: -4.6)
            // Nose + whiskers
            RoundedRectangle(cornerRadius: 1.2)
                .fill(.pink)
                .frame(width: 5, height: 3.2)
                .offset(y: 1.6)
            Capsule().fill(.white.opacity(0.6)).frame(width: 4, height: 1).offset(x: -11, y: 2)
            Capsule().fill(.white.opacity(0.6)).frame(width: 4, height: 1).offset(x: 11, y: 2)
        }
        .frame(width: 32, height: 36)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Cursor overlay drawn on top of the web area

struct AICursorOverlay: View {
    @ObservedObject var store: BrowserStore

    @State private var ringVisible = false
    @State private var ringScale: CGFloat = 0.4
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if store.cursor.visible && store.settings.aiCursorEnabled {
                VStack(spacing: 0) {
                    if let label = store.cursor.label, store.settings.showAgentLabelsEnabled {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: Capsule())
                            .foregroundStyle(.white)
                            .offset(y: -14)
                    }
                    MouseMascotView()
                }
                .position(store.cursor.position)
                .animation(.easeOut(duration: 0.055), value: store.cursor.position)
                .allowsHitTesting(false)
            }
            if ringVisible {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .frame(width: 18, height: 18)
                    .scaleEffect(ringScale)
                    .opacity(ringOpacity)
                    .position(store.cursor.position)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: store.cursor.pulseID) { newValue in
            guard newValue > 0 else { return }
            playRing()
        }
        .allowsHitTesting(false)
    }

    private func playRing() {
        ringVisible = true
        ringScale = 0.4
        ringOpacity = 0.9
        withAnimation(.easeOut(duration: 0.4)) {
            ringScale = 1.9
            ringOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            ringVisible = false
        }
    }
}

// MARK: - Little mouse used in branding / welcome

struct MascotLogoView: View {
    var size: CGFloat = 72
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: size, height: size)
                .shadow(color: .accentColor.opacity(0.5), radius: 14, y: 6)
            MouseMascotView()
                .scaleEffect(size / 64)
        }
    }
}
