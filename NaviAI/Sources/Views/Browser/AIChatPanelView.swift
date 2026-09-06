import SwiftUI
import UIKit

struct AIChatPanelSheet: View {
    @ObservedObject var store: BrowserStore
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if store.turns.isEmpty {
                                emptyState
                            }
                            ForEach(store.turns) { turn in
                                MessageBubble(turn: turn)
                                    .id(turn.id)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: turn.role == .user ? .trailing : .leading)
                                            .combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                        }
                        .padding(12)
                        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: store.turns.count)
                    }
                    .background {
                        if store.turns.isEmpty {
                            AmbientSceneView(intensity: .whisper)
                        }
                    }
                    .onChange(of: store.turns.count) { _ in
                        if let last = store.turns.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                if store.isAgentRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(store.agentStatus.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.agentMode == .auto && store.agentStep > 0 {
                            Text("Step \(store.agentStep)/30")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            store.stopAgent()
                        } label: {
                            Label("STOP", systemImage: "stop.fill")
                                .font(.caption.weight(.heavy))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }

                modePicker
                bottomBar
            }
            .navigationTitle("AI Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if app.providers.activeProvider != nil {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.providers.activeProvider?.name ?? "")
                                .font(.caption.weight(.semibold))
                            Text(app.providers.activeProvider?.model ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            store.clearChat()
                        } label: {
                            Image(systemName: "trash")
                        }
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
        }
        .environmentObject(app)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            MascotLogoView(size: 60)
                .breathing()
            Text("Ask NaviAI to browse for you")
                .font(.headline)
            RotatingGreetingView(
                greetings: [
                    "Example: “Search for the 5 best ways to learn Python and open the best result.”",
                    "Cứ hỏi tự nhiên, Navi hiểu hết 🐭",
                    "Navi có thể tự lướt web giúp bạn đó!"
                ],
                font: .subheadline,
                color: .secondary
            )
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            Button {
                store.chatInput = "Tìm cho tôi cách kiếm tiền online."
                store.submitPrompt(store.chatInput)
                store.chatInput = ""
            } label: {
                Text("Try an example")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            .buttonStyle(BouncyButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .transition(.opacity)
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(AgentMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        store.agentMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.symbol)
                            .font(.caption2)
                        Text(mode.label)
                            .font(.caption.weight(store.agentMode == mode ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        store.agentMode == mode ? Color.accentColor : Color(.secondarySystemBackground),
                        in: Capsule()
                    )
                    .foregroundStyle(store.agentMode == mode ? Color.white : Color.secondary)
                    .scaleEffect(store.agentMode == mode ? 1.05 : 1)
                }
                .buttonStyle(.plain)
                .disabled(store.isAgentRunning)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField("Ask NaviAI…", text: $store.chatInput, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit { submit() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(canSend ? Color.accentColor : Color(.secondarySystemBackground), in: Circle())
                    .foregroundStyle(canSend ? .white : Color.secondary)
            }
            .buttonStyle(BouncyButtonStyle())
            .disabled(!canSend)
        }
        .padding(10)
        .background(.bar)
    }

    private var canSend: Bool {
        !store.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isAgentRunning
    }

    private func submit() {
        let text = store.chatInput
        store.chatInput = ""
        store.submitPrompt(text)
    }
}

struct MessageBubble: View {
    let turn: ChatTurn
    @State private var appeared = false

    var body: some View {
        content
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    appeared = true
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch turn.kind {
        case .text:
            if turn.role == .user {
                HStack {
                    Spacer()
                    Text(turn.text)
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.white)
                }
            } else {
                HStack {
                    Text(turn.text)
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Spacer()
                }
            }
        case .action:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                Text(turn.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 6)
        case .toolResult:
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text(turn.text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 6)
        case .info:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                Text(turn.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
            .background(Color(.secondarySystemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
