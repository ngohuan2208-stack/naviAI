import SwiftUI

// MARK: - Ambient scene: waterfall backdrop + drifting birds
//
// A single reusable "living background" for the app's calmer surfaces
// (Welcome, empty chat state). It reads as a quiet waterfall behind soft
// mist, with a couple of birds drifting across on a slow loop, and settles
// into stillness when the environment prefers reduced motion.

struct AmbientSceneView: View {
    var intensity: Intensity = .full

    enum Intensity {
        case full        // Welcome screen: full waterfall + birds
        case whisper      // Chat/browser: faint wash, birds only, no ribbons
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion)) { context in
            Canvas { gfx, size in
                drawWash(&gfx, size: size)
                if intensity == .full {
                    drawFalls(&gfx, size: size, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
            .overlay {
                if !reduceMotion {
                    BirdFlockView(whisper: intensity == .whisper)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawWash(_ gfx: inout GraphicsContext, size: CGSize) {
        let topColor = Color.accentColor.opacity(intensity == .full ? 0.22 : 0.10)
        let bottomColor = Color.accentColor.opacity(intensity == .full ? 0.05 : 0.02)
        let rect = CGRect(origin: .zero, size: size)
        gfx.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [topColor, bottomColor, .clear]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    /// Three loosely-spaced ribbons of light sliding downward, each built
    /// from short dashes so it reads as falling water rather than a bar.
    private func drawFalls(_ gfx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let laneCount = 3
        let laneWidth = size.width / CGFloat(laneCount + 1)

        for lane in 0..<laneCount {
            let x = laneWidth * CGFloat(lane + 1) + sinWobble(lane: lane, time: time) * 10
            let speed: CGFloat = reduceMotion ? 0 : (46 + CGFloat(lane) * 14)
            let phase = CGFloat(time) * speed
            let dashLength: CGFloat = 30
            let gap: CGFloat = 22
            let period = dashLength + gap

            var y = -period + phase.truncatingRemainder(dividingBy: period) - period
            while y < size.height + dashLength {
                let opacity = 0.10 + 0.08 * Double(lane == 1 ? 1 : 0)
                var path = Path()
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + dashLength))
                gfx.stroke(
                    path,
                    with: .color(Color.white.opacity(opacity)),
                    style: StrokeStyle(lineWidth: lane == 1 ? 3 : 2, lineCap: .round)
                )
                y += period
            }
        }

        // Soft mist glow where the falls would meet a pool, near the bottom.
        let mistRect = CGRect(x: 0, y: size.height - 70, width: size.width, height: 70)
        gfx.fill(
            Path(ellipseIn: mistRect.insetBy(dx: -size.width * 0.2, dy: 0)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.10), .clear]),
                center: CGPoint(x: size.width / 2, y: size.height - 20),
                startRadius: 0,
                endRadius: size.width * 0.6
            )
        )
    }

    private func sinWobble(lane: Int, time: TimeInterval) -> CGFloat {
        CGFloat(sin(time * 0.4 + Double(lane) * 2.1))
    }
}

// MARK: - Drifting birds

private struct BirdFlockView: View {
    var whisper: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                DriftingBird(
                    yFraction: 0.16, duration: 15, delay: 0,
                    scale: whisper ? 0.6 : 0.85, opacity: whisper ? 0.35 : 0.55,
                    width: geo.size.width
                )
                DriftingBird(
                    yFraction: 0.27, duration: 21, delay: 6,
                    scale: whisper ? 0.45 : 0.6, opacity: whisper ? 0.25 : 0.4,
                    width: geo.size.width
                )
                if !whisper {
                    DriftingBird(
                        yFraction: 0.10, duration: 26, delay: 12,
                        scale: 0.5, opacity: 0.32,
                        width: geo.size.width
                    )
                }
            }
        }
    }
}

private struct DriftingBird: View {
    let yFraction: CGFloat
    let duration: Double
    let delay: Double
    let scale: CGFloat
    let opacity: Double
    let width: CGFloat

    @State private var progress: CGFloat = 0
    @State private var wingUp = false

    var body: some View {
        BirdShape(wingUp: wingUp)
            .stroke(Color.primary.opacity(opacity), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 22, height: 10)
            .scaleEffect(scale)
            .position(
                x: -30 + progress * (width + 60),
                y: yFraction * 500
            )
            .onAppear {
                withAnimation(.linear(duration: duration).delay(delay).repeatForever(autoreverses: false)) {
                    progress = 1
                }
                withAnimation(.easeInOut(duration: 0.28).delay(delay).repeatForever(autoreverses: true)) {
                    wingUp = true
                }
            }
    }
}

/// A simple two-stroke "M" bird, wings flapping between up and flat.
private struct BirdShape: Shape {
    var wingUp: Bool

    var animatableData: Double {
        get { wingUp ? 1 : 0 }
        set { }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = wingUp ? rect.minY + rect.height * 0.15 : rect.midY
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: midY),
            control: CGPoint(x: rect.minX + rect.width * 0.25, y: midY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - rect.width * 0.25, y: midY)
        )
        return path
    }
}

// MARK: - iOS 16-safe "pulse while active" effect
//
// SwiftUI's `.symbolEffect` needs iOS 17+, but this project targets iOS 16,
// so active/running indicators use this instead: a gentle opacity + scale
// breathing animation that starts and stops with `isActive`.

private struct PulseWhenActiveModifier: ViewModifier {
    var isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 0.45 : 1)
            .scaleEffect(pulsing ? 0.85 : 1)
            .onAppear { sync() }
            .onChange(of: isActive) { _ in sync() }
    }

    private func sync() {
        guard isActive, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { pulsing = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

extension View {
    /// A small looping breathe effect for icons that represent "in progress"
    /// state (e.g. the agent status glyph, the waveform icon).
    func pulsingWhileActive(_ isActive: Bool) -> some View {
        modifier(PulseWhenActiveModifier(isActive: isActive))
    }
}

// MARK: - Rotating Vietnamese greeting

/// Cycles through a short list of warm, casual greetings. Height is fixed
/// to the tallest line so surrounding layout never jumps.
struct RotatingGreetingView: View {
    static let defaultGreetings = [
        "Bạn muốn làm gì hôm nay?",
        "Hôm nay có gì hay ho không?",
        "Cứ nói, Navi nghe đây 🐭",
        "Rảnh chưa? Lướt web tí nào!",
        "Có việc gì cần Navi giúp không?"
    ]

    var greetings: [String] = RotatingGreetingView.defaultGreetings
    var font: Font = .subheadline
    var color: Color = .secondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    var body: some View {
        ZStack {
            ForEach(Array(greetings.enumerated()), id: \.offset) { offset, text in
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .opacity(offset == index ? 1 : 0)
                    .offset(y: offset == index ? 0 : 6)
                    .allowsHitTesting(offset == index)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            guard !reduceMotion, greetings.count > 1 else { return }
            scheduleNext()
        }
    }

    private func scheduleNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            withAnimation(.easeInOut(duration: 0.5)) {
                index = (index + 1) % greetings.count
            }
            scheduleNext()
        }
    }
}
