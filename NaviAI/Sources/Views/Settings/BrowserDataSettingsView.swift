import SwiftUI
import UniformTypeIdentifiers

struct BrowserDataSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var pendingItems: [ImportedBookmark] = []
    @State private var pendingInvalid = 0
    @State private var showImportConfirm = false
    @State private var report: ImportReport?
    @State private var exportError: String?

    static let importTypes: [UTType] = [.html, .json, .data]
    static let exportType = UTType(exportedAs: "com.naviai.export", conformingTo: .json)

    var body: some View {
        Form {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Import from Safari…", systemImage: "square.and.arrow.down")
                }
                Button {
                    showExporter = true
                } label: {
                    Label("Export Navi data…", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Browser Data")
            } footer: {
                Text("Import bookmarks from Safari's HTML export, or export Navi's bookmarks, history and conversations as JSON. API keys and secrets are never included.")
            }

            if let report {
                Section("Last import") {
                    Text(report.summary)
                        .font(.footnote)
                    Text(report.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let exportError {
                Section {
                    Text(exportError).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle("Browser Data")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                handlePickedFile(url)
            case .failure(let error):
                exportError = "Import failed: \(error.localizedDescription)"
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: ExportDocument(data: exportData()),
                      contentType: Self.exportType,
                      defaultFilename: "navi-export") { result in
            if case .failure(let error) = result {
                exportError = "Export failed: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Import \(pendingItems.count) bookmark(s)?",
                            isPresented: $showImportConfirm,
                            titleVisibility: .visible) {
            Button("Import \(pendingItems.count) bookmarks") {
                let mgr = BrowserDataManager.shared
                report = mgr.confirmImport(pendingItems, into: app.browser)
                pendingItems = []
            }
            Button("Cancel", role: .cancel) { pendingItems = [] }
        } message: {
            Text("Duplicates will be skipped.\(pendingInvalid > 0 ? " \(pendingInvalid) invalid entries will be skipped." : "")")
        }
    }

    private func handlePickedFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            exportError = "Could not open the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let (items, invalid) = BrowserDataManager.shared.preview(data)
            guard !items.isEmpty else {
                exportError = "No readable bookmarks found in that file."
                return
            }
            exportError = nil
            pendingItems = items
            pendingInvalid = invalid
            showImportConfirm = true
        } catch {
            exportError = "Could not read file: \(error.localizedDescription)"
        }
    }

    private func exportData() -> Data? {
        BrowserDataManager.shared.buildExport(browser: app.browser)
    }
}

struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data?

    init(data: Data?) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        return FileWrapper(regularFileWithContents: data)
    }
}
