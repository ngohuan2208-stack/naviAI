import Foundation
import Combine
import UIKit
import BackgroundTasks

@MainActor
final class AutomationScheduler: ObservableObject {

    @Published private(set) var tasks: [AutomationTask] = [] {
        didSet { AutomationPersistence.shared.saveTasks(tasks) }
    }
    @Published private(set) var history: [AutomationRun] = [] {
        didSet { AutomationPersistence.shared.saveHistory(Array(history.prefix(500))) }
    }
    @Published var confirmationRequest: AutomationConfirmation?

    struct AutomationConfirmation: Identifiable {
        let id = UUID()
        let taskID: UUID
        let runID: UUID
        let message: String
        let stepSummary: String
    }

    let engine = AutomationEngine()
    private var tickTimer: Timer?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    private var pausingTaskIDs = Set<UUID>()
    private var cancellables = Set<AnyCancellable>()
    private weak var browser: BrowserStore?

    init(browser: BrowserStore) {
        self.browser = browser
        engine.delegate = self
        engine.browser = browser
        loadPersisted()
        armTicker()
        registerBackgroundRefresh()
    }

    private func loadPersisted() {
        tasks = AutomationPersistence.shared.loadTasks()
        history = AutomationPersistence.shared.loadHistory()

        for i in tasks.indices where tasks[i].status == .running {
            if tasks[i].pendingRunState == nil {
                tasks[i].pendingRunState = .init(stepIndex: 0, startedAt: Date(), trigger: "restored")
            }
            tasks[i].status = .suspended
        }

        for i in tasks.indices where tasks[i].status == .scheduled {
            tasks[i].nextRun = Self.nextRunDate(for: tasks[i], from: Date())
        }
    }

    private func armTicker() {
        tickTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func tick() {
        guard engine.isRunning == false else { return }
        let now = Date()
        for i in tasks.indices {
            guard tasks[i].status == .scheduled,
                  let next = tasks[i].nextRun, next <= now else { continue }
            startRun(taskID: tasks[i].id, trigger: tasks[i].schedule.kind == .runOnce ? "schedule (once)" : "schedule (repeat)")
            break
        }
    }

    @discardableResult
    func add(task: AutomationTask) -> Bool {
        var t = task

        if t.schedule.kind == .repeat_ && !t.hasBound {
            t.schedule.maxRuns = 100
        }
        t.updatedAt = Date()
        t.status = .scheduled
        t.nextRun = Self.nextRunDate(for: t, from: Date())
        tasks.append(t)
        return true
    }

    func update(_ task: AutomationTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var t = task
        if t.schedule.kind == .repeat_ && !t.hasBound {
            t.schedule.maxRuns = 100
        }
        t.updatedAt = Date()
        if !t.status.isTerminal && t.status != .running {
            t.nextRun = Self.nextRunDate(for: t, from: Date())
        }
        tasks[idx] = t
    }

    func delete(_ task: AutomationTask) {
        if engine.runningTaskID == task.id { engine.stop() }
        tasks.removeAll { $0.id == task.id }
    }

    func task(withID id: UUID) -> AutomationTask? {
        tasks.first { $0.id == id }
    }

    func runs(forTask taskID: UUID) -> [AutomationRun] {
        history.filter { $0.taskID == taskID }.sorted { $0.startTime > $1.startTime }
    }

    func startRun(taskID: UUID, trigger: String = "manual") {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard engine.isRunning == false else { return }
        var t = tasks[idx]
        let resumeFrom = t.pendingRunState
        t.pendingRunState = nil
        t.status = .running
        t.lastRun = Date()
        t.updatedAt = Date()
        tasks[idx] = t

        var runnable = t
        runnable.pendingRunState = resumeFrom
        engine.start(task: runnable, trigger: trigger)
        AutomationNotification.shared.postLifecycle(event: .started, taskName: t.name)
        AgentActivityLog.shared.add("Task started — \(t.name)")
    }

    func start(taskID: UUID) { startRun(taskID: taskID, trigger: "manual") }

    func pause(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if engine.runningTaskID == taskID {
            pausingTaskIDs.insert(taskID)

            if confirmationRequest?.taskID == taskID {
                answerConfirmation(false)
            }
            engine.stop()
        }
        tasks[idx].status = .paused
        tasks[idx].updatedAt = Date()
        tasks[idx].nextRun = nil
    }

    func resume(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[idx].status == .paused else { return }
        tasks[idx].status = .scheduled
        tasks[idx].updatedAt = Date()
        tasks[idx].nextRun = Self.nextRunDate(for: tasks[idx], from: Date())
    }

    func stop(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if engine.runningTaskID == taskID {
            if confirmationRequest?.taskID == taskID {
                answerConfirmation(false)
            }
            engine.stop()
        } else {
            tasks[idx].status = .cancelled
            tasks[idx].nextRun = nil
            tasks[idx].updatedAt = Date()
        }
    }

    func restart(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[idx].runCount = 0
        tasks[idx].status = .scheduled
        tasks[idx].updatedAt = Date()
        tasks[idx].nextRun = Date()
    }

    func retry(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[idx].status = .scheduled
        tasks[idx].updatedAt = Date()
        startRun(taskID: taskID, trigger: "retry")
    }

    func resumeSuspended(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        guard tasks[idx].status == .suspended else { return }
        startRun(taskID: taskID, trigger: "resumed after suspension")
    }

    func discardSuspended(taskID: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[idx].pendingRunState = nil
        tasks[idx].status = .scheduled
        tasks[idx].updatedAt = Date()
        tasks[idx].nextRun = Self.nextRunDate(for: tasks[idx], from: Date())
    }

    static func nextRunDate(for task: AutomationTask, from reference: Date) -> Date? {
        let cal = Calendar.current
        let sched = task.schedule

        if sched.kind == .runOnce {
            let base = task.lastRun ?? task.createdAt
            let target = base.addingTimeInterval(sched.delaySeconds)
            return target > reference ? target : reference.addingTimeInterval(sched.delaySeconds)
        }

        if let maxRuns = sched.maxRuns, maxRuns > 0, task.runCount >= maxRuns { return nil }
        if let end = sched.endDate, reference >= end { return nil }

        let base = task.lastRun ?? reference
        var candidate = base.addingTimeInterval(sched.intervalSeconds)
        if candidate < reference { candidate = reference.addingTimeInterval(sched.intervalSeconds) }

        if let open = AutomationSchedule.parseClock(sched.startTime) {
            var openDate = cal.date(bySettingHour: open.h, minute: open.m, second: 0, of: candidate) ?? candidate
            if let close = AutomationSchedule.parseClock(sched.endTime) {
                var closeDate = cal.date(bySettingHour: close.h, minute: close.m, second: 0, of: candidate) ?? candidate
                if closeDate <= openDate {

                    closeDate = cal.date(byAdding: .day, value: 1, to: closeDate) ?? closeDate
                }
                if candidate < openDate && candidate > (openDate.addingTimeInterval(-86_400)) {
                    candidate = openDate
                } else if candidate > closeDate {
                    openDate = cal.date(byAdding: .day, value: 1, to: openDate) ?? openDate
                    candidate = max(openDate, candidate)
                }
            } else {

                let dayOpen = cal.date(bySettingHour: open.h, minute: open.m, second: 0, of: candidate) ?? candidate
                let prevDayOpen = dayOpen.addingTimeInterval(-86_400)
                if candidate < dayOpen && candidate >= prevDayOpen { candidate = dayOpen }
            }
        }

        if let end = sched.endDate, candidate > end { return nil }
        return candidate
    }

    private func registerBackgroundRefresh() {

        guard !Self.backgroundRegistered else {
            scheduleNextBackgroundRefresh()
            return
        }
        Self.backgroundRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundRefreshID, using: nil) { [weak self] bgTask in

            Task { @MainActor [weak self] in
                guard let self else {
                    bgTask.setTaskCompleted(success: false)
                    return
                }
                self.armTicker()
                for i in self.tasks.indices where self.tasks[i].status == .scheduled {
                    self.tasks[i].nextRun = AutomationScheduler.nextRunDate(for: self.tasks[i], from: Date())
                }
                AutomationPersistence.shared.saveTasks(self.tasks)
                self.scheduleNextBackgroundRefresh()
                bgTask.setTaskCompleted(success: true)
            }
        }
        scheduleNextBackgroundRefresh()
    }

    private func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {

        }
    }

    static let backgroundRefreshID = "com.naviai.app.automation.refresh"

    private static var backgroundRegistered = false

    func restoreAfterBackground() {
        armTicker()
        for i in tasks.indices where tasks[i].status == .scheduled {
            tasks[i].nextRun = Self.nextRunDate(for: tasks[i], from: Date())
        }
    }

    func persistForBackground() {
        guard let runningID = engine.runningTaskID,
              let idx = tasks.firstIndex(where: { $0.id == runningID }) else {
            AutomationPersistence.shared.saveTasks(tasks)
            return
        }
        tasks[idx].pendingRunState = .init(stepIndex: max(0, engine.currentStepIndex),
                                           startedAt: Date(),
                                           trigger: "backgrounded")
        tasks[idx].status = .suspended
        AutomationPersistence.shared.saveTasks(tasks)
    }

    var suspendedTasks: [AutomationTask] {
        tasks.filter { $0.status == .suspended && $0.pendingRunState != nil }
    }

    var todayRuns: [AutomationRun] { Self.runs(in: history, from: Calendar.current.startOfDay(for: Date())) }

    var yesterdayRuns: [AutomationRun] {
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        return Self.runs(in: history, from: start, to: Calendar.current.startOfDay(for: Date()))
    }

    var last7DaysRuns: [AutomationRun] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -7, to: today)!
        let end = cal.date(byAdding: .day, value: -1, to: today)!
        return Self.runs(in: history, from: start, to: end)
    }

    var olderRuns: [AutomationRun] {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date()))!
        return history.filter { $0.startTime < start }.sorted { $0.startTime > $1.startTime }
    }

    private static func runs(in list: [AutomationRun], from: Date, to: Date? = nil) -> [AutomationRun] {
        list.filter { run in
            run.startTime >= from && (to.map { $0 > run.startTime } ?? true)
        }.sorted { $0.startTime > $1.startTime }
    }

    func clearHistory() {
        history.removeAll()
    }
}

extension AutomationScheduler: AutomationEngineDelegate {

    func engineDidStartRun(_ engine: AutomationEngine, task: AutomationTask, runID: UUID) {

    }

    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID,
                willExecuteStepAt index: Int, step: AutomationStep) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].updatedAt = Date()
    }

    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID, didLog message: String) {
        AgentActivityLog.shared.add(message)
    }

    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID,
                requiresConfirmation message: String, for step: AutomationStep) async -> Bool {
        AutomationNotification.shared.postLifecycle(event: .needsConfirmation, taskName: task.name, force: true)
        confirmationRequest = AutomationConfirmation(taskID: task.id, runID: runID, message: message, stepSummary: step.summary)
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.confirmationContinuation = cont
        }
        confirmationRequest = nil
        return granted
    }

    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID,
                didFinishWith status: AutomationTaskStatus, stepsExecuted: Int, result: String, error: String?, confirmations: [String]) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }

        if pausingTaskIDs.remove(task.id) != nil {
            tasks[idx].status = .paused
            tasks[idx].updatedAt = Date()
            AgentActivityLog.shared.add("Task paused — \(task.name)")
            AutomationPersistence.shared.saveTasks(tasks)
            return
        }

        let now = Date()
        let started = tasks[idx].lastRun ?? now
        let run = AutomationRun(
            taskID: task.id,
            taskName: task.name,
            startTime: started,
            endTime: now,
            status: status,
            stepsExecuted: stepsExecuted,
            totalSteps: task.steps.count,
            result: result,
            error: error,
            userConfirmations: confirmations,
            trigger: ""
        )
        history.insert(run, at: 0)

        tasks[idx].runCount += 1
        tasks[idx].updatedAt = now

        switch status {
        case .completed:
            tasks[idx].status = .scheduled
            tasks[idx].nextRun = Self.nextRunDate(for: tasks[idx], from: now)
            if tasks[idx].nextRun == nil {
                tasks[idx].status = .completed
                AgentActivityLog.shared.add("Task completed — no further runs scheduled")
            } else {
                AgentActivityLog.shared.add("Task completed — \(stepsExecuted) steps")
            }
            AutomationNotification.shared.postLifecycle(event: .completed, taskName: task.name, detail: "\(stepsExecuted)/\(task.steps.count) steps")
        case .cancelled:
            tasks[idx].status = .cancelled
            tasks[idx].nextRun = nil
            AutomationNotification.shared.postLifecycle(event: .failed, taskName: task.name, detail: "cancelled")
        case .failed:
            let retries = tasks[idx].retryPolicy.maxRetries
            if retries > 0 {

                tasks[idx].status = .scheduled
                tasks[idx].retryPolicy.maxRetries = retries - 1
                tasks[idx].nextRun = now.addingTimeInterval(max(5, tasks[idx].retryPolicy.retryDelaySeconds))
                AgentActivityLog.shared.add("Task failed — retrying in \(Int(tasks[idx].retryPolicy.retryDelaySeconds))s")
            } else {
                tasks[idx].status = .failed
                tasks[idx].nextRun = nil
                AutomationNotification.shared.postLifecycle(event: .failed, taskName: task.name, detail: error)
            }
        default:
            break
        }
        AutomationPersistence.shared.saveTasks(tasks)
    }

    func answerConfirmation(_ granted: Bool) {
        confirmationContinuation?.resume(returning: granted)
        confirmationContinuation = nil
    }
}
