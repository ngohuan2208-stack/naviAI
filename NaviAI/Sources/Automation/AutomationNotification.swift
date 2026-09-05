import Foundation
import UserNotifications

// MARK: - Local notifications for automation

/// Sends the four lifecycle notifications (started / completed / failed /
/// needs confirmation) through the official UNUserNotificationCenter API,
/// strictly rate-limited so the user is never spammed.
final class AutomationNotification {

    static let shared = AutomationNotification()

    private init() {}

    private enum Limits {
        static let minGap: TimeInterval = 20          // never two toasts closer than this
        static let maxPerHour = 6
    }

    private var lastPostDate: Date = .distantPast
    private var recentTimestamps: [Date] = []
    private let lock = NSLock()

    // MARK: Permission

    func requestPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    var permissionRequestedKey: String { "automation.notifications.requested" }

    func requestPermissionOnce() {
        let d = UserDefaults.standard
        guard d.bool(forKey: permissionRequestedKey) == false else { return }
        d.set(true, forKey: permissionRequestedKey)
        requestPermissionIfNeeded()
    }

    // MARK: Posting

    func postLocal(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Lifecycle events use the rate limiter; immediate in-app confirmations
    /// (e.g. asking the user to allow an action) can bypass via `force`.
    func postLifecycle(event: LifecycleEvent, taskName: String, detail: String? = nil, force: Bool = false) {
        guard shouldThrottle(taskName: taskName, event: event) || force else { return }
        let content = UNMutableNotificationContent()
        switch event {
        case .started:
            content.title = "Navi AI started a task"
            content.body = taskName
        case .completed:
            content.title = "Navi AI đã hoàn thành task"
            content.body = taskName + (detail.map { " — \($0)" } ?? "")
        case .failed:
            content.title = "Navi AI task failed"
            content.body = "\(taskName)\(detail.map { " — \($0)" } ?? "")"
        case .needsConfirmation:
            content.title = "Navi AI cần bạn xác nhận một hành động"
            content.body = taskName
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    enum LifecycleEvent {
        case started, completed, failed, needsConfirmation
    }

    // MARK: Throttling

    private func shouldThrottle(taskName: String, event: LifecycleEvent) -> Bool {
        // Confirmation requests are important; still capped by the hourly cap.
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        recentTimestamps = recentTimestamps.filter { now.timeIntervalSince($0) < 3600 }
        if recentTimestamps.count >= Limits.maxPerHour { return false }
        if now.timeIntervalSince(lastPostDate) < Limits.minGap && event != .completed { return false }

        lastPostDate = now
        recentTimestamps.append(now)
        return true
    }
}
