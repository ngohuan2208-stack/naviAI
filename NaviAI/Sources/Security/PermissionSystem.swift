import Foundation
import Combine

enum ToolPermission: String, Codable, CaseIterable, Identifiable {
    case readWeb, click, type, navigate, select, scroll, focus, wait, extract
    case download, screenshot, readFile, writeFile, imageGenerate, search
    case tabManage, historyAccess, conversationAccess, automation, agent
    case externalRequest, accountAction, purchase, sendMessage, delete
    case selfStop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .selfStop: return "Stop current task"
        case .readWeb: return "Read web page"
        case .click: return "Click elements"
        case .type: return "Type text"
        case .navigate: return "Navigate"
        case .select: return "Select options"
        case .scroll: return "Scroll page"
        case .focus: return "Focus fields"
        case .wait: return "Wait"
        case .extract: return "Extract content"
        case .download: return "Download files"
        case .screenshot: return "Take screenshots"
        case .readFile: return "Read files"
        case .writeFile: return "Write files"
        case .imageGenerate: return "Generate images"
        case .search: return "Web search"
        case .tabManage: return "Manage tabs"
        case .historyAccess: return "Access history"
        case .conversationAccess: return "Access conversations"
        case .automation: return "Run automation"
        case .agent: return "Run coding agent"
        case .externalRequest: return "External network request"
        case .accountAction: return "Change account info"
        case .purchase: return "Purchase / spend money"
        case .sendMessage: return "Send message"
        case .delete: return "Delete data"
        }
    }

    var symbol: String {
        switch self {
        case .readWeb: return "doc.text.magnifyingglass"
        case .click: return "hand.tap"
        case .type: return "keyboard"
        case .navigate: return "arrow.up.right.square"
        case .select: return "checklist"
        case .scroll: return "arrow.down.circle"
        case .focus: return "cursorarrow.click"
        case .wait: return "clock"
        case .extract: return "text.quote"
        case .download: return "arrow.down.circle"
        case .screenshot: return "camera"
        case .readFile, .writeFile: return "folder"
        case .imageGenerate: return "photo.on.rectangle.angled"
        case .search: return "magnifyingglass"
        case .tabManage: return "square.on.square"
        case .historyAccess: return "clock.arrow.circlepath"
        case .conversationAccess: return "bubble.left"
        case .automation: return "wand.and.stars"
        case .agent: return "brain.head.profile"
        case .externalRequest: return "network"
        case .selfStop: return "stop.circle"
        case .accountAction: return "person.crop.circle.badge.xmark"
        case .purchase: return "creditcard"
        case .sendMessage: return "paperplane"
        case .delete: return "trash"
        }
    }

    var isRisky: Bool {
        switch self {
        case .writeFile, .imageGenerate, .automation, .agent, .externalRequest,
             .accountAction, .purchase, .sendMessage, .delete:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class PermissionSystem: ObservableObject {

    struct PermissionRequest: Identifiable {
        let id = UUID()
        let permission: ToolPermission
        let detail: String
    }

    @Published private(set) var granted: Set<ToolPermission> = []
    @Published var request: PermissionRequest?

    var policy: PermissionPolicy = .ask

    private var continuation: CheckedContinuation<Bool, Never>?

    static let shared = PermissionSystem()
    private init() {}

    func grant(_ permission: ToolPermission) {
        granted.insert(permission)
    }

    func revoke(_ permission: ToolPermission) {
        granted.remove(permission)
    }

    func revokeAll() {
        granted.removeAll()
    }

    func isGranted(_ permission: ToolPermission) -> Bool {
        granted.contains(permission)
    }

    func authorize(_ permission: ToolPermission, detail: String = "") async -> Bool {
        if granted.contains(permission) { return true }
        switch policy {
        case .allow:
            granted.insert(permission)
            return true
        case .skip:
            return !permission.isRisky
        case .ask:
            if !permission.isRisky {

                granted.insert(permission)
                return true
            }
            return await withCheckedContinuation { cont in
                self.continuation = cont
                self.request = PermissionRequest(permission: permission, detail: detail)
            }
        }
    }

    func answer(_ allowed: Bool) {
        continuation?.resume(returning: allowed)
        continuation = nil
        request = nil
    }
}

enum PermissionPolicy: String, Codable, CaseIterable, Identifiable {

    case allow

    case ask

    case skip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allow: return "Allow without asking"
        case .ask: return "Ask before risky actions"
        case .skip: return "Skip risky actions"
        }
    }
}
