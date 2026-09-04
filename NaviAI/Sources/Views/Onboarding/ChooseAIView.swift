import SwiftUI

struct ChooseAIView: View {
    @EnvironmentObject var app: AppModel
    @State private var providerDestination: ProviderConfig?
    @State private var customAdding = false

    private var configuredCount: Int {
        app.providers.providers.filter { app.providers.hasKey(for: $0) }.count
    }

    var body: some View {
        List {
            Section {
                ForEach(app.providers.providers) { provider in
                    Button {
                        providerDestination = provider
                    } label: {
                        ProviderRow(provider: provider, hasKey: app.providers.hasKey(for: provider))
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if app.providers.providers.count > 1 {
                            Button(role: .destructive) {
                                app.providers.remove(provider)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Choose your AI")
            } footer: {
                Text("Pick a provider and add your API key. Keys are stored in the iOS Keychain - never in app storage or in plain text.")
            }

            Section {
                Button {
                    let custom = app.providers.makeProvider(of: .custom)
                    providerDestination = custom
                } label: {
                    Label("Add Custom API", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Choose your AI")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Skip") { app.settings.onboarded = true }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(configuredCount > 0 ? "Continue" : "Continue later") {
                    app.settings.onboarded = true
                }
                .fontWeight(.semibold)
            }
        }
        .navigationDestination(item: $providerDestination) { provider in
            ProviderConfigView(config: provider)
        }
        .onAppear {
            _ = customAdding
        }
    }
}

struct ProviderRow: View {
    let provider: ProviderConfig
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: provider.kind.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.body.weight(.semibold))
                Text(provider.model.isEmpty ? "No model set" : provider.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasKey {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}
