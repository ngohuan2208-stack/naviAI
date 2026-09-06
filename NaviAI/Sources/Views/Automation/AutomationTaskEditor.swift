import SwiftUI

struct AutomationTaskEditor: View {
    @EnvironmentObject var automation: AutomationScheduler
    @Environment(\.dismiss) private var dismiss

    let editingTask: AutomationTask?

    @State private var name = ""
    @State private var description = ""
    @State private var steps: [AutomationStep] = []
    @State private var repeatMode = false
    @State private var intervalMinutes = 10
    @State private var delaySeconds = 30
    @State private var startTimeText = ""
    @State private var endTimeText = ""
    @State private var maxRuns = 10
    @State private var useEndDate = false
    @State private var endDate = Date().addingTimeInterval(86_400)
    @State private var timeoutMinutes = 10
    @State private var maxSteps = 40
    @State private var retries = 0
    @State private var policy: ConfirmationPolicy = .riskyActions
    @State private var editingStep: AutomationStep?
    @State private var stepEditorPresented = false
    @State private var errorMessage: String?

    init(task: AutomationTask?) {
        editingTask = task
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Name (e.g. Check website)", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    ForEach(steps) { step in
                        Button {
                            editingStep = step
                            stepEditorPresented = true
                        } label: {
                            HStack {
                                Image(systemName: step.kind.symbol)
                                    .frame(width: 22)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.summary).font(.subheadline)
                                    if !step.note.isEmpty {
                                        Text(step.note).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { steps.remove(atOffsets: $0) }
                    .onMove { steps.move(fromOffsets: $0, toOffset: $1) }

                    Menu {
                        ForEach(AutomationStepKind.allCases) { kind in
                            Button {
                                steps.append(AutomationStep(kind: kind, value: "", amount: defaultAmount(for: kind)))
                            } label: {
                                Label(kind.label, systemImage: kind.symbol)
                            }
                        }
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Steps (\(steps.count))")
                } footer: {
                    Text("Click/Type steps find the element by its visible text on every run, so they keep working when the page changes.")
                }

                Section {
                    Picker("Mode", selection: $repeatMode) {
                        Text("Run once").tag(false)
                        Text("Repeat").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if repeatMode {
                        Picker("Every", selection: $intervalMinutes) {
                            Text("10 minutes").tag(10)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                            Text("6 hours").tag(360)
                            Text("1 day").tag(1440)
                            Text("Custom…").tag(0)
                        }
                        if ![10, 30, 60, 360, 1440].contains(intervalMinutes) {
                            Stepper("Custom: every \(max(1, intervalMinutes)) min", value: $intervalMinutes, in: 1...10_080)
                        }
                        HStack {
                            TextField("Start 08:00", text: $startTimeText)
                                .keyboardType(.numbersAndPunctuation)
                            TextField("End 22:00", text: $endTimeText)
                                .keyboardType(.numbersAndPunctuation)
                        }
                        Stepper("Max runs: \(maxRuns == 0 ? "until window ends" : String(maxRuns))", value: $maxRuns, in: 0...1000)
                        Toggle("End date", isOn: $useEndDate)
                        if useEndDate {
                            DatePicker("Stop after", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                        }
                    } else {
                        Picker("Start in", selection: $delaySeconds) {
                            Text("10 seconds").tag(10)
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("5 minutes").tag(300)
                            Text("Custom…").tag(0)
                        }
                        if delaySeconds == 0 {
                            Stepper("Custom: \(delaySeconds) sec", value: $delaySeconds, in: 5...86_400)
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Repeating tasks need a bound — max runs, an end time or an end date — so they never run forever.")
                }

                Section("Safety") {
                    Picker("Confirmation", selection: $policy) {
                        ForEach(ConfirmationPolicy.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    Stepper("Timeout: \(timeoutMinutes) min", value: $timeoutMinutes, in: 1...120)
                    Stepper("Step limit: \(maxSteps)", value: $maxSteps, in: 1...200)
                    Stepper("Retries on failure: \(retries)", value: $retries, in: 0...5)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editingTask == nil ? "New Automation" : "Edit Automation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear(perform: load)
            .sheet(item: $editingStep) { step in
                AutomationStepEditor(step: step) { updated in
                    if let idx = steps.firstIndex(where: { $0.id == updated.id }) {
                        steps[idx] = updated
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func load() {
        guard let t = editingTask else { return }
        name = t.name
        description = t.description
        steps = t.steps
        repeatMode = t.schedule.kind == .repeat_
        intervalMinutes = Int(t.schedule.intervalSeconds / 60)
        delaySeconds = Int(t.schedule.delaySeconds)
        startTimeText = t.schedule.startTime ?? ""
        endTimeText = t.schedule.endTime ?? ""
        maxRuns = t.schedule.maxRuns ?? 0
        policy = t.confirmationPolicy
        timeoutMinutes = max(1, Int(t.timeout / 60))
        maxSteps = t.maxSteps
        retries = t.retryPolicy.maxRetries
        if let end = t.schedule.endDate { endDate = end; useEndDate = true }
    }

    private func buildTask() -> AutomationTask {
        var schedule = AutomationSchedule()
        if repeatMode {
            schedule.kind = .repeat_
            schedule.intervalSeconds = TimeInterval(max(1, intervalMinutes) * 60)
            schedule.startTime = normalizedClock(startTimeText)
            schedule.endTime = normalizedClock(endTimeText)
            schedule.maxRuns = maxRuns > 0 ? maxRuns : nil
            if useEndDate { schedule.endDate = endDate }
        } else {
            schedule.kind = .runOnce
            schedule.delaySeconds = TimeInterval(max(5, delaySeconds))
        }

        var t = editingTask ?? AutomationTask(name: name)
        t.name = name
        t.description = description
        t.steps = steps
        t.schedule = schedule
        t.timeout = TimeInterval(timeoutMinutes * 60)
        t.maxSteps = maxSteps
        t.retryPolicy = RetryPolicy(maxRetries: retries, retryDelaySeconds: 30)
        t.confirmationPolicy = policy
        return t
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please give the task a name."
            return
        }
        guard !steps.isEmpty else {
            errorMessage = "Add at least one step."
            return
        }
        if repeatMode {
            let windowOK = AutomationSchedule.parseClock(startTimeText) != nil &&
                           AutomationSchedule.parseClock(endTimeText) != nil ||
                           (startTimeText.isEmpty && endTimeText.isEmpty)
            guard windowOK else {
                errorMessage = "Daily window must use HH:mm format (e.g. 08:00 and 22:00)."
                return
            }
            guard maxRuns > 0 || useEndDate || !endTimeText.isEmpty else {
                errorMessage = "Repeating tasks need a bound: max runs, an end time or an end date."
                return
            }
        }
        let task = buildTask()
        if editingTask == nil {
            automation.add(task: task)
        } else {
            automation.update(task)
        }
        dismiss()
    }

    private func defaultAmount(for kind: AutomationStepKind) -> Int? {
        switch kind {
        case .scroll: return 700
        case .wait: return 3
        case .extractText: return 4000
        default: return nil
        }
    }

    private func normalizedClock(_ text: String) -> String? {
        AutomationSchedule.parseClock(text) != nil ? text.trimmingCharacters(in: .whitespaces) : nil
    }
}

struct AutomationStepEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var step: AutomationStep
    var onSave: (AutomationStep) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Step type") {
                    Picker("Type", selection: $step.kind) {
                        ForEach(AutomationStepKind.allCases) { kind in
                            Label(kind.label, systemImage: kind.symbol).tag(kind)
                        }
                    }
                }

                switch step.kind {
                case .navigate:
                    TextField("https://example.com", text: $step.value)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                case .search:
                    TextField("Search query", text: $step.value)
                case .clickElement:
                    TextField("Visible text of the element (e.g. Search)", text: $step.value)
                case .typeText:
                    TextField("Field text hint (e.g. Search)", text: $step.value)
                    TextField("Text to type", text: $step.note, axis: .vertical)
                        .lineLimit(2...4)
                case .scroll:
                    Picker("Direction", selection: $step.value) {
                        Text("Down").tag("down")
                        Text("Up").tag("up")
                        Text("Top").tag("top")
                        Text("Bottom").tag("bottom")
                    }
                    Stepper("Amount: \(step.amount ?? 700) px", value: Binding(
                        get: { step.amount ?? 700 },
                        set: { step.amount = $0 }
                    ), in: 100...5000, step: 100)
                case .wait:
                    Stepper("Wait \(step.amount ?? 3) sec", value: Binding(
                        get: { step.amount ?? 3 },
                        set: { step.amount = $0 }
                    ), in: 1...60)
                case .extractText:
                    Stepper("Max characters: \(step.amount ?? 4000)", value: Binding(
                        get: { step.amount ?? 4000 },
                        set: { step.amount = $0 }
                    ), in: 500...12_000, step: 500)
                case .readPage:
                    EmptyView()
                case .askLLM:
                    TextField("Question for the AI (uses compact page context)", text: $step.value, axis: .vertical)
                        .lineLimit(2...5)
                case .notify:
                    TextField("Notification message", text: $step.value, axis: .vertical)
                        .lineLimit(2...4)
                }

                if step.kind == .typeText {
                    Text("Tip: the text lives in the second field; the first field tells the AI which input to focus.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Edit Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(step)
                        dismiss()
                    }
                }
            }
        }
    }
}
