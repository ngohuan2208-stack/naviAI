import SwiftUI
import UIKit

struct ProviderConfigView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let config: ProviderConfig

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKeyText: String = ""
    @State private var modelText: String = ""
    @State private var apiFormat: APIMessageFormat = .openAI
    @State private var supportsVision: Bool = false
    @State private var showKey: Bool = false

    @State private var isTesting = false
    @State private var testOutcome: TestOutcome?

    @State private var isFetchingModels = false
    @State private var fetchOutcome: TestOutcome?

    private let llm = LLMService()

    enum TestOutcome: Equatable {
        case success(String)
        case failure(String)
    }

    init(config: ProviderConfig) {
        self.config = config
        _name = State(initialValue: config.name)
        _baseURL = State(initialValue: config.baseURL)
        _modelText = State(initialValue: config.model)
        _apiFormat = State(initialValue: config.apiFormat)
        _supportsVision = State(initialValue: config.supportsVision)
    }

    private var storedKey: String? { app.providers.apiKey(for: config) }

    private var effectiveKey: String {
        apiKeyText.isEmpty ? (storedKey ?? "") : apiKeyText
    }

    private var fetchedModels: [String] {
        app.providers.cachedModels(for: config)
    }

    private var workingConfig: ProviderConfig {
        var c = config
        c.name = name.isEmpty ? config.kind.label : name
        c.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        c.model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        c.apiFormat = apiFormat
        c.supportsVision = supportsVision
        return c
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 40, height: 40)
                        Image(systemName: config.kind.symbol).foregroundStyle(Color.accentColor)
                    }
                    Text(config.kind.label)
                        .font(.headline)
                }
                if config.kind == .custom {
                    TextField("Display name", text: $name)
                }
            }

            Section("Connection") {
                SecureField("API key", text: $apiKeyText)
                    .textContentType(.password)
                if !showKey {
                    Toggle("Show key", isOn: $showKey)
                }
                if let key = storedKey, !key.isEmpty && apiKeyText.isEmpty {
                    Label("A key is stored in the Keychain for this provider.", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Base URL", text: $baseURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if config.kind == .custom {
                    Picker("API format", selection: $apiFormat) {
                        Text(APIMessageFormat.openAI.label).tag(APIMessageFormat.openAI)
                        Text(APIMessageFormat.anthropic.label).tag(APIMessageFormat.anthropic)
                    }
                }
            }

            Section("Model") {
                TextField("Model ID", text: $modelText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))

                if !config.kind.defaultModelSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(config.kind.defaultModelSuggestions, id: \.self) { suggestion in
                                Button {
                                    modelText = suggestion
                                } label: {
                                    Text(suggestion)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(modelText == suggestion ? Color.accentColor : Color(.secondarySystemBackground),
                                                    in: Capsule())
                                        .foregroundStyle(modelText == suggestion ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Toggle("Model supports vision (image input)", isOn: $supportsVision)
            }

            if config.kind.supportsModelListing {
                Section("Models from provider") {
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack {
                            Text("Fetch models from provider")
                            Spacer()
                            if isFetchingModels {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isFetchingModels || effectiveKey.isEmpty || baseURL.isEmpty)

                    if let fetchOutcome {
                        outcomeView(fetchOutcome)
                    }

                    ForEach(fetchedModels.prefix(200), id: \.self) { m in
                        Button {
                            modelText = m
                        } label: {
                            HStack {
                                Text(m).font(.system(.subheadline, design: .monospaced))
                                Spacer()
                                if m == modelText {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if fetchedModels.isEmpty {
                        Text("Fetch to see the models this provider exposes. You can also type a model ID manually - NaviAI never assumes a model exists.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting || modelText.isEmpty || effectiveKey.isEmpty || baseURL.isEmpty)

                if let testOutcome {
                    outcomeView(testOutcome)
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .disabled(modelText.isEmpty || baseURL.isEmpty)
            }
        }
        .navigationTitle(config.kind.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func outcomeView(_ outcome: TestOutcome) -> some View {
        switch outcome {
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.footnote)
        }
    }

    private func testConnection() async {
        isTesting = true
        testOutcome = nil
        let result = await llm.test(config: workingConfig, apiKey: effectiveKey)
        isTesting = false
        switch result {
        case .success(let reply):
            testOutcome = .success("Connected. Model replied: \(reply)")
        case .failure(let err):
            testOutcome = .failure(err.friendlyMessage)
        }
    }

    private func fetchModels() async {
        isFetchingModels = true
        fetchOutcome = nil
        let result = await app.providers.fetchModelIDs(for: workingConfig, apiKeyOverride: apiKeyText.isEmpty ? nil : apiKeyText)
        isFetchingModels = false
        switch result {
        case .success(let models):
            app.providers.applyModels(models, for: config)
            fetchOutcome = .success("Found \(models.count) models.")
        case .failure(let err):
            fetchOutcome = .failure(err.friendlyMessage)
        }
    }

    private func save() {
        var c = workingConfig
        if c.id == config.id, !name.isEmpty {
            c.name = name
        }
        if !apiKeyText.isEmpty {
            app.providers.setAPIKey(apiKeyText, for: c)
        }
        app.providers.upsert(c)
        app.providers.select(c)
        dismiss()
    }
}
