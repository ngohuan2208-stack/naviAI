import SwiftUI

struct WelcomeLaunchView: View {
    @EnvironmentObject var app: AppModel

    @State private var command = ""
    @FocusState private var commandFocused: Bool
    @State private var appeared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                        .settleIn(appeared, delay: 0.00)
                    commandBox
                        .settleIn(appeared, delay: 0.05)
                    continueRow
                        .settleIn(appeared, delay: 0.10)
                    quickActions
                        .settleIn(appeared, delay: 0.15)
                    SmartRecentsSection(app: app)
                        .settleIn(appeared, delay: 0.20)
                }
                .padding()
            }
            .background {
                ZStack {
                    Color(.systemGroupedBackground)
                    AmbientSceneView(intensity: .full)
                }
                .ignoresSafeArea()
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .onAppear {
                markVisited()
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    appeared = true
                }
            }
        }
    }

    private func markVisited() {
        app.settings.onboarded = true
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Navi AI")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("Xin chào 👋")
                    .font(.title3.weight(.semibold))
                RotatingGreetingView()
            }
            Spacer()
            MascotLogoView(size: 44)
                .breathing()
        }
        .padding(.top, 8)
    }

    private var commandBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $command)
                .focused($commandFocused)
                .frame(minHeight: 64, maxHeight: 110)
                .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button {
                    submitCommand()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .overlay(alignment: .topLeading) {
            if command.isEmpty && !commandFocused {
                Text("Search the web or ask Navi anything…")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
                    .padding(.leading, 12)
                    .allowsHitTesting(false)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(commandFocused ? 0.55 : 0), lineWidth: 1.5)
        }
        .shadow(color: Color.accentColor.opacity(commandFocused ? 0.22 : 0), radius: 14, y: 4)
        .animation(.easeOut(duration: 0.22), value: commandFocused)
    }

    private var continueRow: some View {
        Group {
            if let item = continueItem {
                Button {
                    item.run(app: app)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.title3)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CONTINUE")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text(item.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(BouncyButtonStyle())
            }
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
            QuickAction(symbol: "magnifyingglass", label: "Tìm kiếm") {
                enterBrowser { app.browser.showsCommandBar = true }
            }
            QuickAction(symbol: "sparkles", label: "Hỏi Navi") {
                enterBrowser { app.browser.showsChatPanel = true }
            }
            QuickAction(symbol: "globe", label: "Mở trang web") {
                enterBrowser { app.browser.showsCommandBar = true }
            }
            QuickAction(symbol: "doc.text.magnifyingglass", label: "Deep Research") {
                enterBrowser { app.browser.showsResearch = true }
            }
            QuickAction(symbol: "bolt", label: "Auto Task") {
                enterBrowser { app.browser.showsAutomation = true }
            }
            QuickAction(symbol: "photo", label: "Phân tích ảnh") {
                enterBrowser { app.browser.showsImageStudio = true }
            }
            QuickAction(symbol: "wrench.and.screwdriver", label: "DevTools") {
                enterBrowser { app.browser.showsDevTools = true }
            }
            QuickAction(symbol: "eye.slash", label: "Private Tab") {
                enterBrowser { app.browser.openPrivateTab() }
            }
        }
    }

    private func enterBrowser(_ configure: @escaping () -> Void) {
        app.browser.showsWelcome = false
        configure()
    }

    private func submitCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        command = ""
        commandFocused = false
        if let intent = AppIntentRouter.detect(text: text) {
            intent.run(app, text)
        } else {

            app.browser.showsWelcome = false
            app.browser.showsChatPanel = true
            app.browser.submitPrompt(text)
        }
    }
}

extension WelcomeLaunchView {

    private var continueItem: SmartRecent? {
        SmartRecentsBuilder.build(app: app).first
    }
}

struct SmartRecent: Identifiable {
    enum Kind {
        case tab, history, chat, report, automation
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let date: Date?
    let action: @MainActor (AppModel) -> Void

    var symbol: String {
        switch kind {
        case .tab: return "macwindow"
        case .history: return "clock.arrow.circlepath"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .report: return "doc.text.magnifyingglass"
        case .automation: return "workflow"
        }
    }

    var kindLabel: String {
        switch kind {
        case .tab: return "Open tab"
        case .history: return "History"
        case .chat: return "Chat"
        case .report: return "Research"
        case .automation: return "Automation"
        }
    }

    @MainActor
    func run(app: AppModel) {
        app.browser.showsWelcome = false
        action(app)
    }
}

enum SmartRecentsBuilder {

    @MainActor
    static func build(app: AppModel, limit: Int = 8) -> [SmartRecent] {
        var items: [SmartRecent] = []
        let browser = app.browser

        for tab in browser.tabs.prefix(3) where tab.url != nil {
            let tabID = tab.id
            let title = tab.title.isEmpty ? (tab.url?.host ?? "Tab") : tab.title
            let subtitle = tab.url?.absoluteString ?? ""
            let date: Date? = nil
            items.append(SmartRecent(
                id: "tab-\(tabID)",
                kind: .tab,
                title: title,
                subtitle: subtitle,
                date: date,
                action: { store in
                    store.browser.selectTab(tabID)
                    store.browser.showsWelcome = false
                }))
        }

        for convo in ConversationStore.shared.conversations.prefix(2) {
            let convoID = convo.id
            let title = convo.title
            let date = convo.updatedAt
            items.append(SmartRecent(
                id: "chat-\(convoID)",
                kind: .chat,
                title: title,
                subtitle: "Chat",
                date: date,
                action: { store in
                    ConversationStore.shared.activeConversationID = convoID
                    store.browser.showsWelcome = false
                    store.browser.showsChatPanel = true
                }))
        }

        for report in DeepResearchEngine.shared.reports.prefix(2) {
            let question = report.question
            let date = report.createdAt
            items.append(SmartRecent(
                id: "report-\(report.id)",
                kind: .report,
                title: question,
                subtitle: "Research report",
                date: date,
                action: { store in
                    store.browser.showsWelcome = false
                    store.browser.showsResearch = true
                }))
        }

        for entry in HistoryStore.shared.entries.prefix(2) {
            let urlText = entry.url
            let title = entry.title.isEmpty ? (URL(string: urlText)?.host ?? "Page") : entry.title
            let date = entry.visitedAt
            items.append(SmartRecent(
                id: "hist-\(urlText)",
                kind: .history,
                title: title,
                subtitle: URL(string: urlText)?.host ?? urlText,
                date: date,
                action: { store in
                    store.browser.loadAddress(urlText)
                    store.browser.showsWelcome = false
                }))
        }

        for run in app.automation.history.prefix(1) {
            let name = run.taskName
            let status = run.status.label
            let date = run.startTime
            items.append(SmartRecent(
                id: "auto-\(run.id)",
                kind: .automation,
                title: name,
                subtitle: status,
                date: date,
                action: { store in
                    store.browser.showsWelcome = false
                    store.browser.showsAutomation = true
                }))
        }

        return items
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }
}

struct SmartRecentsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        let items = SmartRecentsBuilder.build(app: app)
        Group {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Start exploring")
                    Text("Open a tab or ask the AI anything — your recent tabs, chats, reports and history will show up here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Recent")
                    ForEach(items) { item in
                        Button {
                            item.run(app: app)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol)
                                    .frame(width: 26)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.kindLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let date = item.date {
                                    Text(date, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct QuickAction: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

private struct SettleInModifier: ViewModifier {
    let appeared: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(delay), value: appeared)
    }
}

private struct BreathingModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    scale = 1.06
                }
            }
    }
}

extension View {

    func settleIn(_ appeared: Bool, delay: Double = 0) -> some View {
        modifier(SettleInModifier(appeared: appeared, delay: delay))
    }

    func breathing() -> some View {
        modifier(BreathingModifier())
    }
}
