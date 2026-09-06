import SwiftUI
import Network

struct LANRemoteSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var server = LANControlServer.shared
    @ObservedObject private var pairing = LANPairing.shared
    @State private var showPairSheet = false

    var body: some View {
        Form {
            Section {
                Toggle("Remote control (Wi-Fi)", isOn: lanToggle)
                if server.status == .running {
                    LabeledContent("Address", value: server.serverURL)
                    Button {
                        UIPasteboard.general.string = server.serverURL
                    } label: {
                        Label("Copy address", systemImage: "doc.on.doc")
                    }
                }
                switch server.status {
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                case .starting:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Starting server…").foregroundStyle(.secondary)
                    }
                default:
                    EmptyView()
                }
            } header: {
                Text("LAN Server")
            } footer: {
                Text("Other devices on the same Wi-Fi open the address above to mirror and control Navi. The server only listens while NaviAI is running.")
            }

            Section {
                Toggle("Allow observing (read-only)", isOn: $app.settings.lanAllowObserve)
                Toggle("Allow controlling (clicks, typing)", isOn: $app.settings.lanAllowControl)
            } header: {
                Text("Permissions")
            } footer: {
                Text("Observing sends page context and screenshots to paired devices. Controlling lets them drive this browser. Risky actions still require on-device confirmation.")
            }

            Section("Devices") {
                let sessions = server.connectedSessions
                if sessions.isEmpty {
                    Text("No devices connected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        HStack {
                            Image(systemName: "laptopcomputer.and.iphone")
                            VStack(alignment: .leading) {
                                Text(session.deviceName)
                                Text(session.platform + (session.canControl ? " · control" : " · observe"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(session.isConnected ? Color.green : Color.gray)
                                .frame(width: 9, height: 9)
                        }
                    }
                }
            }

            Section {
                Button {
                    pairing.generatePIN()
                    showPairSheet = true
                } label: {
                    Label("Pair a new device", systemImage: "qr.code")
                }
            } footer: {
                Text("A new 6-digit PIN is shown for 5 minutes. Enter it on the device you want to pair.")
            }
        }
        .navigationTitle("LAN Remote Control")
        .sheet(isPresented: $showPairSheet) {
            LANPairSheet()
        }
    }

    private var lanToggle: Binding<Bool> {
        Binding(
            get: { app.settings.lanEnabled },
            set: { on in
                app.settings.lanEnabled = on
                if on {
                    LANControlServer.shared.start(browser: app.browser)
                } else {
                    LANControlServer.shared.stop()
                }
            }
        )
    }
}

struct LANPairSheet: View {
    @ObservedObject private var pairing = LANPairing.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Enter this PIN on your other device:")
                    .font(.headline)
                Text(pairing.pin.isEmpty ? "······" : pairing.pin)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .kerning(6)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                Text(pairing.pinRemainingText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = pairing.pin
                } label: {
                    Label("Copy PIN", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
