import SwiftUI

// MARK: - Root automation screen

struct AutomationRootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var automation: AutomationScheduler
    @State private var showEditor = false

    var body: some View {
        NavigationStack {
            Group {
                if automation.tasks.isEmpty {
                    ContentUnavailable("No automations yet", systemImage: "wand.and.stars",
                                       message: "Create a multi-step task and let Navi AI run it for you - once or on a schedule.")
                } else {
                    taskList
                }
            }
            .navigationTitle("Automation")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 16) {
                        NavigationLink {
                            AgentActivityView()
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        NavigationLink {
                            AutomationHistoryView()
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                AutomationTaskEditor(task: nil)
            }
        }
    }

    private var taskList: some View {
        List {
            ForEach(automation.tasks) { task in
                NavigationLink {
                    AutomationTaskDetailView(taskID: task.id)
                } label: {
                    AutomationCard(task: task)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    automation.delete(automation.tasks[index])
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Task card (status + next run + pause/stop)

struct AutomationCard: View {
    @EnvironmentObject var automation: AutomationScheduler
    let task: AutomationTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name).font(.subheadline.weight(.semibold))
                    Text(scheduleLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            HStack {
                if let next = task.nextRun, !task.status.isTerminal, task.status != .paused {
                    Label("Next run: " + next.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                controls
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var controls: some View {
        switch task.status {
        case .running:
            Button("Pause") { automation.pause(taskID: task.id) }
            Button("Stop", role: .destructive) { automation.stop(taskID: task.id) }
        case .paused:
            Button("Resume") { automation.resume(taskID: task.id) }
            Button("Stop", role: .destructive) { automation.stop(taskID: task.id) }
        case .suspended:
            Button("Resume") { automation.resumeSuspended(taskID: task.id) }
            Button("Discard", role: .destructive) { automation.discardSuspended(taskID: task.id) }
        case .scheduled:
            Button("Start") { automation.start(taskID: task.id) }
            Button("Pause") { automation.pause(taskID: task.id) }
        case .completed, .cancelled:
            Button("Restart") { automation.restart(taskID: task.id) }
        case .failed:
            Button("Retry") { automation.retry(taskID: task.id) }
            Button("Restart") { automation.restart(taskID: task.id) }
        }
    }

    private var scheduleLabel: String {
        switch task.schedule.kind {
        case .runOnce: return "Run once, " + task.schedule.delayLabel
        case .repeat_: return task.schedule.intervalLabel + boundSuffix
        }
    }

    private var boundSuffix: String {
        var parts: [String] = []
        if let maxRuns = task.schedule.maxRuns, maxRuns > 0 { parts.append("max " + String(maxRuns) + " runs") }
        if AutomationSchedule.parseClock(task.schedule.endTime) != nil {
            parts.append("until " + (task.schedule.endTime ?? ""))
        }
        return parts.isEmpty ? "" : " - " + parts.joined(separator: ", ")
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(task.status.label).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch task.status {
        case .running: return .green
        case .paused: return .orange
        case .scheduled: return .blue
        case .completed: return .mint
        case .failed: return .red
        case .cancelled: return .gray
        case .suspended: return .indigo
        }
    }
}

// MARK: - Task details

struct AutomationTaskDetailView: View {
    @EnvironmentObject var automation: AutomationScheduler
    let taskID: UUID

    var body: some View {
        List {
            statusSection
            goalSection
            stepsSection
            runsSection
            controlsSection
        }
        .navigationTitle(task?.name ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var task: AutomationTask? {
        automation.task(withID: taskID)
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Status", value: task?.status.label ?? "-")
            if let next = task?.nextRun, task?.status.isTerminal == false {
                LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
            }
            if let last = task?.lastRun {
                LabeledContent("Last run", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Runs", value: String(task?.runCount ?? 0))
            LabeledContent("Timeout", value: String(Int(task?.timeout ?? 0)) + "s / run")
            LabeledContent("Step limit", value: String(task?.maxSteps ?? 0))
            LabeledContent("Confirmation", value: task?.confirmationPolicy.label ?? "-")
            if let pending = task?.pendingRunState, let t = task {
                LabeledContent("Interrupted at step", value: String(pending.stepIndex + 1) + "/" + String(t.steps.count))
            }
        }
    }

    private var goalSection: some View {
        Section("Goal") {
            Text(task?.description.isEmpty == false ? (task?.description ?? "") : "No description.")
                .font(.subheadline)
        }
    }

    private var stepsSection: some View {
        Section("Actions") {
            ForEach(task?.steps ?? []) { step in
                HStack(spacing: 10) {
                    Image(systemName: step.kind.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.summary).font(.subheadline)
                        if !step.note.isEmpty {
                            Text(step.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var runsSection: some View {
        Section("Recent runs") {
            let runs = automation.runs(forTask: taskID)
            if runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary)
            } else {
                ForEach(runs.prefix(8)) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(run.status.label).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(run.durationLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(run.startTime.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let err = run.error {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            switch task?.status {
            case .running:
                Button(role: .destructive) {
                    automation.stop(taskID: taskID)
                } label: {
                    Label("Stop task", systemImage: "stop.fill")
                }
            case .paused:
                Button {
                    automation.resume(taskID: taskID)
                } label: {
                    Label("Resume task", systemImage: "play.fill")
                }
            case .suspended:
                Button {
                    automation.resumeSuspended(taskID: taskID)
                } label: {
                    Label("Resume previous task", systemImage: "arrow.clockwise.circle")
                }
                Button(role: .destructive) {
                    automation.discardSuspended(taskID: taskID)
                } label: {
                    Label("Discard suspended state", systemImage: "trash")
                }
            default:
                Button {
                    automation.start(taskID: taskID)
                } label: {
                    Label("Run now", systemImage: "play.fill")
                }
            }
        }
    }
}

// MARK: - Automation history (Today / Yesterday / Last 7 days / Older)

struct AutomationHistoryView: View {
    @EnvironmentObject var automation: AutomationScheduler

    var body: some View {
        List {
            historySection("Today", runs: automation.todayRuns)
            historySection("Yesterday", runs: automation.yesterdayRuns)
            historySection("Last 7 days", runs: automation.last7DaysRuns)
            historySection("Older", runs: automation.olderRuns)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") {
                    automation.clearHistory()
                }
                .disabled(automation.history.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func historySection(_ title: String, runs: [AutomationRun]) -> some View {
        if !runs.isEmpty {
            Section(title) {
                ForEach(runs) { run in
                    NavigationLink {
                        AutomationRunDetailView(run: run)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(run.taskName).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(run.status.label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(run.status == .completed ? .green : (run.status == .failed ? .red : .secondary))
                            }
                            Text(run.startTime.formatted(date: .abbreviated, time: .shortened) + " - " + run.durationLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Single run details (Goal / Actions / Timeline / Result / Errors)

struct AutomationRunDetailView: View {
    @EnvironmentObject var automation: AutomationScheduler
    @ObservedObject private var log = AgentActivityLog.shared
    let run: AutomationRun

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Task", value: run.taskName)
                LabeledContent("Status", value: run.status.label)
                LabeledContent("Started", value: run.startTime.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Ended", value: run.endTime.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Duration", value: run.durationLabel)
                LabeledContent("Steps", value: String(run.stepsExecuted) + "/" + String(run.totalSteps))
                LabeledContent("Trigger", value: run.trigger.isEmpty ? "schedule" : run.trigger)
            }
            Section("Result") {
                Text(run.result).font(.subheadline)
            }
            if let err = run.error {
                Section("Errors") {
                    Text(err).font(.subheadline).foregroundStyle(.red)
                }
            }
            if !run.userConfirmations.isEmpty {
                Section("User confirmations") {
                    ForEach(run.userConfirmations, id: \.self) { c in
                        Text(c).font(.caption)
                    }
                }
            }
            Section("Timeline") {
                let entries = log.entriesBetween(run.startTime, run.endTime)
                if entries.isEmpty {
                    Text("No activity recorded for this window.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.timeLabel)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)
                            Text(entry.message).font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Task details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Agent activity log

struct AgentActivityView: View {
    @EnvironmentObject var automation: AutomationScheduler
    @ObservedObject private var log = AgentActivityLog.shared

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("Activity will appear here while the AI browses or automates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.entries.reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.timeLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(entry.message).font(.caption)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Agent Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Clear") { log.clear() }
            }
        }
    }
}

// MARK: - Overlays: confirmation alert + floating mini status card + resume prompt

/// Hosted above the browser. Contains ONLY functional state the user must
/// see - never decorative debug UI.
struct AutomationOverlays: View {
    @EnvironmentObject var automation: AutomationScheduler
    @EnvironmentObject var engine: AutomationEngine
    /// Whether the "Resume previous task?" prompt has been handled this session.
    @State private var resumeHandled = false

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                if let taskID = engine.runningTaskID,
                   let task = automation.task(withID: taskID) {
                    FloatingStatusCard(task: task)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.runningTaskID)
        .alert("Navi AI needs confirmation",
               isPresented: Binding(
                   get: { automation.confirmationRequest != nil },
                   set: { if !$0 { automation.answerConfirmation(false) } }
               )) {
            Button("Allow") { automation.answerConfirmation(true) }
            Button("Cancel", role: .cancel) { automation.answerConfirmation(false) }
        } message: {
            Text(automation.confirmationRequest?.message ?? "")
        }
        .alert("Resume previous task?",
               isPresented: Binding(
                   get: { !resumeHandled && automation.suspendedTasks.first != nil },
                   set: { _ in }
               )) {
            Button("Resume") {
                if let t = automation.suspendedTasks.first {
                    automation.resumeSuspended(taskID: t.id)
                }
                resumeHandled = true
            }
            Button("Discard", role: .destructive) {
                if let t = automation.suspendedTasks.first {
                    automation.discardSuspended(taskID: t.id)
                }
                resumeHandled = true
            }
        } message: {
            Text("\"" + (automation.suspendedTasks.first?.name ?? "Task") + "\" was interrupted. Continue from where it stopped?")
        }
    }
}

/// Compact floating card: "AI Task Running / Searching... / Step 4 / 12" with
/// Pause + Stop. Shown only while a task runs; auto-hides when idle.
struct FloatingStatusCard: View {
    @EnvironmentObject var automation: AutomationScheduler
    @EnvironmentObject var engine: AutomationEngine
    let task: AutomationTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.accentColor)
                Text("AI Task Running")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            Text(engine.currentSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("Step " + String(engine.currentStepIndex) + " / " + String(max(engine.currentStepTotal, 1)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            HStack(spacing: 12) {
                Button {
                    automation.pause(taskID: task.id)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    automation.stop(taskID: task.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.12), in: Capsule())
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}
