import Foundation

/// One workspace/project container under ~/Library/Developer/Xcode/UserData/CodingAssistant/.
/// The directory name is "<WorkspaceName>-<28-char hash of the workspace path>".
struct Container: Identifiable {
    let id: String          // directory name on disk, e.g. "Client-eqzwjakjzwvucubwlrgllpdjlmid"
    let displayName: String
    let url: URL
    let projectPath: String?  // real workspace folder, recovered from an agent session's cwd
    var conversations: [Conversation]

    /// Human-readable location used to tell same-named projects apart: the project folder
    /// with the home directory abbreviated, falling back to the hashed directory name.
    var pathLabel: String {
        guard let projectPath else { return id }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return projectPath.hasPrefix(home) ? "~" + projectPath.dropFirst(home.count) : projectPath
    }

    var manifestURL: URL { url.appending(path: "CodingAssistantManifest.plist") }
    var snapshotsURL: URL { url.appending(path: "Snapshots") }
}

/// One conversation, backed by an entry in CodingAssistantManifest.plist (the source of
/// truth — stale conversation directories exist for deleted conversations).
struct Conversation: Identifiable {
    let id: String          // UUID string from the manifest entry
    let containerID: String
    let name: String
    let startDate: Date?
    let lastActivityDate: Date?
    let sizeOnDisk: Int64
    let sessionID: String?  // Claude agent session UUID, if this is an agent-backed conversation

    /// The manifest entry kept verbatim so unknown/new keys survive a copy across Xcode versions.
    let rawManifestEntry: [String: Any]
}

/// Identifies a conversation across containers for selection state.
struct ConversationRef: Hashable {
    let containerID: String
    let conversationID: String
}

struct TransferError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
