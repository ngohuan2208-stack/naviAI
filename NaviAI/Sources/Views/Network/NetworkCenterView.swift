import SwiftUI

// MARK: - Network center

/// Settings + status hub for the Network module: proxy pool, rotation, VPN
/// info (honest), and live status checks. All credentials live in Keychain.
struct NetworkCenterView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var proxy = ProxyManager.shared
    @ObservedObject private var network = NetworkManager.shared
    @ObservedObject private var vpn = VPNManager.shared

    @State private var editorTarget: ProxyProfile?
    @State private var showEditor = false
    @State private var importText = ""
    @State private var testing = false
    @State private var checkRunning = false

    var body: some View {
        Form {
            statusSection
            proxySection
            rotationSection
            poolSection
            importSection
            vpnSection
            limitsSection
        }
        .navigationTitle("Network")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { network.applyProxyToSharedSession() }
        .sheet(isPresented: $showEditor, onDismiss: { editorTarget = nil }) {
            ProxyEditorView(profile: editorTarget) { updated, password in
                proxy.pool.add(updated)
                proxy.setPassword(password, for: updated)
                proxy.persist()
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Internet") {
                Label(
                    network.status.internet ? "Connected" : "Offline",
                    systemImage: network.status.internet ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(network.status.internet ? Color.green : Color.red)
            }
            LabeledContent("Interface") {
                Text(interfaceLabel)
            }
            LabeledContent("VPN (system)") {
                Text(vpn.systemVPNActive ? "Active" : "None")
                    .foregroundStyle(vpn.systemVPNActive ? Color.green : Color.secondary)
            }
            LabeledContent("Proxy (NaviAI)") {
                Text(proxy.enabled && proxy.pool.current != nil
                     ? (proxy.pool.current?.name ?? "On") : "Off")
                    .foregroundStyle(proxy.enabled ? Color.green : Color.secondary)
            }
            if let latency = network.status.latencyMS {
                LabeledContent("Latency") { Text("\(latency) ms") }
            }
            Button {
                checkRunning = true
                Task {
                    await network.runFullCheck()
                    checkRunning = false
                }
            } label: {
                if checkRunning {
                    HStack { ProgressView(); Text("Running check…") }
                } else {
                    Label("Run full check", systemImage: "stethoscope")
                }
            }
        }
    }

    private var interfaceLabel: String {
        switch network.status.interface {
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .wired: return "Wired"
        case .loopback: return "Loopback"
        case .none: return "None"
        case .other: return "Other"
        }
    }

    private var proxySection: some View {
        Section {
            Toggle("Use proxy for app traffic", isOn: Binding(
                get: { proxy.enabled },
                set: { on in
                    proxy.enabled = on
                    proxy.persist()
                    network.applyProxyToSharedSession()
                }))
            if let current = proxy.pool.current {
                LabeledContent("Active", value: current.displayEndpoint)
            }
            Button {
                testing = true
                let target = proxy.pool.current ?? proxy.pool.profiles.first
                Task {
                    if let target {
                        proxy.pool.select(id: target.id)
                        _ = await proxy.testAndRecord(profile: target)
                    }
                    testing = false
                }
            } label: {
                if testing {
                    HStack { ProgressView(); Text("Testing…") }
                } else {
                    Label("Test active proxy", systemImage: "bolt.horizontal")
                }
            }
            .disabled(!proxy.enabled || proxy.pool.profiles.isEmpty || testing)

            if let result = proxy.lastTestResult {
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(result.success ? Color.green : Color.red)
            }
        } header: {
            Text("Proxy")
        } footer: {
            Text("Applies to NaviAI's own requests (AI providers, downloads). WKWebView page traffic cannot be proxied on iOS via public API.")
        }
    }

    private var rotationSection: some View {
        Section("Rotation") {
            Picker("Mode", selection: Binding(
                get: { proxy.pool.rotation },
                set: { mode in
                    proxy.pool.rotation = mode
                    proxy.persist()
                })) {
                ForEach(ProxyRotationMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if proxy.pool.rotation == .timedInterval {
                Stepper("Every \(proxy.pool.rotationIntervalSeconds) s",
                        value: Binding(
                            get: { proxy.pool.rotationIntervalSeconds },
                            set: { secs in
                                proxy.pool.rotationIntervalSeconds = max(30, secs)
                                proxy.persist()
                            }),
                        in: 30...3600, step: 30)
            }
            Button {
                proxy.rotateNow()
            } label: {
                Label("Switch proxy now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(proxy.pool.profiles.count < 2)
            if let switched = proxy.lastSwitchAt {
                LabeledContent("Last switch") {
                    Text(switched, style: .relative)
                }
            }
        }
    }

    private var poolSection: some View {
        Section {
            ForEach(proxy.pool.profiles) { profile in
                Button {
                    editorTarget = profile
                    showEditor = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .foregroundStyle(.primary)
                            Text(profile.displayEndpoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if proxy.pool.current?.id == profile.id, proxy.enabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .onDelete { offsets in
                for idx in offsets {
                    proxy.deleteCredentials(for: proxy.pool.profiles[idx])
                }
                proxy.pool.remove(at: offsets)
                proxy.persist()
            }
            Button {
                editorTarget = nil
                showEditor = true
            } label: {
                Label("Add proxy", systemImage: "plus.circle")
            }
        } header: {
            Text("Proxy pool")
        } footer: {
            Text("Passwords are stored in the iOS Keychain, never in app data or backups of this list.")
        }
    }

    private var importSection: some View {
        Section {
            TextEditor(text: $importText)
                .frame(minHeight: 60)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
            Button {
                importPool()
            } label: {
                Label("Import lines", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(importText.isEmpty)
        } header: {
            Text("Bulk import")
        } footer: {
            Text("One proxy per line: name|http|host|port|user")
        }
    }

    private func importPool() {
        let lines = importText.split(separator: "\n").map(String.init)
        var added = 0
        for line in lines {
            if let profile = ProxyProfile.parse(line: line) {
                proxy.pool.add(profile)
                added += 1
            }
        }
        if added > 0 { proxy.persist() }
        importText = ""
    }

extension NetworkCenterView {

    private var vpnSection: some View {
        Section {
            LabeledContent("Integration") {
                Text(vpn.configuredProvider == .none ? "None (architecture stub)" : vpn.configuredProvider.rawValue)
            }
            LabeledContent("System VPN") {
                Text(vpn.systemVPNActive ? "Detected" : "Not detected")
            }
            if !vpn.dnsServers.isEmpty {
                LabeledContent("DNS") {
                    Text(vpn.dnsServers.prefix(2).joined(separator: ", "))
                        .font(.caption)
                }
            }
        } header: {
            Text("VPN")
        } footer: {
            Text("NaviAI does not ship a VPN. A real one requires Apple's Personal VPN entitlement and a Packet Tunnel Provider extension — this screen reports system state honestly instead of simulating it.")
        }
    }

    private var limitsSection: some View {
        Section("Fair use") {
            Label("Proxy rotation is configuration-only — NaviAI never bypasses CAPTCHAs or anti-bot systems.", systemImage: "hand.raised")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Proxy editor sheet

struct ProxyEditorView: View {
    let profile: ProxyProfile?
    let onSave: (ProxyProfile, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var kind: ProxyProfile.Kind = .http

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Picker("Protocol", selection: $kind) {
                        ForEach(ProxyProfile.Kind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }
                    TextField("Host", text: $host)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section {
                    TextField("Username (optional)", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password (stored in Keychain)", text: $password)
                } header: {
                    Text("Credentials")
                } footer: {
                    Text("Leave empty for anonymous proxies.")
                }
            }
            .navigationTitle(profile == nil ? "Add Proxy" : "Edit Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let portNum = Int(port), portNum > 0, !host.isEmpty else { return }
                        var updated = profile ?? ProxyProfile(name: name, host: host, port: portNum, kind: kind, username: username)
                        updated.name = name
                        updated.host = host
                        updated.port = portNum
                        updated.kind = kind
                        updated.username = username
                        onSave(updated, password)
                        dismiss()
                    }
                    .disabled(name.isEmpty || host.isEmpty || Int(port).map { $0 > 0 } != true)
                }
            }
        }
    }
}
}