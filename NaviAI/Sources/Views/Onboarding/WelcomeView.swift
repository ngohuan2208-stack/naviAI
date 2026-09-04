import SwiftUI

struct OnboardingRootView: View {
    var body: some View {
        NavigationStack {
            WelcomeView()
        }
    }
}

struct WelcomeView: View {
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var floatOffset: CGFloat = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(uiColor: .systemBackground),
                Color.accentColor.opacity(0.16)
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()
                MascotLogoView(size: 108)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .offset(y: floatOffset)
                    .onAppear {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                            logoScale = 1
                            logoOpacity = 1
                        }
                        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                            floatOffset = -10
                        }
                    }

                VStack(spacing: 6) {
                    Text("NaviAI")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                    Text("Your AI-powered browser.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .opacity(textOpacity)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.7).delay(0.3)) {
                        textOpacity = 1
                    }
                }

                Spacer()

                NavigationLink {
                    ChooseAIView()
                } label: {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .opacity(textOpacity)
            }
        }
    }
}
