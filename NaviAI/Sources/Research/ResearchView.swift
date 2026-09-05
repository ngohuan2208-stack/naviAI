import SwiftUI

// MARK: - Deep research view

/// UI for the Deep Research engine: ask a question, watch the
/// Plan → Search → Read → Synthesize progress, stop at any time, and browse
/// past reports with their sources.
struct ResearchView: View {
    @ObservedObject private var engine = DeepResearchEngine.shared
    @EnvironmentObject var app: AppModel

    @State private var question = ""

    private var stageLabel: String {
        switch engine.stage {
        case .idle: return "Ready"
        case .planning: return "Planning searches…"
        case .searching: return "Searching the web…"
        case .reading(let done, let total): return "Reading source \(done)/\(total)…"
        case .synthesizing: return "Synthesizing the report…"
        case .done: return "Done"
        }
    }

    var body: some View {
        List {
            askSection
            if engine.isRunning { progressSection }
            reportsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Deep Research")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Ask

    private var askSection: some View {
        Section("Research question") {
            TextField("e.g. Compare the newest iPhone models' cameras", text: $question, axis: .vertical)
                .lineLimit(2...4)
                .disabled(engine.isRunning)
            Button {
                start()
            } label: {
                Label("Start Research", systemImage: "sparkMagnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isRunning)
            if engine.isRunning {
                Button(role: .destructive) {
                    engine.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func start() {
        engine.run(question.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Progress

    @ViewBuilder
    private var progressSection: some View {
        Section("Progress") {
            HStack(spacing: 10) {
                ProgressView()
                Text(stageLabel)
                    .font(.subheadline)
                Spacer()
            }
            if !engine.progress.isEmpty {
                Text(engine.progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Reports

    @ViewBuilder
    private var reportsSection: some View {
        Section {
            if engine.reports.isEmpty {
                Text("No reports yet. Run a research question above — NaviAI searches, reads several sources and writes a sourced summary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.reports) { report in
                    DisclosureGroup {
                        Text(report.report)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                        sourceList(report)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.question)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text("\(report.sources.count) source\(report.sources.count == 1 ? "" : "s") · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    engine.deleteReports(at: offsets)
                }
            }
        } header: {
            if !engine.reports.isEmpty {
                HStack {
                    Text("Reports")
                    Spacer()
                    Button("Clear All") { engine.clearReports() }
                        .font(.caption)
                }
            }
        }
    }

    private func sourceList(_ report: DeepResearchReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.caption.weight(.semibold))
            ForEach(report.sources) { source in
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title)
                        .font(.caption.weight(.medium))
                    Text(source.url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
