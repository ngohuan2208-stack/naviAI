import Foundation

struct AutomationPersistence {

    static let shared = AutomationPersistence()

    private let fm = FileManager.default
    private let tasksURL: URL
    private let historyURL: URL
    private let activityURL: URL

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Automation", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        tasksURL = dir.appendingPathComponent("tasks.json")
        historyURL = dir.appendingPathComponent("history.json")
        activityURL = dir.appendingPathComponent("activity.json")
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func loadTasks() -> [AutomationTask] {
        guard let data = try? Data(contentsOf: tasksURL) else { return [] }
        return (try? decoder.decode([AutomationTask].self, from: data)) ?? []
    }

    func saveTasks(_ tasks: [AutomationTask]) {
        if let data = try? encoder.encode(tasks) {
            try? data.write(to: tasksURL, options: .atomic)
        }
    }

    func loadHistory() -> [AutomationRun] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? decoder.decode([AutomationRun].self, from: data)) ?? []
    }

    func saveHistory(_ runs: [AutomationRun]) {
        if let data = try? encoder.encode(runs) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    func loadActivity() -> [AgentActivityEntry] {
        guard let data = try? Data(contentsOf: activityURL) else { return [] }
        return (try? decoder.decode([AgentActivityEntry].self, from: data)) ?? []
    }

    func saveActivity(_ entries: [AgentActivityEntry]) {
        if let data = try? encoder.encode(entries) {
            try? data.write(to: activityURL, options: .atomic)
        }
    }

    func wipeAll() {
        try? fm.removeItem(at: tasksURL)
        try? fm.removeItem(at: historyURL)
        try? fm.removeItem(at: activityURL)
    }
}
