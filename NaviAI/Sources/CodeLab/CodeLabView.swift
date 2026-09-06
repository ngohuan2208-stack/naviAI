import SwiftUI

// MARK: - Code Lab Panel

struct CodeLabView: View {
    @ObservedObject var store: CodeLabStore
    @State private var showHistory = false
    @State private var showSaveDialog = false
    @State private var saveTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Language", selection: $store.currentLanguage) {
                    ForEach(CodeLanguage.allCases) { lang in
                        Label(lang.displayName, systemImage: lang.icon).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: store.currentLanguage) { _, newLang in
                    store.changeLanguage(newLang)
                }

                Spacer()

                Button {
                    Task { await store.runCurrent() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isRunning)

                Button { showHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }

                Button { saveTitle = ""; showSaveDialog = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))

            VStack(spacing: 0) {
                CodeEditor(text: $store.currentCode, language: store.currentLanguage)
                    .frame(minHeight: 200)
                Divider()
                CodeOutputView(result: store.lastResult, isRunning: store.isRunning)
                    .frame(maxHeight: 200)
            }
        }
        .sheet(isPresented: $showHistory) {
            CodeLabHistoryView(store: store)
        }
        .alert("Save Snippet", isPresented: $showSaveDialog) {
            TextField("Title", text: $saveTitle)
            Button("Save") {
                store.saveSnippet(title: saveTitle.isEmpty ? "Untitled" : saveTitle, code: store.currentCode, language: store.currentLanguage)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct CodeEditor: View {
    @Binding var text: String
    let language: CodeLanguage

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
    }
}

struct CodeOutputView: View {
    let result: CodeExecutionResult?
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Output")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let r = result {
                    Text(r.summary)
                        .font(.caption)
                        .foregroundStyle(r.isSuccess ? .green : .red)
                }
                if isRunning {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let r = result {
                        if !r.stdout.isEmpty {
                            Text(r.stdout)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !r.stderr.isEmpty {
                            Text(r.stderr)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        if r.stdout.isEmpty && r.stderr.isEmpty {
                            Text("(no output)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("Press Run to execute code")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

struct CodeLabHistoryView: View {
    @ObservedObject var store: CodeLabStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Recent Runs") {
                    if store.history.isEmpty {
                        Text("No runs yet").foregroundStyle(.secondary)
                    }
                    ForEach(store.history) { snippet in
                        Button {
                            store.loadSnippet(snippet)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(snippet.title)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    if let r = snippet.lastResult {
                                        Text(r.summary)
                                            .font(.caption)
                                            .foregroundStyle(r.isSuccess ? .green : .red)
                                    }
                                }
                                Text(snippet.language.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(snippet.code.prefix(100))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { store.deleteHistory(at: $0) }
                }

                Section("Saved Snippets") {
                    if store.savedSnippets.isEmpty {
                        Text("No saved snippets").foregroundStyle(.secondary)
                    }
                    ForEach(store.savedSnippets) { snippet in
                        Button {
                            store.loadSnippet(snippet)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.title)
                                    .font(.subheadline.weight(.medium))
                                Text(snippet.language.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { store.deleteSnippet(at: $0) }
                }
            }
            .navigationTitle("Code Lab History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear All") { store.clearHistory() }
                        .disabled(store.history.isEmpty)
                }
            }
        }
    }
}
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
    }
}