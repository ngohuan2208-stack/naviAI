import Foundation
import Combine

// MARK: - Browser profile

/// A Navi browser profile is a *profile*, not a fingerprinting or anti-detection
/// device. It only organises Navi's own browsing data (bookmarks, history) and
/// UI identity (name, avatar). It never spoofs device identity or fingerprints.
struct BrowserProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "Default"
    var displayName: String = "Default"
    var avatarSymbol: String = "face.smiling"
    var createdAt: Date = Date()

    var displayTitle: String {
        displayName.isEmpty ? name : displayName
    }
}

// MARK: - Browser profile store

/// Persists the user's browser profiles. The first profile is created on first
/// use so the app always has one.
@MainActor
final class BrowserProfileStore: ObservableObject {

    static let shared = BrowserProfileStore()

    @Published private(set) var profiles: [BrowserProfile] = []
    @Published var activeProfileID: UUID? {
        didSet { persist() }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let profiles = "browser.profiles.v1"
        static let active = "browser.profiles.active.v1"
    }

    private init() {
        if let data = defaults.data(forKey: Keys.profiles),
           let list = try? JSONDecoder().decode([BrowserProfile].self, from: data) {
            profiles = list
        }
        if let id = defaults.string(forKey: Keys.active).flatMap(UUID.init(uuidString:)),
           profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        } else {
            activeProfileID = profiles.first?.id
        }
        if profiles.isEmpty {
            let profile = BrowserProfile()
            profiles = [profile]
            activeProfileID = profile.id
            persist()
        }
    }

    var activeProfile: BrowserProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first ?? BrowserProfile()
    }

    func addProfile(name: String, displayName: String = "", avatar: String = "face.smiling") {
        let profile = BrowserProfile(name: name,
                                     displayName: displayName.isEmpty ? name : displayName,
                                     avatarSymbol: avatar)
        profiles.append(profile)
        activeProfileID = profile.id
        persist()
    }

    func activate(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
    }

    func rename(_ id: UUID, displayName: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].displayName = displayName
        persist()
    }

    func remove(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Keys.profiles)
        }
        defaults.set(activeProfileID?.uuidString, forKey: Keys.active)
    }
}