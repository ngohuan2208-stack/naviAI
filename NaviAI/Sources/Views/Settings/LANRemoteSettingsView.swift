import SwiftUI
import Network
import CoreImage.CIFilterBuiltins

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
    @ObservedObject private var server = LANControlServer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                WaterfallEffect()
                    .ignoresSafeArea()
                VStack(spacing: 18) {
                    Text("Scan this QR with your other device:")
                        .font(.headline)
                    if let qr = Self.qrImage(for: server.serverURL) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 168, height: 168)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(14)
                        Text(server.serverURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("Or enter this PIN:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(pairing.pin.isEmpty ? "······" : pairing.pin)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .kerning(6)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    Text(pairing.pinRemainingText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = server.serverURL
                    } label: {
                        Label("Copy address", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Pair Device")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private static func qrImage(for string: String) -> UIImage? {
        guard let filter = CIFilter.qrCodeGenerator() else { return nil }
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct WaterfallEffect: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<14 {
                    let seed = Double(index)
                    let speed = 45 + seed * 11
                    let height = 40 + (seed.truncatingRemainder(dividingBy: 3)) * 22
                    let x = size.width * (0.04 + 0.07 * seed)
                    let travel = size.height + height
                    let y = (now * speed + seed * 97)
                        .truncatingRemainder(dividingBy: travel) - height
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + height))
                    var copy = context
                    copy.stroke(
                        path,
                        with: .color(.blue.opacity(0.16 + 0.1 * (seed.truncatingRemainder(dividingBy: 2)))),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    copy.addFilter(.blur(radius: 0.5))
                    copy.draw(path, with: .color(.blue.opacity(0.1)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
